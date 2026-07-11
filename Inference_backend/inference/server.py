"""TslInference gRPC servicer + entrypoint.

RPCs (contract: docs/api/tsl_inference.proto):
  StreamInference — bidi landmark frames -> predictions (the landmark path;
                    gRPC only, no HTTP fallback, per root DOX)
  UploadModel     — client-streamed model/label-map upload, atomic hot-swap
  StreamLogs      — server-streamed live log records for the Go gateway
  GetTuning /
  SetTuning       — runtime inference knobs for the webui

Run: python -m inference.server   (listens on SIGNMIND_AI_ADDR,
default localhost:50051 — the Go gateway's default dial target).
"""

import logging
import os
import queue
import shutil
from concurrent import futures
from datetime import datetime, timezone

import grpc
import numpy as np

import tsl_preprocess
from inference import logstream
from inference.engine import (
    LABEL_MAP_FILENAME,
    MODEL_FILENAME,
    InferenceEngine,
    ModelLoadError,
)
from inference.pb import tsl_inference_pb2 as pb
from inference.pb import tsl_inference_pb2_grpc as pb_grpc

logger = logging.getLogger("inference.server")

# Wire contract (docs/api/stream-schema.md, schema_version 1): every frame
# carries exactly 441 floats; only the position block (first 147) feeds the
# model — deltas are recomputed server-side after hand normalization.
WIRE_FEATURE_DIM = 441

UPLOADS_DIRNAME = "uploads"
# Reject uploads whose declared or actual size exceeds this (a full-precision
# LSTM .tflite is a few MB; 512 MiB is far beyond any legitimate model).
MAX_UPLOAD_BYTES = 512 * 1024 * 1024

_KIND_TO_FILENAME = {
    pb.FILE_KIND_TFLITE_MODEL: MODEL_FILENAME,
    pb.FILE_KIND_LABEL_MAP: LABEL_MAP_FILENAME,
    pb.FILE_KIND_PREPROCESS_CONFIG: tsl_preprocess.CONFIG_FILENAME,
}
_REQUIRED_KINDS = (pb.FILE_KIND_TFLITE_MODEL, pb.FILE_KIND_LABEL_MAP)

LOG_POLL_SECONDS = 0.5  # how often StreamLogs rechecks a quiet connection


class TslInferenceServicer(pb_grpc.TslInferenceServicer):
    def __init__(self, engine: InferenceEngine, broadcaster: logstream.LogBroadcaster):
        self._engine = engine
        self._broadcaster = broadcaster

    # ---- StreamInference ----

    def StreamInference(self, request_iterator, context):
        session = self._engine.session()
        logger.info("Inference stream opened: %s", context.peer())
        for frame in request_iterator:
            if frame.reset:
                session.reset()
                continue
            if not self._engine.model_loaded:
                context.abort(
                    grpc.StatusCode.FAILED_PRECONDITION,
                    "no model loaded — restore artifacts or call UploadModel",
                )
            if len(frame.features) != WIRE_FEATURE_DIM:
                context.abort(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    f"features must contain exactly {WIRE_FEATURE_DIM} values, "
                    f"got {len(frame.features)}",
                )
            position = np.asarray(
                frame.features[: tsl_preprocess.POSITION_DIMS], dtype=np.float32
            )
            try:
                result = session.add_frame(position)
            except RuntimeError as exc:  # model hot-swapped mid-stream
                context.abort(grpc.StatusCode.FAILED_PRECONDITION, str(exc))
            if result is None:
                continue
            yield pb.Prediction(
                seq=frame.seq,
                word=result.word,
                confidence=result.confidence,
                is_idle=result.is_idle,
                is_uncertain=result.is_uncertain,
                top=[
                    pb.ClassProb(label=label, prob=prob)
                    for label, prob in result.top
                ],
                inference_micros=result.inference_micros,
            )
        logger.info("Inference stream closed: %s", context.peer())

    # ---- UploadModel ----

    def UploadModel(self, request_iterator, context):
        staging_dir = os.path.join(
            self._engine.output_dir,
            UPLOADS_DIRNAME,
            datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"),
        )
        os.makedirs(staging_dir, exist_ok=True)
        received: dict[int, tuple[str, int, int]] = {}  # kind -> (path, declared, got)
        current_kind: int | None = None
        current_file = None

        def fail(code, detail):
            if current_file is not None:
                current_file.close()
            shutil.rmtree(staging_dir, ignore_errors=True)
            logger.warning("UploadModel rejected: %s", detail)
            context.abort(code, detail)

        try:
            for request in request_iterator:
                which = request.WhichOneof("payload")
                if which == "header":
                    header = request.header
                    if current_file is not None:
                        current_file.close()
                        current_file = None
                    filename = _KIND_TO_FILENAME.get(header.kind)
                    if filename is None:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"unknown FileKind {header.kind}",
                        )
                    if header.kind in received:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"duplicate file kind {header.kind}",
                        )
                    if header.size_bytes > MAX_UPLOAD_BYTES:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"{filename}: declared size {header.size_bytes} exceeds "
                            f"limit {MAX_UPLOAD_BYTES}",
                        )
                    path = os.path.join(staging_dir, filename)
                    received[header.kind] = (path, int(header.size_bytes), 0)
                    current_kind = header.kind
                    current_file = open(path, "wb")
                elif which == "chunk":
                    if current_file is None:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            "chunk received before any FileHeader",
                        )
                    path, declared, got = received[current_kind]
                    got += len(request.chunk)
                    if got > declared:
                        fail(
                            grpc.StatusCode.INVALID_ARGUMENT,
                            f"{os.path.basename(path)}: received {got} bytes, "
                            f"header declared {declared}",
                        )
                    current_file.write(request.chunk)
                    received[current_kind] = (path, declared, got)
                else:
                    fail(grpc.StatusCode.INVALID_ARGUMENT, "empty UploadModelRequest")
            if current_file is not None:
                current_file.close()
                current_file = None
        except OSError as exc:
            fail(grpc.StatusCode.INTERNAL, f"cannot stage upload: {exc}")

        for kind in _REQUIRED_KINDS:
            if kind not in received:
                fail(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    f"missing required file: {_KIND_TO_FILENAME[kind]}",
                )
        for path, declared, got in received.values():
            if got != declared:
                fail(
                    grpc.StatusCode.INVALID_ARGUMENT,
                    f"{os.path.basename(path)}: received {got} bytes, "
                    f"header declared {declared}",
                )

        try:
            self._engine.activate_artifacts(staging_dir)
        except ModelLoadError as exc:
            fail(grpc.StatusCode.INVALID_ARGUMENT, f"uploaded model rejected: {exc}")

        num_classes, sequence_len, feature_dim = self._engine.model_info()
        logger.info(
            "UploadModel: new model live (%d classes, window %d, features %d)",
            num_classes,
            sequence_len,
            feature_dim,
        )
        return pb.UploadModelResponse(
            reloaded=True,
            num_classes=num_classes,
            sequence_len=sequence_len,
            feature_dim=feature_dim,
        )

    # ---- StreamLogs ----

    def StreamLogs(self, request, context):
        min_level = request.min_level or pb.LOG_LEVEL_INFO
        history, live = self._broadcaster.subscribe(request.history_lines)
        logger.info("Log stream opened: %s", context.peer())
        try:
            for event in history:
                if event.level >= min_level:
                    yield _log_entry(event)
            while context.is_active():
                try:
                    event = live.get(timeout=LOG_POLL_SECONDS)
                except queue.Empty:
                    continue
                if event.level >= min_level:
                    yield _log_entry(event)
        finally:
            self._broadcaster.unsubscribe(live)

    # ---- Tuning ----

    def GetTuning(self, request, context):
        return self._tuning_state()

    def SetTuning(self, request, context):
        kwargs = {}
        if request.HasField("confidence_threshold"):
            kwargs["confidence_threshold"] = request.confidence_threshold
        if request.HasField("idle_min_frames_with_hands"):
            kwargs["idle_min_frames_with_hands"] = request.idle_min_frames_with_hands
        if request.HasField("idle_motion_std_threshold"):
            kwargs["idle_motion_std_threshold"] = request.idle_motion_std_threshold
        try:
            self._engine.set_tuning(**kwargs)
        except ValueError as exc:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))
        return self._tuning_state()

    def _tuning_state(self) -> "pb.TuningState":
        tuning = self._engine.get_tuning()
        num_classes, sequence_len, feature_dim = self._engine.model_info()
        return pb.TuningState(
            confidence_threshold=tuning.confidence_threshold,
            idle_min_frames_with_hands=tuning.idle_min_frames_with_hands,
            idle_motion_std_threshold=tuning.idle_motion_std_threshold,
            model_loaded=self._engine.model_loaded,
            num_classes=num_classes,
            sequence_len=sequence_len,
            feature_dim=feature_dim,
        )


def _log_entry(event: logstream.LogEvent) -> "pb.LogEntry":
    return pb.LogEntry(
        timestamp_ms=event.timestamp_ms,
        level=event.level,
        logger=event.logger,
        message=event.message,
    )


def build_server(
    engine: InferenceEngine,
    broadcaster: logstream.LogBroadcaster,
    addr: str,
    max_workers: int = 10,
) -> tuple[grpc.Server, int]:
    """Wire the servicer into an (unstarted) server; returns (server, port)."""
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=max_workers))
    pb_grpc.add_TslInferenceServicer_to_server(
        TslInferenceServicer(engine, broadcaster), server
    )
    port = server.add_insecure_port(addr)
    if port == 0:
        raise RuntimeError(f"cannot bind gRPC server to {addr}")
    return server, port


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    broadcaster = logstream.LogBroadcaster()
    broadcaster.setFormatter(logging.Formatter("%(message)s"))
    logging.getLogger().addHandler(broadcaster)

    engine = InferenceEngine()
    addr = os.environ.get("SIGNMIND_AI_ADDR", "localhost:50051")
    server, port = build_server(engine, broadcaster, addr)
    server.start()
    logger.info("TslInference gRPC server listening on %s (port %d)", addr, port)
    server.wait_for_termination()


if __name__ == "__main__":
    main()
