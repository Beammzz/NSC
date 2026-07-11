"""Shared test doubles: a fake TFLite interpreter and frame factories."""

import json

import numpy as np

import tsl_preprocess as tp
from inference import engine as eng

NUM_CLASSES = 4
LABELS = {
    "สวัสดี": 0,
    "ขอบคุณ": 1,
    "รัก": 2,
    "ไม่ทำอะไรเลย (Idle)": 3,
}


class FakeInterpreter:
    """Mimics the litert Interpreter surface the engine touches."""

    def __init__(self, probs, sequence_len=30, feature_dim=441):
        self.probs = np.asarray(probs, dtype=np.float32)
        self.input_shape = [1, sequence_len, feature_dim]
        self.invocations = 0
        self.last_input = None

    def get_input_details(self):
        return [{"index": 0, "shape": self.input_shape}]

    def get_output_details(self):
        return [{"index": 1, "shape": [1, len(self.probs)]}]

    def set_tensor(self, index, data):
        self.last_input = data

    def invoke(self):
        self.invocations += 1

    def get_tensor(self, index):
        return np.expand_dims(self.probs, axis=0)


def write_artifacts(dir_path):
    """Drop an (empty) model file and a valid 4-class label map into dir_path."""
    (dir_path / eng.MODEL_FILENAME).write_bytes(b"fake")
    (dir_path / eng.LABEL_MAP_FILENAME).write_text(
        json.dumps(LABELS, ensure_ascii=False), encoding="utf-8"
    )
    return dir_path


def moving_frames(t=30):
    """(t, 147) position frames with hands present and in motion."""
    rng = np.random.default_rng(7)
    return rng.uniform(0.1, 1.0, size=(t, tp.POSITION_DIMS)).astype(np.float32)
