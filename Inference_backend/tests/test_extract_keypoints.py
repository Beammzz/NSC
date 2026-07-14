"""Tests for the pure helpers of extract_keypoints (no MediaPipe/OpenCV).

Importing the module is safe because cv2/mediapipe are imported lazily inside
extract(); only the pure frame-shaping helpers are exercised here.
"""

from types import SimpleNamespace

import pytest

import extract_keypoints as ek


def lm(x: float, y: float, z: float = 0.0) -> SimpleNamespace:
    """A stand-in for a MediaPipe normalized landmark (exposes x/y/z)."""
    return SimpleNamespace(x=x, y=y, z=z)


class TestPoint:
    def test_rounds_and_defaults_z(self):
        p = ek._point(SimpleNamespace(x=0.123456, y=0.654321))
        assert p == {"x": 0.12346, "y": 0.65432, "z": 0.0}


class TestLandmarksToFrame:
    def test_pose_points_follow_signavatar_order(self):
        # Encode the MediaPipe index in x so the mapping is checkable.
        pose = [lm(float(i), 0.0) for i in range(17)]
        frame = ek.landmarks_to_frame(pose, None)
        assert len(frame) == 7
        assert [pt["x"] for pt in frame] == [0.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0]

    def test_missing_pose_is_zero_filled(self):
        frame = ek.landmarks_to_frame(None, None)
        assert frame == [{"x": 0.0, "y": 0.0, "z": 0.0}] * 7

    def test_hands_appended_after_pose(self):
        pose = [lm(0.0, 0.0) for _ in range(17)]
        left = [lm(0.1, 0.1)] * 21
        right = [lm(0.2, 0.2)] * 21
        frame = ek.landmarks_to_frame(pose, [left, right])
        assert len(frame) == 7 + 21 + 21
        assert frame[7]["x"] == 0.1
        assert frame[7 + 21]["x"] == 0.2


class TestDownsample:
    def test_returns_all_when_fewer_than_count(self):
        assert ek.downsample([1, 2, 3], 5) == [1, 2, 3]

    def test_exact_count_returns_all(self):
        assert ek.downsample([1, 2, 3], 3) == [1, 2, 3]

    def test_picks_count_frames_keeping_ends(self):
        frames = list(range(10))
        out = ek.downsample(frames, 4)
        assert len(out) == 4
        assert out[0] == 0
        assert out[-1] == 9

    def test_count_one_returns_first(self):
        assert ek.downsample([5, 6, 7], 1) == [5]

    def test_non_positive_count_raises(self):
        with pytest.raises(ValueError, match="positive"):
            ek.downsample([1, 2, 3], 0)
