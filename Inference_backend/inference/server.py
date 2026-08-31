"""TslInference gRPC servicer + entrypoint.

RPCs (contract: docs/api/tsl_inference.proto):
  StreamInference — bidi landmark frames -> predictions (the landmark path;
                    gRPC only, no HTTP fallback, per root DOX)
  UploadModel     — client-streamed model/label-map upload, atomic hot-swap
  ExtractKeypoints — client-streamed sign clip -> avatar keypoint frames JSON
                    (MediaPipe, offline; the gateway image has no Python)
  StreamLogs      — server-streamed live log records for the Go gateway
  GetTuning /
  SetTuning       — runtime inference knobs for the webui

Run: python -m inference.server   (listens on SIGNMIND_AI_ADDR,
default localhost:50051 — the Go gateway's default dial target).
"""

import json
import logging
import os
import queue
import shutil
import signal
import tempfile
import threading
from concurrent import futures
from datetime import datetime, timezone

import grpc
import numpy as np

import tsl_preprocess
from inference import logstream
from inference.auth_interceptor import SharedSecretInterceptor
from inference.engine import (
    LABEL_MAP_FILENAME,
    MODEL_FILENAME,
    InferenceEngine,
    ModelLoadError,
)
from inference.pb import tsl_inference_pb2 as pb
from inference.pb import tsl_inference_pb2_grpc as pb_grpc

logger = logging.getLogger("inference.server")

# Wire contract (docs/api/stream-schema.md, schema_version 1): every frame
# carries exactly 441 floats; only the position block (first 147) feeds the
# model — deltas are recomputed server-side after hand normalization.
WIRE_FEATURE_DIM = 441

UPLOADS_DIRNAME = "uploads"
# Reject uploads whose declared or actual size exceeds this (a full-precision
# LSTM .tflite is a few MB; 512 MiB is far beyond any legitimate model).
MAX_UPLOAD_BYTES = 512 * 1024 * 1024
# Accepted-upload directories kept under uploads/ (each up to 3 files x
# MAX_UPLOAD_BYTES). Rejected uploads are already cleaned up immediately by
# fail() below; without this cap, every successful UploadModel call grows
# disk usage forever. The most recent MAX_RETAINED_UPLOADS survive, which
# always includes the currently active one (its directory name — a UTC
# timestamp — sorts last).
MAX_RETAINED_UPLOADS = 5

_KIND_TO_FILENAME = {
    pb.FILE_KIND_TFLITE_MODEL: MODEL_FILENAME,
    pb.FILE_KIND_LABEL_MAP: LABEL_MAP_FILENAME,
    pb.FILE_KIND_PREPROCESS_CONFIG: tsl_preprocess.CONFIG_FILENAME,
}
_REQUIRED_KINDS = (pb.FILE_KIND_TFLITE_MODEL, pb.FILE_KIND_LABEL_MAP)

LOG_POLL_SECONDS = 0.5  # how often StreamLogs rechecks a quiet connection

# ---- ExtractKeypoints ----
# Mirrors the gateway's maxRecordingBytes (Backend/internal/learn/handler.go):
# a 2-4 second sign clip is a few MB, so this only stops abuse.
MAX_CLIP_BYTES = 100 * 1024 * 1024
# Containers the landmarker's decoder is expected to open. The extension also
# names the temp file, so this allow-list is what keeps a client-supplied
# string out of the path — never interpolate request.info.extension directly.
ALLOWED_CLIP_EXTENSIONS = frozenset(
    {".webm", ".mp4", ".mov", ".mkv", ".avi", ".gif"}
)
DEFAULT_CLIP_EXTENSION = ".webm"


class TslInferenceServicer(pb_grpc.TslInferenceServicer):
    def __init__(self, engine: InferenceEngine, broadcaster: logstream.LogBroadcaster):
        self._engine = engine
        self._broadcaster = broadcaster

    # ---- StreamInference ----

    def StreamInference(self, request_iterator, context):
        session = self._engine.session()
        logger.info("Inference stream opened: %s", context.peer())
        for frame in request_iterator:
            if frame.reset:
                session.reset()
                continue
            if not self._engine.model_loaded:
                context.abort(
                    grpc.StatusCode.FAILED_PRECONDITION,
                    "no model loaded — restore artifacts or call UploadModel",
                )
            if len(frame.features) != WIRE_FEATURE_DIM:
                context.abort(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    f"features must contain exactly {WIRE_FEATURE_DIM} values, "
                    f"got {len(frame.features)}",
                )
            position = np.asarray(
                frame.features[: tsl_preprocess.POSITION_DIMS], dtype=np.float32
            )
            if not np.all(np.isfinite(position)):
                context.abort(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    "features must be finite (no NaN/Infinity)",
                )
            try:
                result = session.add_frame(position, frame.timestamp_ms)
            except RuntimeError as exc:  # model hot-swapped mid-stream
                context.abort(grpc.StatusCode.FAILED_PRECONDITION, str(exc))
            if result is None:
                continue
            logger.debug(
                "prediction seq=%d word=%r conf=%.4f idle=%s uncertain=%s "
                "top=%s other=%.4f micros=%d",
                frame.seq,
                result.word,
                result.confidence,
                result.is_idle,
                result.is_uncertain,
                [(label, round(prob, 4)) for label, prob in result.top],
                result.other_prob,
                result.inference_micros,
            )
            yield pb.Prediction(
                seq=frame.seq,
                word=result.word,
                confidence=result.confidence,
                is_idle=result.is_idle,
                is_uncertain=result.is_uncertain,
                top=[
                    pb.ClassProb(label=label, prob=prob)
                    for label, prob in result.top
                ],
                inference_micros=result.inference_micros,
                other_prob=result.other_prob,
            )
        logger.info("Inference stream closed: %s", context.peer())

    # ---- UploadModel ----

    def UploadModel(self, request_iterator, context):
        staging_dir = os.path.join(
            self._engine.output_dir,
            UPLOADS_DIRNAME,
            datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"),
        )
        os.makedirs(staging_dir, exist_ok=True)
        received: dict[int, tuple[str, int, int]] = {}  # kind -> (path, declared, got)
        current_kind: int | None = None
        current_file = None

        def fail(code, detail):
            if current_file is not None:
                current_file.close()
            shutil.rmtree(staging_dir, ignore_errors=True)
            logger.warning("UploadModel rejected: %s", detail)
            context.abort(code, detail)

        try:
            for request in request_iterator:
                which = request.WhichOneof("payload")
                if which == "header":
                    header = request.header
                    if current_file is not None:
                        current_file.close()
                        current_file = None
                    filename = _KIND_TO_FILENAME.get(header.kind)
                    if filename is None:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"unknown FileKind {header.kind}",
                        )
                    if header.kind in received:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"duplicate file kind {header.kind}",
                        )
                    if header.size_bytes > MAX_UPLOAD_BYTES:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"{filename}: declared size {header.size_bytes} exceeds "
                            f"limit {MAX_UPLOAD_BYTES}",
                        )
                    path = os.path.join(staging_dir, filename)
                    received[header.kind] = (path, int(header.size_bytes), 0)
                    current_kind = header.kind
                    current_file = open(path, "wb")
                elif which == "chunk":
                    if current_file is None:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            "chunk received before any FileHeader",
                        )
                    path, declared, got = received[current_kind]
                    got += len(request.chunk)
                    if got > declared:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"{os.path.basename(path)}: received {got} bytes, "
                            f"header declared {declared}",
                        )
                    current_file.write(request.chunk)
                    received[current_kind] = (path, declared, got)
                else:
                    fail(grpc.StatusCode.INVALID_ARGUMENT, "empty UploadModelRequest")
            if current_file is not None:
                current_file.close()
                current_file = None
        except OSError as exc:
            fail(grpc.StatusCode.INTERNAL, f"cannot stage upload: {exc}")

        for kind in _REQUIRED_KINDS:
            if kind not in received:
                fail(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    f"missing required file: {_KIND_TO_FILENAME[kind]}",
                )
        for path, declared, got in received.values():
            if got != declared:
                fail(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    f"{os.path.basename(path)}: received {got} bytes, "
                    f"header declared {declared}",
                )

        try:
            self._engine.activate_artifacts(staging_dir)
        except ModelLoadError as exc:
            fail(grpc.StatusCode.INVALID_ARGUMENT, f"uploaded model rejected: {exc}")

        _prune_old_uploads(
            os.path.join(self._engine.output_dir, UPLOADS_DIRNAME), MAX_RETAINED_UPLOADS
        )

        num_classes, sequence_len, feature_dim = self._engine.model_info()
        logger.info(
            "UploadModel: new model live (%d classes, window %d, features %d)",
            num_classes,
            sequence_len,
            feature_dim,
        )
        return pb.UploadModelResponse(
            reloaded=True,
            num_classes=num_classes,
            sequence_len=sequence_len,
            feature_dim=feature_dim,
        )

    # ---- ExtractKeypoints ----

    def ExtractKeypoints(self, request_iterator, context):
        """Client-streamed sign clip -> avatar keypoint frames JSON.

        Offline and independent of the loaded LSTM: it touches neither the
        interpreter nor any InferenceSession, so a running inference stream is
        unaffected (it does compete for CPU while MediaPipe runs).
        """
        extension = DEFAULT_CLIP_EXTENSION
        frame_count = 0
        received = 0
        tmp_path = None
        clip = None
        seen_info = False

        def fail(code, detail):
            if clip is not None:
                clip.close()
            if tmp_path is not None:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            logger.warning("ExtractKeypoints rejected: %s", detail)
            context.abort(code, detail)

        try:
            for request in request_iterator:
                which = request.WhichOneof("payload")
                if which == "info":
                    if seen_info:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            "ExtractInfo may only be sent once, as the first message",
                        )
                    seen_info = True
                    requested = request.info.extension.strip().lower()
                    if requested:
                        if requested not in ALLOWED_CLIP_EXTENSIONS:
                            fail(
                                grpc.StatusCode.INVALID_ARGUMENT,
                                f"unsupported clip extension {requested!r}; "
                                f"expected one of "
                                f"{sorted(ALLOWED_CLIP_EXTENSIONS)}",
                            )
                        extension = requested
                    frame_count = int(request.info.frames)
                    fd, tmp_path = tempfile.mkstemp(
                        prefix="signmind-clip-", suffix=extension
                    )
                    clip = os.fdopen(fd, "wb")
                elif which == "chunk":
                    if clip is None:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            "chunk received before ExtractInfo",
                        )
                    received += len(request.chunk)
                    if received > MAX_CLIP_BYTES:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"clip exceeds the {MAX_CLIP_BYTES} byte limit",
                        )
                    clip.write(request.chunk)
                else:
                    fail(
                        grpc.StatusCode.INVALID_ARGUMENT,
                        "empty ExtractKeypointsRequest",
                    )
            if clip is not None:
                clip.close()
                clip = None
        except OSError as exc:
            fail(grpc.StatusCode.INTERNAL, f"cannot stage clip: {exc}")

        if not seen_info:
            fail(grpc.StatusCode.INVALID_ARGUMENT, "no ExtractInfo received")
        if received == 0:
            fail(grpc.StatusCode.INVALID_ARGUMENT, "clip is empty")

        try:
            # Imported here, not at module scope: MediaPipe/OpenCV are heavy
            # and are only present in deployments that serve this RPC, so a
            # service without them still starts and serves inference.
            import extract_keypoints
        except ImportError as exc:
            fail(
                grpc.StatusCode.FAILED_PRECONDITION,
                f"keypoint extraction is unavailable on this service: {exc}",
            )

        count = frame_count if frame_count > 0 else extract_keypoints.DEFAULT_FRAMES
        try:
            frames = extract_keypoints.extract(tmp_path, count)
        except ImportError as exc:  # MediaPipe/OpenCV missing at call time
            fail(
                grpc.StatusCode.FAILED_PRECONDITION,
                f"keypoint extraction is unavailable on this service: {exc}",
            )
        except (RuntimeError, ValueError, OSError) as exc:
            fail(
                grpc.StatusCode.INVALID_ARGUMENT,
                f"cannot extract keypoints from the clip: {exc}",
            )
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

        if not frames:
            fail(
                grpc.StatusCode.INVALID_ARGUMENT,
                "no frames extracted (empty or unreadable clip)",
            )

        logger.info(
            "ExtractKeypoints: %d frames from a %d byte %s clip",
            len(frames),
            received,
            extension,
        )
        return pb.ExtractKeypointsResponse(
            frames_json=json.dumps(frames, ensure_ascii=False),
            frame_count=len(frames),
        )

    # ---- StreamLogs ----

    def StreamLogs(self, request, context):
        min_level = request.min_level or pb.LOG_LEVEL_INFO
        history, live = self._broadcaster.subscribe(request.history_lines)
        logger.info("Log stream opened: %s", context.peer())
        try:
            for event in history:
                if event.level >= min_level:
                    yield _log_entry(event)
            while context.is_active():
                try:
                    event = live.get(timeout=LOG_POLL_SECONDS)
                except queue.Empty:
                    continue
                if event.level >= min_level:
                    yield _log_entry(event)
        finally:
            self._broadcaster.unsubscribe(live)

    # ---- Tuning ----

    def GetTuning(self, request, context):
        return self._tuning_state()

    def SetTuning(self, request, context):
        kwargs = {}
        if request.HasField("confidence_threshold"):
            kwargs["confidence_threshold"] = request.confidence_threshold
        if request.HasField("idle_min_frames_with_hands"):
            kwargs["idle_min_frames_with_hands"] = request.idle_min_frames_with_hands
        if request.HasField("idle_motion_std_threshold"):
            kwargs["idle_motion_std_threshold"] = request.idle_motion_std_threshold
        if request.HasField("debug_mode"):
            kwargs["debug_mode"] = request.debug_mode
        try:
            self._engine.set_tuning(**kwargs)
        except ValueError as exc:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))
        if request.HasField("debug_mode"):
            # Dev enables all debug output (per-prediction breakdown lines and
            # any library DEBUG records reach StreamLogs subscribers).
            level = logging.DEBUG if request.debug_mode else logging.INFO
            logging.getLogger().setLevel(level)
            logger.info("debug_mode=%s -> log level %s",
                        request.debug_mode, logging.getLevelName(level))
        return self._tuning_state()

    def _tuning_state(self) -> "pb.TuningState":
        tuning = self._engine.get_tuning()
        num_classes, sequence_len, feature_dim = self._engine.model_info()
        return pb.TuningState(
            confidence_threshold=tuning.confidence_threshold,
            idle_min_frames_with_hands=tuning.idle_min_frames_with_hands,
            idle_motion_std_threshold=tuning.idle_motion_std_threshold,
            model_loaded=self._engine.model_loaded,
            num_classes=num_classes,
            sequence_len=sequence_len,
            feature_dim=feature_dim,
            debug_mode=tuning.debug_mode,
        )


def _prune_old_uploads(uploads_dir: str, keep: int) -> None:
    """Delete the oldest accepted-upload directories beyond *keep*.

    Directory names are UTC timestamps (see UploadModel's staging_dir), so
    lexicographic order is chronological order.
    """
    try:
        entries = sorted(
            (e.path for e in os.scandir(uploads_dir) if e.is_dir()),
        )
    except OSError:
        return
    stale = entries[:-keep] if keep > 0 else entries
    for path in stale:
        shutil.rmtree(path, ignore_errors=True)


def _log_entry(event: logstream.LogEvent) -> "pb.LogEntry":
    return pb.LogEntry(
        timestamp_ms=event.timestamp_ms,
        level=event.level,
        logger=event.logger,
        message=event.message,
    )


def build_server(
    engine: InferenceEngine,
    broadcaster: logstream.LogBroadcaster,
    addr: str,
    max_workers: int = 10,
    shared_secret: str | None = None,
) -> tuple[grpc.Server, int]:
    """Wire the servicer into an (unstarted) server; returns (server, port).

    shared_secret, when set, requires every RPC to carry a matching
    x-signmind-shared-secret metadata entry (see auth_interceptor.py) —
    otherwise this gRPC service accepts calls from any network client that
    can reach addr.
    """
    interceptors = []
    if shared_secret:
        interceptors.append(SharedSecretInterceptor(shared_secret))
    server = grpc.server(
        futures.ThreadPoolExecutor(max_workers=max_workers),
        interceptors=interceptors,
    )
    pb_grpc.add_TslInferenceServicer_to_server(
        TslInferenceServicer(engine, broadcaster), server
    )
    port = server.add_insecure_port(addr)
    if port == 0:
        raise RuntimeError(f"cannot bind gRPC server to {addr}")
    return server, port


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    broadcaster = logstream.LogBroadcaster()
    broadcaster.setFormatter(logging.Formatter("%(message)s"))
    logging.getLogger().addHandler(broadcaster)

    engine = InferenceEngine()
    addr = os.environ.get("SIGNMIND_AI_ADDR", "localhost:50051")
    shared_secret = os.environ.get("SIGNMIND_AI_SHARED_SECRET", "")
    if not shared_secret:
        logger.warning(
            "SIGNMIND_AI_SHARED_SECRET is not set — this gRPC service is "
            "UNAUTHENTICATED. Any client that can reach %s can replace the "
            "live model, change tuning, or read live logs. Set it (and the "
            "matching value on the Go backend) outside local dev.",
            addr,
        )
    server, port = build_server(engine, broadcaster, addr, shared_secret=shared_secret)
    server.start()
    logger.info("TslInference gRPC server listening on %s (port %d)", addr, port)

    stop_event = threading.Event()

    def _shutdown(signum=None, frame=None):
        logger.info("Shutdown signal (%s) received", signum)
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _shutdown)
        except (ValueError, OSError):
            pass

    try:
        while not stop_event.is_set():
            stop_event.wait(timeout=1.0)
    except KeyboardInterrupt:
        logger.info("KeyboardInterrupt received")

    logger.info("Shutting down TslInference gRPC server...")
    shutdown_event = server.stop(grace=5)
    shutdown_event.wait()
    logger.info("TslInference gRPC server stopped cleanly.")


if __name__ == "__main__":
    main()
