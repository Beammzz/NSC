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
    "target_fps": 12,
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


def resample_window(
    frames: np.ndarray,
    timestamps_ms: np.ndarray | list[int | float],
    target_len: int,
    target_interval_ms: float,
) -> np.ndarray | None:
    """Resample a sequence of timestamped position frames onto a uniform time grid.

    Returns a (target_len, POSITION_DIMS) float32 array ending at the newest
    timestamp, spaced by target_interval_ms, or None if the input history does
    not cover the target duration (no extrapolation).
    """
    frames_arr = np.asarray(frames, dtype=np.float32)
    t_raw = np.asarray(timestamps_ms, dtype=np.float64)
    if frames_arr.ndim != 2 or frames_arr.shape[1] != POSITION_DIMS:
        return None
    if len(frames_arr) < 2 or len(t_raw) != len(frames_arr) or target_len < 1:
        return None

    # Guard non-monotonic / duplicate timestamps: keep strictly increasing sequence.
    clean_t = [t_raw[0]]
    clean_indices = [0]
    for i in range(1, len(t_raw)):
        if t_raw[i] > clean_t[-1]:
            clean_t.append(t_raw[i])
            clean_indices.append(i)
    if len(clean_t) < 2:
        return None

    t_arr = np.array(clean_t, dtype=np.float64)
    f_arr = frames_arr[clean_indices]

    t_latest = t_arr[-1]
    grid_t = t_latest - (
        target_len - 1 - np.arange(target_len, dtype=np.float64)
    ) * target_interval_ms
    if t_arr[0] > grid_t[0]:
        return None

    out = np.zeros((target_len, POSITION_DIMS), dtype=np.float32)
    for k in range(target_len):
        t_k = grid_t[k]
        right_idx = int(np.searchsorted(t_arr, t_k, side="left"))
        if right_idx == 0:
            idx_l, idx_r = 0, 0
            alpha = 0.0
        elif right_idx >= len(t_arr):
            idx_l, idx_r = len(t_arr) - 1, len(t_arr) - 1
            alpha = 0.0
        else:
            idx_l = right_idx - 1
            idx_r = right_idx
            dt = t_arr[idx_r] - t_arr[idx_l]
            alpha = (t_k - t_arr[idx_l]) / dt if dt > 0 else 0.0

        # Pose block: linear interpolation
        out[k, :POSE_DIMS] = (
            f_arr[idx_l, :POSE_DIMS]
            + alpha * (f_arr[idx_r, :POSE_DIMS] - f_arr[idx_l, :POSE_DIMS])
        )

        # Presence-gated hand interpolation
        if t_k - t_arr[idx_l] <= t_arr[idx_r] - t_k:
            nearest_idx = idx_l
        else:
            nearest_idx = idx_r

        for hand_slice in (LEFT_HAND_SLICE, RIGHT_HAND_SLICE):
            hand_l = f_arr[idx_l, hand_slice]
            hand_r = f_arr[idx_r, hand_slice]
            present_l = np.any(hand_l != 0.0)
            present_r = np.any(hand_r != 0.0)
            if present_l and present_r:
                out[k, hand_slice] = hand_l + alpha * (hand_r - hand_l)
            else:
                out[k, hand_slice] = f_arr[nearest_idx, hand_slice]

    return out
