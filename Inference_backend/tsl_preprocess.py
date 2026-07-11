"""TSL preprocessing shared by training and inference.

⚠️ RECONSTRUCTION NOTICE ⚠️
The original ``tsl_preprocess.py`` was lost in the repository split. This
module is rebuilt from the documented spec (root ``Agents.md`` Feature Vector
Spec, ``docs/api/stream-schema.md``, ``docs/api/tsl_inference.proto`` comments
and ``docs/STATE.md`` facts), with config keys matched to the recovered
training ``TSL_Output/preprocess_config.json`` (hand_local_norm,
hand_scale_norm, use_velocity, use_acceleration, confidence_threshold).
The exact hand-normalization FORMULAS are still assumptions — if the original
module from the training repo turns up, REPLACE this file with it. Live
signing accuracy is the acceptance test for the assumptions below.

Pipeline (must mirror training exactly):
  input  — (T, 147) position block per frame: [Pose 7*3 | Left 21*3 | Right 21*3],
           already body-normalized on-device (shoulder-mid centered,
           shoulder-width scaled, z included; missing detections zero-filled).
  step 1 — hand_local_norm: each detected hand's 21 landmarks re-centered on
           its own wrist (hand landmark 0), so the hand blocks encode shape
           only; hand location stays available through the pose wrists.
  step 2 — hand_scale_norm: each wrist-centered hand divided by its own size
           (max landmark distance from the wrist), removing hand-size
           differences between signers. Absent hands stay all-zero.
  step 3 — deltas: velocity v[t] = p[t] - p[t-1] (v[0] = 0, use_velocity) and
           acceleration a[t] = v[t] - v[t-1] (a[0] = 0, use_acceleration).
  output — (T, 441) float32: [position 147 | velocity 147 | acceleration 147].
"""

import json
import logging
import os

import numpy as np

logger = logging.getLogger("inference.preprocess")

# Position-block layout (single source of truth: root Agents.md → Feature
# Vector Spec). Slices are [start, stop) into the 147-dim position vector.
POSE_DIMS = 7 * 3  # 21
HAND_DIMS = 21 * 3  # 63
POSITION_DIMS = POSE_DIMS + 2 * HAND_DIMS  # 147
LEFT_HAND_SLICE = slice(POSE_DIMS, POSE_DIMS + HAND_DIMS)  # [21, 84)
RIGHT_HAND_SLICE = slice(POSE_DIMS + HAND_DIMS, POSITION_DIMS)  # [84, 147)

CONFIG_FILENAME = "preprocess_config.json"

# Defaults mirror the recovered training preprocess_config.json (2026-07-11).
# sequence_length is server-side only (wire window size; the model's own
# window length is read from the interpreter). confidence_threshold is
# runtime-tunable via the SetTuning RPC.
DEFAULT_PREPROCESS_CONFIG = {
    "sequence_length": 30,
    "hand_local_norm": True,
    "hand_scale_norm": True,
    "use_velocity": True,
    "use_acceleration": True,
    "confidence_threshold": 0.6,
}

# Guard against a hand whose landmarks all sit on the wrist (scale ~ 0).
MIN_HAND_SCALE = 1e-6


def load_preprocess_config(output_dir: str) -> dict:
    """Load ``preprocess_config.json`` from *output_dir*, merged over defaults.

    Missing file -> defaults with a warning (training may have used other
    values). Malformed file -> ValueError; silently falling back would let a
    model run with mismatched preprocessing.
    """
    config = dict(DEFAULT_PREPROCESS_CONFIG)
    path = os.path.join(output_dir, CONFIG_FILENAME)
    if not os.path.exists(path):
        logger.warning(
            "%s not found in %s — using DEFAULT_PREPROCESS_CONFIG; "
            "preprocessing may not match training.",
            CONFIG_FILENAME,
            output_dir,
        )
        return config
    try:
        with open(path, encoding="utf-8") as f:
            loaded = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        raise ValueError(f"Unreadable preprocess config {path}: {exc}") from exc
    if not isinstance(loaded, dict):
        raise ValueError(
            f"{path} must contain a JSON object, got {type(loaded).__name__}"
        )
    config.update(loaded)
    return config


def feature_dim(config: dict) -> int:
    """Model input feature dimension implied by *config* (441 with defaults)."""
    blocks = 1
    blocks += int(bool(config["use_velocity"]))
    blocks += int(bool(config["use_acceleration"]))
    return POSITION_DIMS * blocks


def _normalize_hands(
    positions: np.ndarray, local_norm: bool, scale_norm: bool
) -> np.ndarray:
    """Person-invariant hand normalization, per frame and per hand.

    local_norm: re-center the 21 landmarks on the hand's wrist (landmark 0).
    scale_norm: divide the wrist-centered landmarks by the hand's size
    (max landmark distance from the wrist) — ASSUMED formula, see module
    docstring. Operates on a copy; the caller's array is never mutated
    (frames are also referenced by the engine's sliding window).
    """
    out = positions.copy()
    for hand in (LEFT_HAND_SLICE, RIGHT_HAND_SLICE):
        block = out[:, hand].reshape(len(out), 21, 3)
        # A hand is "present" when any of its coords is nonzero (absent hands
        # are zero-filled upstream; comparing to 0.0 exactly is intended).
        present = np.any(block != 0.0, axis=(1, 2))
        wrist = block[present, 0:1, :]  # hand landmark 0
        centered = block[present] - wrist
        if scale_norm:
            # (n_present, 1, 1) max distance from wrist across the 21 points.
            scale = np.linalg.norm(centered, axis=2).max(axis=1)[:, None, None]
            centered = centered / np.maximum(scale, MIN_HAND_SCALE)
        block[present] = centered if local_norm else centered + wrist
        out[:, hand] = block.reshape(len(out), HAND_DIMS)
    return out


def preprocess_sequence(sequence: np.ndarray, config: dict) -> np.ndarray:
    """Turn a (T, 147) position sequence into the (T, feature_dim) model input.

    Raises ValueError on a wrong trailing dimension — a mis-sized frame means
    a client/schema mismatch and must never reach the interpreter silently.
    """
    seq = np.asarray(sequence, dtype=np.float32)
    if seq.ndim != 2 or seq.shape[1] != POSITION_DIMS:
        raise ValueError(
            f"expected (T, {POSITION_DIMS}) position sequence, got {seq.shape}"
        )
    local_norm = bool(config["hand_local_norm"])
    scale_norm = bool(config["hand_scale_norm"])
    if local_norm or scale_norm:
        positions = _normalize_hands(seq, local_norm, scale_norm)
    else:
        positions = seq
    blocks = [positions]
    # T=1 -> diff prepends the first frame, so velocity/acceleration are all
    # zeros; T>=2 -> v[0]=0, v[t]=p[t]-p[t-1].
    if config["use_velocity"] or config["use_acceleration"]:
        velocity = np.diff(positions, axis=0, prepend=positions[:1])
        if config["use_velocity"]:
            blocks.append(velocity)
        if config["use_acceleration"]:
            blocks.append(np.diff(velocity, axis=0, prepend=velocity[:1]))
    return np.concatenate(blocks, axis=1).astype(np.float32)
