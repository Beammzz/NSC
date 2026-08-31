# Inference backend — Child DOX

Child of root `Agents.md` (DOX). Root global contracts apply in full; this doc adds `Inference_backend/`-local rules only. (This directory replaces the former `ai/` tree, which was lost in the repository split — training/evaluation pipelines are not yet rebuilt.)

---

## Purpose

Python gRPC TSL inference service: receives landmark-frame streams from the Golang gateway, runs the LSTM (TFLite) over a 30-frame sliding window, and streams predictions back. Also serves management RPCs for the gateway/webui: model upload with hot-swap, live log streaming, runtime tuning, and offline keypoint extraction from recorded sign clips.

---

## Ownership

| Path | Owns |
|---|---|
| `tsl_preprocess.py` | Training-matching preprocessing: config load, hand normalization, temporal resampling (`resample_window` / `target_fps: 12`), delta features. ⚠️ RECONSTRUCTION — see Local Contracts |
| `tsl_live_inference.py` | Webcam demo (MediaPipe + TFLite); reference implementation the server mirrors |
| `extract_keypoints.py` | Recorded clip -> `SignAvatar` keypoint frames (MediaPipe pose + hand landmarkers). Imported by `server.py`'s `ExtractKeypoints` RPC; also runnable as a CLI |
| `inference/engine.py` | Model lifecycle (load/validate/hot-swap), per-stream timestamped sliding-window sessions (`resample_window`), idle bypass, uncertainty gate, runtime tuning |
| `inference/server.py` | `TslInference` gRPC servicer (`StreamInference`, `UploadModel`, `ExtractKeypoints`, `StreamLogs`, `GetTuning`/`SetTuning`) + entrypoint |
| `inference/logstream.py` | Logging handler: ring buffer + live subscriber queues feeding `StreamLogs` |
| `inference/pb/` | Generated stubs from `docs/api/tsl_inference.proto` — never edit by hand; regenerate (see Work Guidance) |
| `TSL_Output/` | Model artifacts: `tsl_lstm_f32.tflite`, `label_map.json`, `preprocess_config.json`; `uploads/<utc-ts>/` dirs + `active_model.json` manifest written by `UploadModel` |
| `tests/` | Unit/integration tests; `fakes.py` provides a fake interpreter so no TFLite runtime is needed |

---

## Local Contracts

- Contract source of truth: `docs/api/tsl_inference.proto`. Wire frames carry exactly 441 floats (`docs/api/stream-schema.md`, schema_version 1); the service consumes only the position block (first 147) along with `timestamp_ms`, and recomputes temporal resampling, hand normalization, and velocity/acceleration itself.
- Landmark path is gRPC bidirectional streaming only — no HTTP fallback (root DOX).
- ⚠️ `tsl_preprocess.py` is a spec-based RECONSTRUCTION (the original was lost with `ai/`). Its config keys match the recovered training `preprocess_config.json` (`hand_local_norm`, `hand_scale_norm`, `use_velocity`, `use_acceleration`, `confidence_threshold`, `target_fps: 12`). Temporal resampling (`resample_window`) uses presence-gated linear interpolation over the timestamped frame buffer to convert variable capture rates (8–30 fps) to the training grid (`12 fps`).
- `InferenceSession` maintains a timestamped ring buffer of `(timestamp_ms, position_features)` sized by duration rather than fixed count. Predictions start only once accumulated frame history covers the target window duration (`(sequence_length - 1) * (1000 / target_fps)` ≈ `2.42 s` for 30 frames at 12 fps).
- The label map may contain an idle class (`ไม่ทำอะไรเลย`); the engine detects it by matching `IDLE_LABEL_THAI`/`IDLE_LABEL_EN` substrings and sets `idle_idx`. When `idle_idx` exists: (1) the heuristic idle bypass synthesizes a 100% idle result, and (2) if the model's own top prediction is the idle class, `is_idle=true` is set on the inference result. When there is no idle class (`idle_idx is None`), the bypass returns an empty word with confidence 0. Clients must key off `is_idle`, never the word.
- `UploadModel` never overwrites live artifact files (Windows refuses replacing a memory-mapped model): each upload lands in `TSL_Output/uploads/<utc-ts>/` and `TSL_Output/active_model.json` points at the active set. Legacy layout (files directly in `TSL_Output/`) is the fallback when no manifest exists.
  - The manifest's `dir` is stored **POSIX-relative** to `TSL_Output/` on every host (`activate_artifacts` replaces `os.sep`), and the reader accepts either separator. Without that, `os.path.relpath` on a Windows dev box writes `uploads\<utc-ts>`, which a Linux deploy cannot resolve — it silently falls back to the legacy layout, so the two platforms serve **different models** from the same manifest while the admin UI reports the upload as active on both.
- Uploads are validated (interpreter loads, label map parses and matches class count, feature dim matches preprocess config) before the swap; on failure the previous model stays live.
- `ExtractKeypoints` is the ONLY keypoint-extraction path: the Go gateway image is a static binary with no Python, so it streams the clip here rather than exec'ing `extract_keypoints.py` (which it did until the extraction move — the old `SIGNMIND_KEYPOINT_PY`/`SIGNMIND_EXTRACT_SCRIPT` env vars are gone). It is offline and touches neither the interpreter nor any `InferenceSession`, so it cannot disturb a live stream — but it is CPU-heavy and shares the servicer thread pool, so a burst of admin recordings competes with inference for cores.
- MediaPipe lives in the `extract` extra (`pip install -e .[extract]`), not in `[project.dependencies]`: it is ~400 MB and only deployments serving `ExtractKeypoints` need it. Without it the service still starts and the RPC answers `FAILED_PRECONDITION` — never a crash at import. Every mediapipe up to 0.10.21 pins `protobuf<5` and so contradicts the stubs' `protobuf>=5.27`; the floor is `>=0.10.35`.
- The clip extension arriving in `ExtractInfo` names a temp file — it is checked against `ALLOWED_CLIP_EXTENSIONS` before use, never interpolated into a path as sent.
- Tuning values (`SetTuning`) are runtime-only; they reset to `preprocess_config.json` values on restart. `debug_mode` (optional bool in tuning/prediction) expands `top` breakdown to 10 entries and populates `other_prob`.
- Model input/output shape: `(1, sequence_len, feature_dim)` → `(1, num_classes)`; window length comes from the interpreter, not hard-coded.

---

## Work Guidance

- Run the service: `python -m inference.server` from `Inference_backend/` (listens on `SIGNMIND_AI_ADDR`, default `localhost:50051` — the gateway's default dial target).
- Windows runtime: the TFLite runtime (`ai-edge-litert` or `tensorflow`) ships no win_arm64 wheels — run the service under the **x64** venv at `Inference_backend/.venv-x64` (what `dev.ps1` prefers; recreate with `<x64 python> -m venv .venv-x64` then `pip install grpcio numpy protobuf ai-edge-litert mediapipe`). Tests and `ruff` run fine on arm64 (the fake interpreter avoids the runtime, and the `ExtractKeypoints` tests fake the extractor rather than importing MediaPipe).
- Sign recording in local dev needs `mediapipe` in that same x64 venv — it is what serves `ExtractKeypoints`. Without it the admin Dictionary page's recorder fails with a 422 whose detail names the missing module. On first extraction the landmarker `.task` models (~16 MB) download into the service's working directory; the Docker image bakes them in at build time instead, so the running container never reaches the network for them.
- Regenerate stubs after any `docs/api/tsl_inference.proto` change (from repo root; needs `grpcio-tools` and, for Go, `protoc-gen-go` v1.36.11 + `protoc-gen-go-grpc` v1.6.2 in `~/go/bin`):
  ```
  python -m grpc_tools.protoc -I docs/api \
    --plugin=protoc-gen-go=$HOME/go/bin/protoc-gen-go.exe --go_out=Backend/internal/pb --go_opt=paths=source_relative \
    --plugin=protoc-gen-go-grpc=$HOME/go/bin/protoc-gen-go-grpc.exe --go-grpc_out=Backend/internal/pb --go-grpc_opt=paths=source_relative \
    --python_out=Inference_backend/inference/pb --pyi_out=Inference_backend/inference/pb --grpc_python_out=Inference_backend/inference/pb \
    docs/api/tsl_inference.proto
  ```
  then fix the generated Python import to be package-relative:
  ```
  sed -i 's/^import tsl_inference_pb2 as/from . import tsl_inference_pb2 as/' Inference_backend/inference/pb/tsl_inference_pb2_grpc.py
  ```
- Threading: the engine guards the interpreter + tuning with one lock (interpreters are not thread-safe; `UploadModel` may swap mid-stream). Each gRPC stream gets its own `InferenceSession` window — never share sessions across streams.
- New RPCs: extend the proto first, regenerate stubs, then implement — never hand-edit `inference/pb/`.

---

## Verification

- Root mandate: `cd Inference_backend && ruff check && pytest` whenever Python code here is touched.
- Tests must not require the TFLite runtime, a model file, or the network (bind test servers to `localhost:0`).

---

## Child DOX Index

None. Create child docs if `training/` or `evaluation/` are rebuilt here.
