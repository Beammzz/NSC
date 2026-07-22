"""Engine tests using a fake TFLite interpreter (no runtime needed)."""

import numpy as np
import pytest
from fakes import NUM_CLASSES, FakeInterpreter, moving_frames, write_artifacts

import tsl_preprocess as tp
from inference import engine as eng


@pytest.fixture
def artifacts(tmp_path):
    """Model dir with an (empty) model file and a valid label map."""
    return write_artifacts(tmp_path)


def make_engine(artifacts, probs):
    fake = FakeInterpreter(probs)
    engine = eng.InferenceEngine(
        output_dir=str(artifacts), interpreter_factory=lambda path: fake
    )
    return engine, fake


class TestModelLifecycle:
    def test_no_artifacts_means_unloaded(self, tmp_path):
        engine = eng.InferenceEngine(
            output_dir=str(tmp_path), interpreter_factory=lambda path: None
        )
        assert not engine.model_loaded
        assert engine.model_info() == (0, 0, 0)
        session = engine.session()
        with pytest.raises(RuntimeError, match="no model loaded"):
            for i, frame in enumerate(moving_frames()):
                session.add_frame(frame, i * (1000.0 / 12.0))

    def test_autoload_from_output_dir(self, artifacts):
        engine, _ = make_engine(artifacts, [0.1, 0.2, 0.6, 0.1])
        assert engine.model_loaded
        assert engine.model_info() == (NUM_CLASSES, 30, 441)

    def test_label_map_class_count_mismatch_rejected(self, artifacts):
        fake = FakeInterpreter([0.5, 0.5])  # 2 outputs vs 4 labels
        with pytest.raises(eng.ModelLoadError, match="4 classes"):
            eng.InferenceEngine(
                output_dir=str(artifacts), interpreter_factory=lambda path: fake
            )

    def test_feature_dim_mismatch_rejected(self, artifacts):
        fake = FakeInterpreter([0.25] * NUM_CLASSES, feature_dim=147)
        with pytest.raises(eng.ModelLoadError, match="feature_dim 147"):
            eng.InferenceEngine(
                output_dir=str(artifacts), interpreter_factory=lambda path: fake
            )

    def test_failed_swap_keeps_previous_model(self, artifacts, tmp_path):
        engine, _ = make_engine(artifacts, [0.1, 0.2, 0.6, 0.1])
        bad_map = tmp_path / "bad_label_map.json"
        bad_map.write_text("[]", encoding="utf-8")
        with pytest.raises(eng.ModelLoadError):
            engine.load_model(str(artifacts / eng.MODEL_FILENAME), str(bad_map))
        assert engine.model_loaded
        assert engine.model_info()[0] == NUM_CLASSES


class TestPrediction:
    def test_window_fills_then_predicts(self, artifacts):
        engine, fake = make_engine(artifacts, [0.05, 0.9, 0.04, 0.01])
        session = engine.session()
        frames = moving_frames(30)
        results = [
            session.add_frame(f, i * (1000.0 / 12.0)) for i, f in enumerate(frames)
        ]
        assert all(r is None for r in results[:29])
        result = results[29]
        assert result.word == "ขอบคุณ"
        assert result.confidence == pytest.approx(0.9)
        assert not result.is_idle and not result.is_uncertain
        assert result.inference_micros >= 0
        assert fake.invocations == 1
        assert fake.last_input.shape == (1, 30, 441)

    def test_resampled_window_at_8fps(self, artifacts):
        engine, fake = make_engine(artifacts, [0.05, 0.9, 0.04, 0.01])
        session = engine.session()
        frames = moving_frames(30)
        results = [session.add_frame(f, i * 125.0) for i, f in enumerate(frames)]
        assert all(r is None for r in results[:20])
        assert results[20] is not None
        assert results[20].word == "ขอบคุณ"
        assert fake.invocations == 10
        assert fake.last_input.shape == (1, 30, 441)

    def test_uncertain_below_threshold_preserves_word_with_flag(self, artifacts):
        engine, _ = make_engine(artifacts, [0.3, 0.3, 0.3, 0.1])
        session = engine.session()
        result = None
        for i, frame in enumerate(moving_frames()):
            result = session.add_frame(frame, i * (1000.0 / 12.0))
        assert result.is_uncertain
        assert result.word == "รัก"
        assert result.confidence == pytest.approx(0.3)

    def test_no_hands_bypasses_to_idle(self, artifacts):
        engine, fake = make_engine(artifacts, [0.25] * NUM_CLASSES)
        session = engine.session()
        frames = moving_frames()
        frames[:, tp.POSE_DIMS :] = 0.0  # no hand landmarks in any frame
        result = None
        for i, frame in enumerate(frames):
            result = session.add_frame(frame, i * (1000.0 / 12.0))
        assert result.is_idle
        assert result.word == "ไม่ทำอะไรเลย (Idle)"
        assert result.confidence == pytest.approx(1.0)
        assert result.inference_micros == 0
        assert fake.invocations == 0

    def test_no_idle_class_bypasses_to_empty_word(self, tmp_path):
        import json

        no_idle_labels = {"สวัสดี": 0, "ขอบคุณ": 1, "รัก": 2, "ครอบครัว": 3}
        (tmp_path / eng.MODEL_FILENAME).write_bytes(b"fake")
        (tmp_path / eng.LABEL_MAP_FILENAME).write_text(
            json.dumps(no_idle_labels, ensure_ascii=False), encoding="utf-8"
        )
        fake = FakeInterpreter([0.25] * 4)
        engine = eng.InferenceEngine(
            output_dir=str(tmp_path), interpreter_factory=lambda path: fake
        )
        session = engine.session()
        frames = moving_frames()
        frames[:, tp.POSE_DIMS :] = 0.0  # no hands -> bypass
        result = None
        for i, frame in enumerate(frames):
            result = session.add_frame(frame, i * (1000.0 / 12.0))
        assert result.is_idle
        assert result.word == ""
        assert result.confidence == pytest.approx(0.0)
        assert result.top == []
        assert fake.invocations == 0

    def test_static_hands_bypass_to_idle(self, artifacts):
        engine, fake = make_engine(artifacts, [0.25] * NUM_CLASSES)
        session = engine.session()
        frame = moving_frames(1)[0]
        result = None
        for i in range(30):
            result = session.add_frame(frame, i * (1000.0 / 12.0))  # zero motion
        assert result.is_idle
        assert fake.invocations == 0

    def test_top_list_sorted_and_filtered(self, artifacts):
        engine, _ = make_engine(artifacts, [0.7, 0.2, 0.09, 0.005])
        session = engine.session()
        result = None
        for i, frame in enumerate(moving_frames()):
            result = session.add_frame(frame, i * (1000.0 / 12.0))
        assert [label for label, _ in result.top] == ["สวัสดี", "ขอบคุณ", "รัก"]
        probs = [p for _, p in result.top]
        assert probs == sorted(probs, reverse=True)

    def test_reset_clears_window(self, artifacts):
        engine, _ = make_engine(artifacts, [0.05, 0.9, 0.04, 0.01])
        session = engine.session()
        for i, frame in enumerate(moving_frames(29)):
            session.add_frame(frame, i * (1000.0 / 12.0))
        session.reset()
        assert session.add_frame(moving_frames(1)[0], 0) is None

    def test_bad_frame_shape_raises(self, artifacts):
        engine, _ = make_engine(artifacts, [0.25] * NUM_CLASSES)
        session = engine.session()
        with pytest.raises(ValueError, match="position frame"):
            session.add_frame(np.zeros(441), 0)  # full vector, not position block


class TestTuning:
    def test_partial_update(self, artifacts):
        engine, _ = make_engine(artifacts, [0.25] * NUM_CLASSES)
        before = engine.get_tuning()
        after = engine.set_tuning(confidence_threshold=0.8)
        assert after.confidence_threshold == pytest.approx(0.8)
        assert after.idle_min_frames_with_hands == before.idle_min_frames_with_hands

    def test_validation(self, artifacts):
        engine, _ = make_engine(artifacts, [0.25] * NUM_CLASSES)
        with pytest.raises(ValueError, match="confidence_threshold"):
            engine.set_tuning(confidence_threshold=1.5)
        with pytest.raises(ValueError, match="idle_min_frames_with_hands"):
            engine.set_tuning(idle_min_frames_with_hands=-1)
        with pytest.raises(ValueError, match="idle_motion_std_threshold"):
            engine.set_tuning(idle_motion_std_threshold=-0.1)

    def test_threshold_change_affects_prediction(self, artifacts):
        engine, _ = make_engine(artifacts, [0.45, 0.4, 0.1, 0.05])
        engine.set_tuning(confidence_threshold=0.4)
        session = engine.session()
        result = None
        for i, frame in enumerate(moving_frames()):
            result = session.add_frame(frame, i * (1000.0 / 12.0))
        assert not result.is_uncertain and result.word == "สวัสดี"


class TestDebugMode:
    def test_debug_off_by_default_and_other_prob_zero(self, artifacts):
        engine, _ = make_engine(artifacts, [0.6, 0.25, 0.1, 0.01])
        assert not engine.get_tuning().debug_mode
        session = engine.session()
        result = None
        for i, frame in enumerate(moving_frames()):
            result = session.add_frame(frame, i * (1000.0 / 12.0))
        assert len(result.top) == 3  # 0.01 filtered by TOP_MIN_PROB
        assert result.other_prob == 0.0

    def test_debug_mode_expands_top_and_fills_other_prob(self, artifacts):
        engine, _ = make_engine(artifacts, [0.6, 0.25, 0.1, 0.01])
        engine.set_tuning(debug_mode=True)
        session = engine.session()
        result = None
        for i, frame in enumerate(moving_frames()):
            result = session.add_frame(frame, i * (1000.0 / 12.0))
        # No probability cutoff: every class appears (capped at DEBUG_TOP_K).
        assert len(result.top) == NUM_CLASSES
        assert result.top[-1][1] == pytest.approx(0.01, abs=1e-4)
        assert result.other_prob == pytest.approx(
            1.0 - sum(p for _, p in result.top), abs=1e-6
        )

    def test_debug_mode_partial_update_keeps_other_tuning(self, artifacts):
        engine, _ = make_engine(artifacts, [0.25] * NUM_CLASSES)
        before = engine.get_tuning()
        after = engine.set_tuning(debug_mode=True)
        assert after.debug_mode
        assert after.confidence_threshold == before.confidence_threshold
        assert after.idle_min_frames_with_hands == before.idle_min_frames_with_hands
