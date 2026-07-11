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
            for frame in moving_frames():
                session.add_frame(frame)

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
        results = [session.add_frame(f) for f in frames]
        assert all(r is None for r in results[:29])
        result = results[29]
        assert result.word == "ขอบคุณ"
        assert result.confidence == pytest.approx(0.9)
        assert not result.is_idle and not result.is_uncertain
        assert result.inference_micros >= 0
        assert fake.invocations == 1
        assert fake.last_input.shape == (1, 30, 441)

    def test_uncertain_below_threshold_blanks_word(self, artifacts):
        engine, _ = make_engine(artifacts, [0.3, 0.3, 0.3, 0.1])
        session = engine.session()
        result = None
        for frame in moving_frames():
            result = session.add_frame(frame)
        assert result.is_uncertain
        assert result.word == ""
        assert result.confidence == pytest.approx(0.3)

    def test_no_hands_bypasses_to_idle(self, artifacts):
        engine, fake = make_engine(artifacts, [0.25] * NUM_CLASSES)
        session = engine.session()
        frames = moving_frames()
        frames[:, tp.POSE_DIMS :] = 0.0  # no hand landmarks in any frame
        result = None
        for frame in frames:
            result = session.add_frame(frame)
        assert result.is_idle
        assert result.word == "ไม่ทำอะไรเลย (Idle)"
        assert result.confidence == pytest.approx(1.0)
        assert result.inference_micros == 0
        assert fake.invocations == 0

    def test_static_hands_bypass_to_idle(self, artifacts):
        engine, fake = make_engine(artifacts, [0.25] * NUM_CLASSES)
        session = engine.session()
        frame = moving_frames(1)[0]
        result = None
        for _ in range(30):
            result = session.add_frame(frame)  # identical frame -> zero motion
        assert result.is_idle
        assert fake.invocations == 0

    def test_top_list_sorted_and_filtered(self, artifacts):
        engine, _ = make_engine(artifacts, [0.7, 0.2, 0.09, 0.005])
        session = engine.session()
        result = None
        for frame in moving_frames():
            result = session.add_frame(frame)
        assert [label for label, _ in result.top] == ["สวัสดี", "ขอบคุณ", "รัก"]
        probs = [p for _, p in result.top]
        assert probs == sorted(probs, reverse=True)

    def test_reset_clears_window(self, artifacts):
        engine, _ = make_engine(artifacts, [0.05, 0.9, 0.04, 0.01])
        session = engine.session()
        for frame in moving_frames(29):
            session.add_frame(frame)
        session.reset()
        assert session.add_frame(moving_frames(1)[0]) is None

    def test_bad_frame_shape_raises(self, artifacts):
        engine, _ = make_engine(artifacts, [0.25] * NUM_CLASSES)
        session = engine.session()
        with pytest.raises(ValueError, match="position frame"):
            session.add_frame(np.zeros(441))  # full vector, not position block


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
        for frame in moving_frames():
            result = session.add_frame(frame)
        assert not result.is_uncertain and result.word == "สวัสดี"
