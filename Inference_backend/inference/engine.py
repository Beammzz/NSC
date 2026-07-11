"""TSL inference engine: model lifecycle, sliding window, idle bypass, tuning.

Prediction behavior (idle bypass, uncertainty gate, top-5) is ported from the
webcam demo ``tsl_live_inference.py`` so server predictions match the
reference implementation frame-for-frame.

Threading model: one ``InferenceEngine`` per process. The engine owns the
model (TFLite interpreter, label map, tuning) guarded by ``_lock`` —
interpreters are not thread-safe and UploadModel may hot-swap the model while
streams run. Each gRPC stream owns its own ``InferenceSession`` (sliding
window), so concurrent gateway connections never share frames.
"""

import json
import logging
import os
import threading
import time
from collections import deque
from dataclasses import dataclass, field

import numpy as np

import tsl_preprocess

logger = logging.getLogger("inference.engine")

MODEL_FILENAME = "tsl_lstm_f32.tflite"
LABEL_MAP_FILENAME = "label_map.json"
# Points at the artifact dir of the last successful UploadModel. Uploads get
# their own directory (never overwriting files a live interpreter may have
# memory-mapped — Windows refuses that) and this manifest makes the newest
# upload survive restarts. Path inside is relative to output_dir.
ACTIVE_MANIFEST = "active_model.json"

# Idle-bypass defaults, from tsl_live_inference.py (window frames with a hand
# below 6, or mean hand-coordinate std-dev below 0.005 -> predict Idle
# without invoking the model). Runtime-tunable via SetTuning.
DEFAULT_IDLE_MIN_FRAMES_WITH_HANDS = 6
DEFAULT_IDLE_MOTION_STD_THRESHOLD = 0.005

# Substrings that mark the Idle class in label_map.json.
IDLE_LABEL_THAI = "ไม่ทำอะไรเลย"
IDLE_LABEL_EN = "idle"

TOP_K = 5
TOP_MIN_PROB = 0.01


def default_interpreter_factory(model_path: str):
    """Build a TFLite interpreter, allocated and ready.

    Imported lazily: ai-edge-litert/tensorflow have no win_arm64 wheels, and
    unit tests (which inject a fake factory) must run without them.
    """
    try:
        import ai_edge_litert.interpreter as litert
    except ImportError:
        try:
            import tensorflow.lite as litert
        except ImportError as exc:
            raise ModelLoadError(
                "No TFLite runtime: install 'ai-edge-litert' or 'tensorflow' "
                "(x64 Python on Windows — no win_arm64 wheels exist)"
            ) from exc
    interpreter = litert.Interpreter(model_path=model_path)
    interpreter.allocate_tensors()
    return interpreter


class ModelLoadError(Exception):
    """A model/label-map failed validation; the previous model stays live."""


@dataclass
class Tuning:
    confidence_threshold: float
    idle_min_frames_with_hands: int = DEFAULT_IDLE_MIN_FRAMES_WITH_HANDS
    idle_motion_std_threshold: float = DEFAULT_IDLE_MOTION_STD_THRESHOLD


@dataclass
class PredictionResult:
    word: str  # top-1 label; "" when is_uncertain
    confidence: float  # top-1 softmax probability
    is_idle: bool
    is_uncertain: bool
    top: list[tuple[str, float]] = field(default_factory=list)
    inference_micros: int = 0  # 0 when the idle bypass skipped the model


class _LoadedModel:
    """Interpreter + label map validated together (swapped atomically)."""

    def __init__(self, interpreter, label_map: dict[str, int]):
        self.interpreter = interpreter
        input_details = interpreter.get_input_details()
        output_details = interpreter.get_output_details()
        self.input_index = input_details[0]["index"]
        self.output_index = output_details[0]["index"]
        # Input tensor shape is (1, sequence_len, feature_dim).
        in_shape = list(input_details[0]["shape"])
        if len(in_shape) != 3:
            raise ModelLoadError(f"expected 3-D model input, got shape {in_shape}")
        self.sequence_len = int(in_shape[1])
        self.feature_dim = int(in_shape[2])
        self.num_classes = int(list(output_details[0]["shape"])[-1])
        if len(label_map) != self.num_classes:
            raise ModelLoadError(
                f"label map has {len(label_map)} classes but model outputs "
                f"{self.num_classes}"
            )
        self.idx_to_label = {int(v): k for k, v in label_map.items()}
        self.idle_idx = next(
            (
                int(v)
                for k, v in label_map.items()
                if IDLE_LABEL_THAI in k or IDLE_LABEL_EN in k.lower()
            ),
            None,
        )


def _parse_label_map(path: str) -> dict[str, int]:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise ModelLoadError(f"unreadable label map {path}: {exc}") from exc
    if not isinstance(data, dict) or not data:
        raise ModelLoadError(f"label map {path} must be a non-empty JSON object")
    try:
        return {str(k): int(v) for k, v in data.items()}
    except (TypeError, ValueError) as exc:
        raise ModelLoadError(
            f"label map {path} values must be integer class indices: {exc}"
        ) from exc


class InferenceEngine:
    """Owns the model + tuning; hands out per-stream sessions."""

    def __init__(
        self,
        output_dir: str | None = None,
        interpreter_factory=default_interpreter_factory,
    ):
        # Default artifact dir: Inference_backend/TSL_Output, cwd-independent.
        if output_dir is None:
            output_dir = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "TSL_Output",
            )
        self.output_dir = output_dir
        self._interpreter_factory = interpreter_factory
        self._lock = threading.Lock()
        self._model: _LoadedModel | None = None
        self.artifact_dir = self._resolve_artifact_dir()
        self.config = tsl_preprocess.load_preprocess_config(self.artifact_dir)
        self.tuning = Tuning(
            confidence_threshold=float(self.config["confidence_threshold"])
        )
        model_path = os.path.join(self.artifact_dir, MODEL_FILENAME)
        label_map_path = os.path.join(self.artifact_dir, LABEL_MAP_FILENAME)
        if os.path.exists(model_path) and os.path.exists(label_map_path):
            self.load_model(model_path, label_map_path)
        else:
            logger.warning(
                "No model in %s (need %s + %s) — StreamInference is "
                "unavailable until artifacts are restored or uploaded.",
                self.artifact_dir,
                MODEL_FILENAME,
                LABEL_MAP_FILENAME,
            )

    def _resolve_artifact_dir(self) -> str:
        """Artifact dir named by the manifest, else output_dir (legacy layout)."""
        manifest_path = os.path.join(self.output_dir, ACTIVE_MANIFEST)
        if not os.path.exists(manifest_path):
            return self.output_dir
        try:
            with open(manifest_path, encoding="utf-8") as f:
                rel = json.load(f)["dir"]
            candidate = os.path.join(self.output_dir, rel)
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
            logger.warning(
                "Ignoring unreadable %s (%s); using %s",
                ACTIVE_MANIFEST,
                exc,
                self.output_dir,
            )
            return self.output_dir
        if os.path.exists(os.path.join(candidate, MODEL_FILENAME)):
            return candidate
        logger.warning(
            "%s points at %s but no model is there; using %s",
            ACTIVE_MANIFEST,
            rel,
            self.output_dir,
        )
        return self.output_dir

    # ---- model lifecycle ----

    def load_model(self, model_path: str, label_map_path: str) -> None:
        """Validate and hot-swap the live model. Raises ModelLoadError on any
        problem; the previous model (if any) stays live."""
        label_map = _parse_label_map(label_map_path)
        try:
            interpreter = self._interpreter_factory(model_path)
        except ModelLoadError:
            raise
        except Exception as exc:  # interpreter rejects bad flatbuffers etc.
            raise ModelLoadError(f"cannot load model {model_path}: {exc}") from exc
        model = _LoadedModel(interpreter, label_map)
        expected = tsl_preprocess.feature_dim(self.config)
        if model.feature_dim != expected:
            raise ModelLoadError(
                f"model expects feature_dim {model.feature_dim} but "
                f"preprocess config produces {expected}"
            )
        with self._lock:
            self._model = model
        logger.info(
            "Model loaded: %s (%d classes, window %d, features %d, idle_idx %s)",
            os.path.basename(model_path),
            model.num_classes,
            model.sequence_len,
            model.feature_dim,
            model.idle_idx,
        )

    def activate_artifacts(self, artifact_dir: str) -> None:
        """Make an uploaded artifact directory the live one.

        Loads its preprocess config + model; only on full success does the
        manifest get written and the previous model/config get dropped. On
        any failure the previous state stays live and this raises
        ModelLoadError.
        """
        previous_config = self.config
        try:
            self.config = tsl_preprocess.load_preprocess_config(artifact_dir)
            self.load_model(
                os.path.join(artifact_dir, MODEL_FILENAME),
                os.path.join(artifact_dir, LABEL_MAP_FILENAME),
            )
        except ValueError as exc:  # bad preprocess_config.json
            self.config = previous_config
            raise ModelLoadError(str(exc)) from exc
        except ModelLoadError:
            self.config = previous_config
            raise
        with self._lock:
            self.tuning.confidence_threshold = float(
                self.config["confidence_threshold"]
            )
        self.artifact_dir = artifact_dir
        manifest_path = os.path.join(self.output_dir, ACTIVE_MANIFEST)
        rel = os.path.relpath(artifact_dir, self.output_dir)
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump({"dir": rel}, f)
        logger.info("Activated uploaded artifacts: %s", rel)

    @property
    def model_loaded(self) -> bool:
        return self._model is not None

    def model_info(self) -> tuple[int, int, int]:
        """(num_classes, sequence_len, feature_dim); zeros when unloaded."""
        model = self._model
        if model is None:
            return (0, 0, 0)
        return (model.num_classes, model.sequence_len, model.feature_dim)

    # ---- tuning ----

    def get_tuning(self) -> Tuning:
        with self._lock:
            return Tuning(
                self.tuning.confidence_threshold,
                self.tuning.idle_min_frames_with_hands,
                self.tuning.idle_motion_std_threshold,
            )

    def set_tuning(
        self,
        confidence_threshold: float | None = None,
        idle_min_frames_with_hands: int | None = None,
        idle_motion_std_threshold: float | None = None,
    ) -> Tuning:
        """Apply only the given fields; validates before mutating anything."""
        if confidence_threshold is not None and not (
            0.0 <= confidence_threshold <= 1.0
        ):
            raise ValueError(
                f"confidence_threshold must be in [0, 1], got {confidence_threshold}"
            )
        if idle_min_frames_with_hands is not None and idle_min_frames_with_hands < 0:
            raise ValueError(
                "idle_min_frames_with_hands must be >= 0, "
                f"got {idle_min_frames_with_hands}"
            )
        if idle_motion_std_threshold is not None and idle_motion_std_threshold < 0.0:
            raise ValueError(
                "idle_motion_std_threshold must be >= 0, "
                f"got {idle_motion_std_threshold}"
            )
        with self._lock:
            if confidence_threshold is not None:
                self.tuning.confidence_threshold = confidence_threshold
            if idle_min_frames_with_hands is not None:
                self.tuning.idle_min_frames_with_hands = idle_min_frames_with_hands
            if idle_motion_std_threshold is not None:
                self.tuning.idle_motion_std_threshold = idle_motion_std_threshold
        logger.info("Tuning updated: %s", self.tuning)
        return self.get_tuning()

    # ---- sessions & prediction ----

    def session(self) -> "InferenceSession":
        return InferenceSession(self)

    def predict_window(self, seq_arr: np.ndarray) -> PredictionResult:
        """Predict on a full (sequence_len, 147) position window.

        Idle bypass and uncertainty gate mirror tsl_live_inference.py.
        """
        with self._lock:
            model = self._model
            tuning = self.tuning
            if model is None:
                raise RuntimeError("no model loaded")
            if len(seq_arr) != model.sequence_len:
                # A hot-swapped model changed the window length under a
                # session created earlier; the stream must reconnect.
                raise RuntimeError(
                    f"window has {len(seq_arr)} frames but the loaded model "
                    f"expects {model.sequence_len} — reset the stream"
                )

            # --- idle bypass (no model invocation) ---
            # Hand block of the position vector is dims [21, 147).
            hands_coords = seq_arr[:, tsl_preprocess.POSE_DIMS :]
            hands_present = np.any(hands_coords != 0.0, axis=1)
            num_frames_with_hands = int(np.sum(hands_present))
            has_motion = True
            if num_frames_with_hands > 0:
                hand_std = np.std(hands_coords, axis=0)
                first_frame_mask = hands_coords[0] != 0.0
                mean_std = (
                    float(np.mean(hand_std[first_frame_mask]))
                    if np.any(first_frame_mask)
                    else 0.0
                )
                if mean_std < tuning.idle_motion_std_threshold:
                    has_motion = False

            inference_micros = 0
            if num_frames_with_hands < tuning.idle_min_frames_with_hands or (
                not has_motion
            ):
                if model.idle_idx is None:
                    # This label map has no Idle class (the recovered 150-word
                    # map doesn't): report the bypass with an empty word
                    # instead of inventing class 0 at 100% confidence.
                    return PredictionResult(
                        word="",
                        confidence=0.0,
                        is_idle=True,
                        is_uncertain=False,
                        top=[],
                        inference_micros=0,
                    )
                res = np.zeros(model.num_classes, dtype=np.float32)
                res[model.idle_idx] = 1.0
                is_idle = True
            else:
                input_seq = tsl_preprocess.preprocess_sequence(seq_arr, self.config)
                input_data = np.expand_dims(input_seq, axis=0).astype(np.float32)
                started = time.perf_counter()
                model.interpreter.set_tensor(model.input_index, input_data)
                model.interpreter.invoke()
                res = model.interpreter.get_tensor(model.output_index)[0]
                # seconds -> microseconds
                inference_micros = int((time.perf_counter() - started) * 1_000_000)
                is_idle = False

            top_prob = float(res.max())
            is_uncertain = top_prob < tuning.confidence_threshold
            sorted_indices = np.argsort(res)[::-1]
            top = [
                (model.idx_to_label.get(int(i), f"Label {int(i)}"), float(res[i]))
                for i in sorted_indices[:TOP_K]
                if float(res[i]) > TOP_MIN_PROB
            ]
            word = (
                ""
                if is_uncertain
                else model.idx_to_label.get(
                    int(sorted_indices[0]), f"Label {int(sorted_indices[0])}"
                )
            )
            return PredictionResult(
                word=word,
                confidence=top_prob,
                is_idle=is_idle,
                is_uncertain=is_uncertain,
                top=top,
                inference_micros=inference_micros,
            )


class InferenceSession:
    """Per-stream sliding window over position frames."""

    def __init__(self, engine: InferenceEngine):
        self._engine = engine
        self._window: deque[np.ndarray] = deque(
            maxlen=int(engine.config["sequence_length"])
        )

    def reset(self) -> None:
        self._window.clear()

    def add_frame(self, position_features: np.ndarray) -> PredictionResult | None:
        """Append one (147,) position frame; predict once the window is full."""
        frame = np.asarray(position_features, dtype=np.float32)
        if frame.shape != (tsl_preprocess.POSITION_DIMS,):
            raise ValueError(
                f"expected ({tsl_preprocess.POSITION_DIMS},) position frame, "
                f"got {frame.shape}"
            )
        self._window.append(frame)
        if len(self._window) < self._window.maxlen:
            return None
        return self._engine.predict_window(np.array(self._window))
