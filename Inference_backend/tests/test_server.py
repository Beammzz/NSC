"""End-to-end gRPC servicer tests over a real local channel."""

import json
import logging
import os
import queue

import grpc
import pytest
from fakes import LABELS, NUM_CLASSES, FakeInterpreter, moving_frames, write_artifacts

from inference import engine as eng
from inference import logstream, server
from inference.pb import tsl_inference_pb2 as pb
from inference.pb import tsl_inference_pb2_grpc as pb_grpc

CONFIDENT = [0.05, 0.9, 0.04, 0.01]  # top-1 "ขอบคุณ"


def frame(seq, features):
    return pb.LandmarkFrame(seq=seq, timestamp_ms=seq * 33, features=features)


def wire_frames(count, start_seq=0):
    """LandmarkFrame messages with 441 wire floats (moving hands)."""
    positions = moving_frames(count)
    for i, pos in enumerate(positions):
        yield frame(start_seq + i, list(pos) + [0.0] * 294)  # zero-pad deltas


@pytest.fixture
def stack(tmp_path):
    """(stub, engine, broadcaster) around a real server on a random port."""
    write_artifacts(tmp_path)
    engine = eng.InferenceEngine(
        output_dir=str(tmp_path),
        interpreter_factory=lambda path: FakeInterpreter(CONFIDENT),
    )
    broadcaster = logstream.LogBroadcaster()
    broadcaster.setFormatter(logging.Formatter("%(message)s"))
    root = logging.getLogger()
    original_level = root.level  # SetTuning(debug_mode=...) mutates it
    root.addHandler(broadcaster)
    grpc_server, port = server.build_server(engine, broadcaster, "localhost:0")
    grpc_server.start()
    channel = grpc.insecure_channel(f"localhost:{port}")
    try:
        yield pb_grpc.TslInferenceStub(channel), engine, broadcaster
    finally:
        channel.close()
        grpc_server.stop(grace=None)
        root.removeHandler(broadcaster)
        root.setLevel(original_level)


class TestStreamInference:
    def test_prediction_after_full_window(self, stack):
        stub, _, _ = stack
        predictions = list(stub.StreamInference(wire_frames(30)))
        assert len(predictions) == 1
        p = predictions[0]
        assert p.seq == 29
        assert p.word == "ขอบคุณ"
        assert p.confidence == pytest.approx(0.9)
        assert not p.is_idle and not p.is_uncertain
        assert [c.label for c in p.top][0] == "ขอบคุณ"

    def test_sliding_window_predicts_per_frame(self, stack):
        stub, _, _ = stack
        predictions = list(stub.StreamInference(wire_frames(32)))
        assert [p.seq for p in predictions] == [29, 30, 31]

    def test_reset_clears_window(self, stack):
        stub, _, _ = stack

        def requests():
            yield from wire_frames(29)
            yield pb.LandmarkFrame(reset=True)
            yield from wire_frames(30, start_seq=100)

        predictions = list(stub.StreamInference(requests()))
        assert [p.seq for p in predictions] == [129]

    def test_wrong_feature_count_rejected(self, stack):
        stub, _, _ = stack
        with pytest.raises(grpc.RpcError) as excinfo:
            list(stub.StreamInference(iter([frame(0, [0.0] * 147)])))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert "441" in excinfo.value.details()

    def test_no_model_rejected(self, tmp_path):
        engine = eng.InferenceEngine(
            output_dir=str(tmp_path), interpreter_factory=lambda path: None
        )
        broadcaster = logstream.LogBroadcaster()
        grpc_server, port = server.build_server(engine, broadcaster, "localhost:0")
        grpc_server.start()
        try:
            with grpc.insecure_channel(f"localhost:{port}") as channel:
                stub = pb_grpc.TslInferenceStub(channel)
                with pytest.raises(grpc.RpcError) as excinfo:
                    list(stub.StreamInference(wire_frames(1)))
                assert excinfo.value.code() == grpc.StatusCode.FAILED_PRECONDITION
        finally:
            grpc_server.stop(grace=None)


def upload_requests(files):
    """files: list of (kind, payload_bytes, declared_size or None=len)."""
    for kind, payload, declared in files:
        size = len(payload) if declared is None else declared
        yield pb.UploadModelRequest(
            header=pb.FileHeader(kind=kind, filename="f", size_bytes=size)
        )
        for i in range(0, len(payload), 64):
            yield pb.UploadModelRequest(chunk=payload[i : i + 64])


def label_map_bytes():
    return json.dumps(LABELS, ensure_ascii=False).encode("utf-8")


class TestUploadModel:
    def test_happy_path_hot_swaps(self, stack):
        stub, engine, _ = stack
        old_dir = engine.artifact_dir
        response = stub.UploadModel(
            upload_requests([
                (pb.FILE_KIND_TFLITE_MODEL, b"new-model-bytes" * 100, None),
                (pb.FILE_KIND_LABEL_MAP, label_map_bytes(), None),
            ])
        )
        assert response.reloaded
        assert response.num_classes == NUM_CLASSES
        assert response.sequence_len == 30
        assert response.feature_dim == 441
        assert engine.artifact_dir != old_dir
        manifest = os.path.join(engine.output_dir, eng.ACTIVE_MANIFEST)
        assert os.path.exists(manifest)

    def test_missing_label_map_rejected(self, stack):
        stub, _, _ = stack
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.UploadModel(
                upload_requests([(pb.FILE_KIND_TFLITE_MODEL, b"model", None)])
            )
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert "label_map.json" in excinfo.value.details()

    def test_size_mismatch_rejected(self, stack):
        stub, _, _ = stack
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.UploadModel(
                upload_requests([
                    (pb.FILE_KIND_TFLITE_MODEL, b"model", 999),
                    (pb.FILE_KIND_LABEL_MAP, label_map_bytes(), None),
                ])
            )
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT

    def test_chunk_before_header_rejected(self, stack):
        stub, _, _ = stack
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.UploadModel(iter([pb.UploadModelRequest(chunk=b"orphan")]))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT

    def test_invalid_label_map_keeps_old_model(self, stack):
        stub, engine, _ = stack
        old_dir = engine.artifact_dir
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.UploadModel(
                upload_requests([
                    (pb.FILE_KIND_TFLITE_MODEL, b"model", None),
                    (pb.FILE_KIND_LABEL_MAP, b"[not-an-object]", None),
                ])
            )
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert engine.model_loaded
        assert engine.artifact_dir == old_dir


class TestStreamLogs:
    def test_history_replay(self, stack):
        stub, _, _ = stack
        logging.getLogger("inference.test").warning("history-marker")
        stream = stub.StreamLogs(pb.StreamLogsRequest(history_lines=50))
        entries = []
        for entry in stream:
            entries.append(entry)
            if any(e.message == "history-marker" for e in entries):
                break
        stream.cancel()
        marker = next(e for e in entries if e.message == "history-marker")
        assert marker.level == pb.LOG_LEVEL_WARNING
        assert marker.logger == "inference.test"
        assert marker.timestamp_ms > 1_500_000_000_000  # ms epoch, not seconds

    def test_min_level_filters(self, stack):
        stub, _, _ = stack
        logging.getLogger("inference.test").info("info-noise")
        logging.getLogger("inference.test").error("error-marker")
        stream = stub.StreamLogs(
            pb.StreamLogsRequest(min_level=pb.LOG_LEVEL_ERROR, history_lines=50)
        )
        first = next(iter(stream))
        stream.cancel()
        assert first.message == "error-marker"


class TestTuning:
    def test_get_reflects_engine(self, stack):
        stub, _, _ = stack
        state = stub.GetTuning(pb.GetTuningRequest())
        assert state.model_loaded
        assert state.num_classes == NUM_CLASSES
        assert state.confidence_threshold == pytest.approx(0.6)

    def test_set_partial(self, stack):
        stub, engine, _ = stack
        state = stub.SetTuning(pb.SetTuningRequest(confidence_threshold=0.75))
        assert state.confidence_threshold == pytest.approx(0.75)
        default_idle_frames = eng.DEFAULT_IDLE_MIN_FRAMES_WITH_HANDS
        assert state.idle_min_frames_with_hands == default_idle_frames
        assert engine.get_tuning().confidence_threshold == pytest.approx(0.75)

    def test_set_invalid_rejected(self, stack):
        stub, _, _ = stack
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.SetTuning(pb.SetTuningRequest(confidence_threshold=2.0))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT

    def test_debug_mode_roundtrip_and_detailed_predictions(self, stack):
        stub, engine, _ = stack
        assert not stub.GetTuning(pb.GetTuningRequest()).debug_mode
        state = stub.SetTuning(pb.SetTuningRequest(debug_mode=True))
        assert state.debug_mode
        assert logging.getLogger().level == logging.DEBUG
        predictions = list(stub.StreamInference(wire_frames(30)))
        p = predictions[0]
        assert len(p.top) == NUM_CLASSES  # expanded: no probability cutoff
        assert p.other_prob == pytest.approx(
            1.0 - sum(c.prob for c in p.top), abs=1e-5
        )
        state = stub.SetTuning(pb.SetTuningRequest(debug_mode=False))
        assert not state.debug_mode
        assert logging.getLogger().level == logging.INFO


class TestLogBroadcaster:
    def test_slow_subscriber_drops_not_blocks(self):
        broadcaster = logstream.LogBroadcaster()
        broadcaster.setFormatter(logging.Formatter("%(message)s"))
        _, live = broadcaster.subscribe(0)
        # Fill the queue past capacity; emit must never raise or block.
        record = logging.LogRecord(
            "t", logging.INFO, __file__, 1, "spam", None, None
        )
        for _ in range(logstream.SUBSCRIBER_QUEUE_SIZE + 10):
            broadcaster.emit(record)
        assert live.qsize() == logstream.SUBSCRIBER_QUEUE_SIZE
        broadcaster.unsubscribe(live)

    def test_unsubscribed_queue_stops_receiving(self):
        broadcaster = logstream.LogBroadcaster()
        broadcaster.setFormatter(logging.Formatter("%(message)s"))
        _, live = broadcaster.subscribe(0)
        broadcaster.unsubscribe(live)
        broadcaster.emit(
            logging.LogRecord("t", logging.INFO, __file__, 1, "gone", None, None)
        )
        with pytest.raises(queue.Empty):
            live.get_nowait()
