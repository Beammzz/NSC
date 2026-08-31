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


def frame(seq, features, timestamp_ms=None):
    if timestamp_ms is None:
        timestamp_ms = int(round(seq * (1000.0 / 12.0)))
    return pb.LandmarkFrame(seq=seq, timestamp_ms=timestamp_ms, features=features)


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

    def test_non_finite_features_rejected(self, stack):
        stub, _, _ = stack
        bad = [float("nan")] * 147 + [0.0] * 294
        with pytest.raises(grpc.RpcError) as excinfo:
            list(stub.StreamInference(iter([frame(0, bad)])))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert "finite" in excinfo.value.details()

    def test_infinite_features_rejected(self, stack):
        stub, _, _ = stack
        bad = [float("inf")] * 147 + [0.0] * 294
        with pytest.raises(grpc.RpcError) as excinfo:
            list(stub.StreamInference(iter([frame(0, bad)])))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert "finite" in excinfo.value.details()

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


class TestSharedSecretAuth:
    """Any client that can reach the listen address must not get a free
    pass to UploadModel/SetTuning/StreamLogs without the shared secret."""

    @pytest.fixture
    def secured_stack(self, tmp_path):
        write_artifacts(tmp_path)
        engine = eng.InferenceEngine(
            output_dir=str(tmp_path),
            interpreter_factory=lambda path: FakeInterpreter(CONFIDENT),
        )
        broadcaster = logstream.LogBroadcaster()
        grpc_server, port = server.build_server(
            engine, broadcaster, "localhost:0", shared_secret="s3cr3t"
        )
        grpc_server.start()
        channel = grpc.insecure_channel(f"localhost:{port}")
        try:
            yield channel
        finally:
            channel.close()
            grpc_server.stop(grace=None)

    def _stub(self, channel):
        return pb_grpc.TslInferenceStub(channel)

    def test_unary_rpc_without_secret_rejected(self, secured_stack):
        stub = self._stub(secured_stack)
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.GetTuning(pb.GetTuningRequest())
        assert excinfo.value.code() == grpc.StatusCode.UNAUTHENTICATED

    def test_unary_rpc_with_wrong_secret_rejected(self, secured_stack):
        stub = self._stub(secured_stack)
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.GetTuning(
                pb.GetTuningRequest(),
                metadata=(("x-signmind-shared-secret", "wrong"),),
            )
        assert excinfo.value.code() == grpc.StatusCode.UNAUTHENTICATED

    def test_unary_rpc_with_correct_secret_admitted(self, secured_stack):
        stub = self._stub(secured_stack)
        response = stub.GetTuning(
            pb.GetTuningRequest(),
            metadata=(("x-signmind-shared-secret", "s3cr3t"),),
        )
        assert response.model_loaded

    def test_streaming_rpc_without_secret_rejected(self, secured_stack):
        stub = self._stub(secured_stack)
        with pytest.raises(grpc.RpcError) as excinfo:
            list(stub.StreamInference(wire_frames(1)))
        assert excinfo.value.code() == grpc.StatusCode.UNAUTHENTICATED

    def test_streaming_rpc_with_correct_secret_admitted(self, secured_stack):
        stub = self._stub(secured_stack)
        predictions = list(
            stub.StreamInference(
                wire_frames(30), metadata=(("x-signmind-shared-secret", "s3cr3t"),)
            )
        )
        assert len(predictions) == 1


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

    def test_old_upload_dirs_are_pruned(self, stack):
        stub, engine, _ = stack
        for _ in range(server.MAX_RETAINED_UPLOADS + 3):
            stub.UploadModel(
                upload_requests([
                    (pb.FILE_KIND_TFLITE_MODEL, b"new-model-bytes" * 100, None),
                    (pb.FILE_KIND_LABEL_MAP, label_map_bytes(), None),
                ])
            )
        uploads_dir = os.path.join(engine.output_dir, server.UPLOADS_DIRNAME)
        remaining = list(os.scandir(uploads_dir))
        assert len(remaining) <= server.MAX_RETAINED_UPLOADS
        # The currently active directory must have survived the prune.
        assert os.path.basename(engine.artifact_dir) in {e.name for e in remaining}

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


def extract_requests(clip=b"video-bytes", extension=".webm", frames=0, chunk=4):
    """ExtractInfo followed by the clip in `chunk`-sized pieces."""
    yield pb.ExtractKeypointsRequest(
        info=pb.ExtractInfo(extension=extension, frames=frames)
    )
    for i in range(0, len(clip), chunk):
        yield pb.ExtractKeypointsRequest(chunk=clip[i : i + chunk])


class FakeExtract:
    """Stands in for extract_keypoints.extract — no MediaPipe, no OpenCV.

    Records the path and the frame count it was called with, and reads the
    staged clip back so tests can prove the streamed bytes landed on disk.
    """

    def __init__(self, frames=None, raises=None):
        self.frames = [[{"x": 0.1, "y": 0.2, "z": 0.0}]] if frames is None else frames
        self.raises = raises
        self.path = None
        self.count = None
        self.staged = None

    def __call__(self, video_path, count):
        self.path = video_path
        self.count = count
        with open(video_path, "rb") as fh:
            self.staged = fh.read()
        if self.raises is not None:
            raise self.raises
        return self.frames


@pytest.fixture
def fake_extract(monkeypatch):
    """Install a FakeExtract, returning a setter so a test can pick behavior."""
    import extract_keypoints

    def install(**kwargs):
        fake = FakeExtract(**kwargs)
        monkeypatch.setattr(extract_keypoints, "extract", fake)
        return fake

    return install


class TestExtractKeypoints:
    def test_happy_path_returns_frames_json(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract(frames=[[{"x": 0.5, "y": 0.25, "z": -0.1}], []])
        clip = b"webm-bytes-that-span-several-chunks"

        response = stub.ExtractKeypoints(extract_requests(clip=clip))

        assert response.frame_count == 2
        assert json.loads(response.frames_json) == [
            [{"x": 0.5, "y": 0.25, "z": -0.1}],
            [],
        ]
        # Every streamed byte reached the staged clip, in order.
        assert fake.staged == clip

    def test_extension_names_the_staged_file(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract()
        stub.ExtractKeypoints(extract_requests(extension=".mp4"))
        assert fake.path.endswith(".mp4")

    def test_staged_clip_is_removed_after_extraction(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract()
        stub.ExtractKeypoints(extract_requests())
        assert not os.path.exists(fake.path)

    def test_zero_frames_uses_the_extractor_default(self, stack, fake_extract):
        import extract_keypoints

        stub, _, _ = stack
        fake = fake_extract()
        stub.ExtractKeypoints(extract_requests(frames=0))
        assert fake.count == extract_keypoints.DEFAULT_FRAMES

    def test_explicit_frame_count_is_passed_through(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract()
        stub.ExtractKeypoints(extract_requests(frames=24))
        assert fake.count == 24

    def test_unsupported_extension_rejected(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract()
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(extract_requests(extension=".exe"))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert fake.path is None  # never reached the extractor

    def test_path_traversal_extension_rejected(self, stack, fake_extract):
        stub, _, _ = stack
        fake_extract()
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(extract_requests(extension="/../../etc/passwd"))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT

    def test_chunk_before_info_rejected(self, stack, fake_extract):
        stub, _, _ = stack
        fake_extract()
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(iter([pb.ExtractKeypointsRequest(chunk=b"orphan")]))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert "before ExtractInfo" in excinfo.value.details()

    def test_empty_clip_rejected(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract()
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(extract_requests(clip=b""))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert fake.path is None

    def test_no_frames_extracted_rejected(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract(frames=[])
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(extract_requests())
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert not os.path.exists(fake.path)  # cleaned up on the failure path

    def test_undecodable_clip_rejected(self, stack, fake_extract):
        stub, _, _ = stack
        fake = fake_extract(raises=RuntimeError("cannot open video: /tmp/x.webm"))
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(extract_requests())
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert not os.path.exists(fake.path)

    def test_missing_mediapipe_reports_failed_precondition(self, stack, fake_extract):
        stub, _, _ = stack
        fake_extract(raises=ImportError("No module named 'mediapipe'"))
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(extract_requests())
        assert excinfo.value.code() == grpc.StatusCode.FAILED_PRECONDITION
        assert "mediapipe" in excinfo.value.details()

    def test_oversized_clip_rejected(self, stack, fake_extract, monkeypatch):
        stub, _, _ = stack
        fake = fake_extract()
        monkeypatch.setattr(server, "MAX_CLIP_BYTES", 8)
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.ExtractKeypoints(extract_requests(clip=b"x" * 64))
        assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
        assert fake.path is None


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
