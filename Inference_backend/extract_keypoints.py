"""Extract avatar keypoint frames from a recorded sign clip.

Reads a video with MediaPipe Pose + Hand landmarkers and writes, to stdout, a
JSON array of animation frames for the Flutter ``SignAvatar`` widget::

    [[{"x": .., "y": .., "z": ..}, ...], ...]

Each frame lists the 7 upper-body pose points in ``SignAvatar`` order
``[nose, L-shoulder, R-shoulder, L-elbow, R-elbow, L-wrist, R-wrist]`` followed
by every detected hand landmark. Coordinates are raw MediaPipe *normalized
image* coordinates (0..1) — NOT the shoulder-centered features the classifier
uses — so the skeletal figure renders in frame. The clip is downsampled to
``--frames`` frames.

The Go backend execs this script (see ``Backend/internal/keypoint``). The heavy
MediaPipe/OpenCV imports are deferred into :func:`extract`, so the pure helpers
(:func:`landmarks_to_frame`, :func:`downsample`) can be unit-tested without
those runtimes installed.
"""

from __future__ import annotations

import argparse
import json
import sys

# MediaPipe Pose landmark indices in SignAvatar's 7-point order:
# nose, left/right shoulder, left/right elbow, left/right wrist.
POSE_INDICES = [0, 11, 12, 13, 14, 15, 16]
DEFAULT_FRAMES = 16

POSE_MODEL_FILE = "pose_landmarker_full.task"
HAND_MODEL_FILE = "hand_landmarker.task"
POSE_MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
    "pose_landmarker_full/float16/1/pose_landmarker_full.task"
)
HAND_MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/hand_landmarker/"
    "hand_landmarker/float16/1/hand_landmarker.task"
)


def _point(landmark: object) -> dict[str, float]:
    """One MediaPipe normalized landmark -> ``{x, y, z}`` (rounded, compact)."""
    return {
        "x": round(float(landmark.x), 5),
        "y": round(float(landmark.y), 5),
        "z": round(float(getattr(landmark, "z", 0.0)), 5),
    }


def landmarks_to_frame(
    pose_landmarks: list | None,
    hand_landmarks: list | None,
) -> list[dict[str, float]]:
    """Build one avatar frame: the 7 pose points in ``SignAvatar`` order (zeros
    when the pose is missing) followed by every detected hand landmark.

    Pure — accepts already-extracted landmark lists (objects exposing ``x``,
    ``y``, ``z``), so it carries no MediaPipe dependency and is unit-testable.
    """
    frame: list[dict[str, float]] = []
    for idx in POSE_INDICES:
        if pose_landmarks is not None and idx < len(pose_landmarks):
            frame.append(_point(pose_landmarks[idx]))
        else:
            frame.append({"x": 0.0, "y": 0.0, "z": 0.0})
    for hand in hand_landmarks or []:
        for lm in hand:
            frame.append(_point(lm))
    return frame


def downsample(frames: list, count: int) -> list:
    """Evenly pick ``count`` frames across ``frames``, keeping the first and
    last. Returns every frame when there are fewer than ``count``. Pure."""
    if count <= 0:
        raise ValueError("count must be positive")
    n = len(frames)
    if n <= count:
        return list(frames)
    if count == 1:
        return [frames[0]]
    step = (n - 1) / (count - 1)
    return [frames[round(i * step)] for i in range(count)]


def _download_models_if_missing() -> None:
    """Fetch the MediaPipe ``.task`` models into the cwd if absent."""
    import os
    import urllib.request

    models = (
        (POSE_MODEL_FILE, POSE_MODEL_URL),
        (HAND_MODEL_FILE, HAND_MODEL_URL),
    )
    for name, url in models:
        if not os.path.exists(name):
            urllib.request.urlretrieve(url, name)


def extract(video_path: str, count: int = DEFAULT_FRAMES) -> list:
    """Run the landmarkers over ``video_path`` and return ``count`` avatar
    frames. Imports MediaPipe/OpenCV lazily (heavy, x64-only runtimes)."""
    import cv2
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision

    _download_models_if_missing()

    pose_opts = vision.PoseLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=POSE_MODEL_FILE),
        running_mode=vision.RunningMode.VIDEO,
        num_poses=1,
    )
    hand_opts = vision.HandLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=HAND_MODEL_FILE),
        running_mode=vision.RunningMode.VIDEO,
        num_hands=2,
    )

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"cannot open video: {video_path}")

    frames: list = []
    try:
        with (
            vision.PoseLandmarker.create_from_options(pose_opts) as pose_lm,
            vision.HandLandmarker.create_from_options(hand_opts) as hand_lm,
        ):
            frame_idx = 0
            while True:
                ok, bgr = cap.read()
                if not ok:
                    break
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
                # Synthetic strictly-increasing timestamps: VIDEO mode rejects
                # non-monotonic ones, and CAP_PROP_POS_MSEC can repeat/return 0.
                timestamp_ms = frame_idx * 33
                frame_idx += 1
                pose_res = pose_lm.detect_for_video(image, timestamp_ms)
                hand_res = hand_lm.detect_for_video(image, timestamp_ms)
                pose = pose_res.pose_landmarks[0] if pose_res.pose_landmarks else None
                frames.append(landmarks_to_frame(pose, hand_res.hand_landmarks))
    finally:
        cap.release()

    return downsample(frames, count)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Extract SignAvatar keypoint frames from a recorded clip."
    )
    parser.add_argument("video", help="path to the recorded sign clip")
    parser.add_argument(
        "--frames",
        type=int,
        default=DEFAULT_FRAMES,
        help=f"number of frames to emit (default {DEFAULT_FRAMES})",
    )
    args = parser.parse_args(argv)

    frames = extract(args.video, args.frames)
    if not frames:
        print("no frames extracted (empty or unreadable video)", file=sys.stderr)
        return 1
    json.dump(frames, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
