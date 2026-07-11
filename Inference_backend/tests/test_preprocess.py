"""Tests for the reconstructed tsl_preprocess module."""

import json

import numpy as np
import pytest

import tsl_preprocess as tp


def make_seq(t: int) -> np.ndarray:
    rng = np.random.default_rng(42)
    return rng.uniform(-1.0, 1.0, size=(t, tp.POSITION_DIMS)).astype(np.float32)


class TestConfig:
    def test_defaults_when_file_missing(self, tmp_path):
        config = tp.load_preprocess_config(str(tmp_path))
        assert config == tp.DEFAULT_PREPROCESS_CONFIG

    def test_file_merges_over_defaults(self, tmp_path):
        (tmp_path / tp.CONFIG_FILENAME).write_text(
            json.dumps({"confidence_threshold": 0.7}), encoding="utf-8"
        )
        config = tp.load_preprocess_config(str(tmp_path))
        assert config["confidence_threshold"] == pytest.approx(0.7)
        assert config["sequence_length"] == 30  # untouched default

    def test_malformed_file_raises(self, tmp_path):
        (tmp_path / tp.CONFIG_FILENAME).write_text("{not json", encoding="utf-8")
        with pytest.raises(ValueError, match="Unreadable preprocess config"):
            tp.load_preprocess_config(str(tmp_path))

    def test_non_object_json_raises(self, tmp_path):
        (tmp_path / tp.CONFIG_FILENAME).write_text("[1, 2]", encoding="utf-8")
        with pytest.raises(ValueError, match="JSON object"):
            tp.load_preprocess_config(str(tmp_path))


class TestFeatureDim:
    def test_default_is_441(self):
        assert tp.feature_dim(tp.DEFAULT_PREPROCESS_CONFIG) == 441

    def test_position_only(self):
        config = dict(tp.DEFAULT_PREPROCESS_CONFIG)
        config["use_velocity"] = False
        config["use_acceleration"] = False
        assert tp.feature_dim(config) == 147


class TestPreprocessSequence:
    def test_output_shape_and_dtype(self):
        out = tp.preprocess_sequence(make_seq(30), tp.DEFAULT_PREPROCESS_CONFIG)
        assert out.shape == (30, 441)
        assert out.dtype == np.float32

    def test_wrong_dim_raises(self):
        with pytest.raises(ValueError, match="expected"):
            tp.preprocess_sequence(np.zeros((30, 146)), tp.DEFAULT_PREPROCESS_CONFIG)

    def test_input_not_mutated(self):
        seq = make_seq(5)
        original = seq.copy()
        tp.preprocess_sequence(seq, tp.DEFAULT_PREPROCESS_CONFIG)
        np.testing.assert_array_equal(seq, original)

    def test_velocity_is_frame_delta(self):
        config = dict(tp.DEFAULT_PREPROCESS_CONFIG)
        config["hand_local_norm"] = False  # isolate the delta math
        config["hand_scale_norm"] = False
        seq = make_seq(4)
        out = tp.preprocess_sequence(seq, config)
        vel = out[:, 147:294]
        np.testing.assert_allclose(vel[0], np.zeros(147), atol=1e-6)
        np.testing.assert_allclose(vel[2], seq[2] - seq[1], rtol=1e-5)
        accel = out[:, 294:441]
        np.testing.assert_allclose(accel[0], np.zeros(147), atol=1e-6)
        np.testing.assert_allclose(accel[2], vel[2] - vel[1], rtol=1e-5)

    def test_single_frame_deltas_are_zero(self):
        out = tp.preprocess_sequence(make_seq(1), tp.DEFAULT_PREPROCESS_CONFIG)
        np.testing.assert_allclose(out[0, 147:], np.zeros(294), atol=1e-6)

    def test_hand_local_norm_recenters_on_wrist(self):
        config = dict(tp.DEFAULT_PREPROCESS_CONFIG)
        config["hand_scale_norm"] = False  # isolate the recentering
        seq = np.zeros((2, 147), dtype=np.float32)
        # Left hand block: wrist at (0.5, 0.5, 0.1), landmark 1 offset +0.2 in x.
        seq[:, 21:24] = [0.5, 0.5, 0.1]
        seq[:, 24:27] = [0.7, 0.5, 0.1]
        out = tp.preprocess_sequence(seq, config)
        np.testing.assert_allclose(out[0, 21:24], [0.0, 0.0, 0.0], atol=1e-6)
        np.testing.assert_allclose(out[0, 24:27], [0.2, 0.0, 0.0], atol=1e-6)

    def test_hand_scale_norm_unit_size(self):
        # Full default config: recenter + scale. The same hand SHAPE at two
        # different sizes must normalize identically (person invariance).
        # All 21 landmarks are set — a detected MediaPipe hand always is.
        def hand_seq(spread):
            seq = np.zeros((1, 147), dtype=np.float32)
            wrist = np.array([0.5, 0.5, 0.1], dtype=np.float32)
            hand = np.zeros((21, 3), dtype=np.float32)
            for i in range(21):
                hand[i] = wrist + spread * np.array([i / 20.0, i / 40.0, 0.0])
            seq[:, 21:84] = hand.reshape(-1)
            return seq

        small = tp.preprocess_sequence(hand_seq(0.1), tp.DEFAULT_PREPROCESS_CONFIG)
        large = tp.preprocess_sequence(hand_seq(0.4), tp.DEFAULT_PREPROCESS_CONFIG)
        np.testing.assert_allclose(small[0, :147], large[0, :147], atol=1e-6)
        # Farthest landmark (i=20) sits at distance 1 from the wrist.
        landmark_20 = small[0, 21 + 20 * 3 : 21 + 21 * 3]
        np.testing.assert_allclose(
            np.linalg.norm(landmark_20), 1.0, atol=1e-6
        )

    def test_absent_hand_stays_zero(self):
        seq = make_seq(3)
        seq[:, tp.RIGHT_HAND_SLICE] = 0.0
        out = tp.preprocess_sequence(seq, tp.DEFAULT_PREPROCESS_CONFIG)
        np.testing.assert_array_equal(out[:, tp.RIGHT_HAND_SLICE], 0.0)
