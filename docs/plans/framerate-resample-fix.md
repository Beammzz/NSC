# Plan — Frame-rate-invariant inference (fix "same sign, ~60% wrong")

Status: **READY FOR IMPLEMENTATION** · Author session: 2026-07-15 · Owner-facing plan for other agents.

This document is the single source of truth for fixing realtime-scanner misclassification caused by a
capture-rate vs training-rate mismatch. Read it top to bottom before touching any file in its scope.
It complements — never overrides — the DOX chain (`Agents.md` + child `AGENTS.md`) and `CLAUDE.md`
guardrails. Post a `TASK` block (per `docs/guardrails/PLAN.md` P4) before the first Edit of each part.

---

## 1. Problem & root cause (verified by reading, 2026-07-15)

Users report: on a Redmi Note 12 5G, doing the *same* sign at the *same* position/angle yields a
prediction that is ~60% wrong, and the pose overlay is laggy (7–9 fps) when both hands are tracked.

The accuracy failure is **not** a MediaPipe model-quality problem and is **not** fixable by a bigger /
"full f32" landmark model:

- There is **no float32 `.task`** for either landmarker — Google publishes float16 only (confirmed on
  the current pose & hand model cards). f16 is effectively lossless for landmark regression.
- The **hand** landmarker has exactly one published variant; the app already uses it. (`docs/STATE.md`
  perf notes already established this.)
- The classifier uses pose for only **7 coarse joints** (shoulders/elbows/wrists) as the normalization
  anchor — 21 of 147 position dims (`Frontend/lib/features/scanner/data/services/feature_vector_builder.dart`).
  `pose_landmarker_lite` already localizes those big joints well; `pose_landmarker_full` was already
  `git rm`'d from the frontend for being too slow (`docs/STATE.md`).

**Actual root cause — a temporal-distribution mismatch:**

- The LSTM was trained on clips resampled to **12 fps** (30 fps video → downsampled). A 30-frame window
  therefore spans **2.4167 s** of motion.
- Velocity + acceleration are **294 of the model's 441 input dims (67%)** and are computed as raw
  per-frame differences with **no `dt` normalization**:
  `velocity = np.diff(positions, axis=0, prepend=positions[:1])`
  — `Inference_backend/tsl_preprocess.py:151`.
- The scanner runs at **7–9 fps** (documented two-hand floor on this GPU — `docs/STATE.md` "Next (perf
  task)"), so each delta arrives ~1.5–1.7× larger than training and the window spans ~3.5 s instead of
  2.4 s. Feeding a temporal model out-of-distribution values on two-thirds of its inputs produces
  confident misclassification.

**Fix:** resample each inference window onto the training 12 fps grid before it reaches the model, so
the delta features become capture-rate-invariant.

## 2. Key discovery that shrinks scope — timestamps already flow end-to-end

The per-frame capture time the resampler needs is **already transmitted the whole way and only dropped
at the final step**:

| Hop | Carries timestamp? | Evidence |
|---|---|---|
| Flutter → WS | yes (`timestamp_ms`) | `Frontend/lib/features/scanner/data/services/tsl_stream_service.dart:283` |
| Go parse | yes (`TimestampMS int64`) | `Backend/internal/stream/messages.go:28` |
| Go → gRPC | yes (copies it) | `Backend/internal/stream/handler.go:156` |
| Proto contract | yes (`int64 timestamp_ms = 2`) | `docs/api/tsl_inference.proto:44` |
| **Python server** | **NO — ignored** | `Inference_backend/inference/server.py:83-87` reads `features`/`seq`/`reset` only; `Inference_backend/inference/engine.py:451` `add_frame(position)` is a plain `deque(maxlen=30)` with no timing |

Therefore the **accuracy fix is Python-only**: no proto change, no Go change, **no wire/schema-version
bump**, no Flutter change. This is the plan's backbone and its main de-risking fact.

## 3. Current state of the relevant code (verified by reading)

- `InferenceSession` (`Inference_backend/inference/engine.py:439-462`) is a `deque(maxlen=30)` of raw
  `(147,)` position frames; `add_frame(position)` appends and, once 30 frames exist, calls
  `predict_window`. No timestamp awareness.
- `predict_window` (`engine.py:336-436`) runs the idle bypass, `preprocess_sequence`, the interpreter,
  the uncertainty gate, and top-k. It requires exactly `sequence_len` (30) frames. **It needs no change
  under this plan** — it just needs to receive a uniformly-sampled window.
- `preprocess_sequence` / `_normalize_hands` (`tsl_preprocess.py:102-156`): person-invariant hand
  normalization + raw `np.diff` deltas. Shared by training and inference. **No change** — deltas become
  correct once the window is uniform.
- `StreamInference` servicer (`Inference_backend/inference/server.py:65-116`) slices the position block
  and calls `session.add_frame(position)`; `frame.timestamp_ms` is available on the message but unused.
- Config loads from `preprocess_config.json` merged over `DEFAULT_PREPROCESS_CONFIG`
  (`tsl_preprocess.py:51-58`); the config ships with the model via `UploadModel`
  (`FILE_KIND_PREPROCESS_CONFIG`).
- **Perf reality (`docs/STATE.md`):** two-hand tracking is a ~8.8–9 fps floor on the Adreno 619 (hand
  70–98 ms; only one hand model exists). `pose_landmarker_full.task` was removed from the frontend.
  12.1 fps was only reached with **no hands in frame**. So Part B below has limited headroom and Part A
  is what makes the unavoidable ~9 fps accurate.

### Load-bearing detail
Absent hands are **zero-filled** upstream (`feature_vector_builder.dart`; `tsl_preprocess._normalize_hands`
treats "any coord ≠ 0" as present). Any resampling MUST NOT linearly blend a present hand against a
zero-filled absent hand — that invents a landmark drifting toward the origin and corrupts both the
features and the idle bypass. See A2 presence-gating rule.

---

## 4. Part A — Accuracy fix (Python inference service only)  ← the essential fix

### A0. Baseline (run first)
`cd Inference_backend && ruff check && pytest` → record `BASELINE: <pass | N failing: names>`.
Do not proceed on an already-red baseline without reporting it.

### A1. Add the training frame rate to preprocess config
**File:** `Inference_backend/tsl_preprocess.py`
- Add `"target_fps": 12` to `DEFAULT_PREPROCESS_CONFIG` (~line 51). It is a training-time property that
  must travel with the model; real configs lacking the key inherit 12. `feature_dim()` is unaffected
  (delta block count unchanged).

### A2. Add a pure resample helper (testable with no runtime)
**File:** `Inference_backend/tsl_preprocess.py` (new function, mirror the pure-helper style of
`downsample`/`landmarks_to_frame`)

`resample_window(frames, timestamps_ms, target_len, target_interval_ms) -> np.ndarray | None`
- Build a uniform grid of `target_len` (=30) timestamps ending at the newest frame, spaced
  `target_interval_ms` (=1000/target_fps ≈ 83.333 ms): `t_k = t_latest - (target_len-1-k)*interval`.
- **Return `None` if the buffer's earliest timestamp is later than `t_0`** (insufficient history) — we
  only ever *interpolate*, never *extrapolate*.
- Pose block (`[0,21)`): linear interpolation per dim between the two bracketing real frames.
- **⚠️ Presence-gated hand interpolation (the one genuine correctness trap).** For each hand block
  (left `[21,84)`, right `[84,147)`) at a grid point: interpolate linearly **only if both bracketing
  real frames have that hand present** (any coord ≠ 0); otherwise copy the block from the **temporally
  nearest** real frame (preserving zeros when that frame's hand is absent).
- Guard non-monotonic/duplicate timestamps (clamp to strictly increasing) so no divide-by-zero.
- Pure — no mediapipe/cv2/tflite import.

### A3. Make the session timestamp-aware and resample before predicting
**File:** `Inference_backend/inference/engine.py` — `InferenceSession` (lines 439-462)
- Replace the raw `deque(maxlen=30)` of frames with a **timestamped ring buffer** of
  `(timestamp_ms, position[147])`. Size it by duration, not count — keep enough to always cover one
  window plus margin (e.g. last ~90 frames; small over-allocation is harmless).
- New signature: `add_frame(self, position_features, timestamp_ms) -> PredictionResult | None`.
  - Append `(timestamp_ms, frame)`.
  - `target_len = engine.config["sequence_length"]`; `target_interval_ms = 1000/engine.config["target_fps"]`.
  - Call `resample_window(...)`; if `None` (cold start / insufficient span) return `None`.
  - Else pass the resampled `(30,147)` array to `engine.predict_window(...)` unchanged.
- `reset()` clears the timestamped buffer.
- **Do not touch** `predict_window`, the idle bypass, or `preprocess_sequence` — they now receive an
  in-distribution, uniformly-spaced window.

### A4. Pass the timestamp through the servicer
**File:** `Inference_backend/inference/server.py` — `StreamInference` (lines 65-91)
- Change `session.add_frame(position)` → `session.add_frame(position, frame.timestamp_ms)`.
  `frame.timestamp_ms` is already on the proto message; nothing else changes here.

### A5. Tests (mirror `tests/test_preprocess.py`, `tests/test_engine.py`; fakes in `tests/fakes.py`)
- **`resample_window` units:** output length 30 and correct spacing; `None` on insufficient span;
  linear interpolation correctness on a known ramp; **presence gating** — a window where the right hand
  first appears midway must never contain a half-origin right-hand block.
- **fps-invariance property test (the acceptance proof):** synthesize constant-velocity motion sampled
  at 8 fps and at 12 fps; assert that after `resample_window` + `preprocess_sequence` the velocity
  feature block matches within tolerance. This directly proves the 60% bug is closed.
- **Engine session test** (fake interpreter): feed timestamped frames at simulated 8 fps; assert the
  window handed to the interpreter is 30×147 and predictions start only once span ≥ window duration.
- Verify: `cd Inference_backend && ruff check && pytest`.

**TASK BLOCK A**
```
GOAL: Resample each inference window onto the model's native 12fps grid using the timestamps already on
      every frame, so mobile capture-rate stops corrupting the velocity/acceleration features.
FILES: Inference_backend/tsl_preprocess.py, Inference_backend/inference/engine.py,
       Inference_backend/inference/server.py, Inference_backend/tests/test_preprocess.py,
       Inference_backend/tests/test_engine.py
EST: ~180 changed lines across 5 files
DONE-WHEN: cd Inference_backend && ruff check && pytest (incl. new fps-invariance test) green; a sign
           fed at simulated 8fps and 12fps yields matching predictions.
CONSTRAINTS: No proto/Go/Flutter/wire changes (timestamp already flows). Do not weaken/skip any existing
             test. predict_window / preprocess_sequence / idle bypass stay behaviorally unchanged for a
             uniformly-sampled window.
```
> >3 files / ~150 lines → per `docs/guardrails/PLAN.md` P6 run as ordered steps A1→A2→A3→A4→A5, with
> `pytest` between A3 and A5. Never carry more than one failing step at a time.

## 5. Part B — Performance (Android only; limited headroom, do after/independent of A)

Honest expectation from `docs/STATE.md`: two-hand tracking is a ~9 fps floor on this GPU because the
single hand model runs 70–98 ms/frame; there is no faster hand variant. Part B recovers a little and
makes the rate observable, but **will not reach 12 fps with two hands** — that is why Part A exists.

### B1. Refresh pose less often
**File:** `Frontend/android/app/src/main/kotlin/com/signmind/signmind/CameraPreviewView.kt`
- Pose feeds only slow-moving shoulder normalization + torso overlay and already runs every 3rd frame
  reusing `lastPoseResult` (`POSE_FRAME_STRIDE = 3`, line 323). Raise to **6** (pose refresh ~1.5–2×/s,
  ample for shoulders) to hand GPU time back to the hand landmarker. Verify overlay still tracks.

### B2. Instrument true throughput
- Extend the existing per-frame `Log.d(TAG, "frame ms: …")` (line 170) with a rolling frames-per-second
  counter (frames emitted in the last 1 s) so the real on-device rate is observable via
  `adb logcat -s SignMindCamera` before/after B1.

### B3. (Optional, measure-first) analysis resolution
- Lowering `ImageAnalysis` resolution speeds palm detection but **shrinks hands in-frame and hurts the
  landmark quality Part A depends on.** Only consider if B1 falls short, and re-measure hand stability.

### B4. (Larger, optional) LIVE_STREAM pipelining
- `docs/STATE.md` estimates overlapping hand+pose via MediaPipe LIVE_STREAM mode could add ~+1 fps. This
  is a redesign, not a config tweak — out of scope here; note it as the only real path above ~9 fps.

**TASK BLOCK B**
```
GOAL: Raise realtime scanner throughput toward 12fps by refreshing the cheap pose model less often, and
      make the true fps observable.
FILES: Frontend/android/app/src/main/kotlin/com/signmind/signmind/CameraPreviewView.kt
EST: ~15 changed lines, 1 file
DONE-WHEN: cd Frontend && flutter analyze && flutter test green; adb logcat shows sustained fps above the
           prior 7–9 with pose active; overlay still tracks the torso.
CONSTRAINTS: Keep 2-hand tracking. Keep the 12fps intake cap. Do not lower analysis resolution without
             re-measuring hand quality (B3).
```
> `flutter analyze`/`flutter test` do not exercise Kotlin; final verification is a device run
> (`adb devices`; if none, `flutter build apk` for manual testing — CLAUDE.md).

## 6. Part C — Optional hardening (separate, lower priority)

- **C1 — Fix the desktop reference.** `Inference_backend/tsl_live_inference.py:291` appends *every*
  webcam frame (~30 fps) → OOD in the opposite direction, so it is not trustworthy ground truth. Apply
  the same 12 fps resampling (reuse `resample_window`) so it matches training.
- **C2 — Capture-time timestamps.** Dart stamps `timestamp_ms` at *send* time
  (`tsl_stream_service.dart:283`), not capture time. Propagating the Android `SystemClock` capture time
  through the EventChannel frame → Dart → WS gives cleaner resampling. Send-time is acceptable for v1.

## 7. Risks / watch-items
1. **Presence-gated interpolation (A2)** is the one genuine correctness trap — get it and its test right,
   or you trade the fps bug for a phantom-hand bug.
2. **Residual accuracy floor:** `tsl_preprocess.py` self-flags (module docstring, lines 3-12) that its
   hand-normalization FORMULAS are **assumptions** reconstructed after a repo split. If accuracy is still
   off after Part A, the next suspect is formula parity with the original training code — a separate
   investigation needing the training repo, not this plan.
3. **Idle bypass** thresholds were tuned on 12 fps data; running them on the resampled 12 fps grid keeps
   them valid — but re-check idle behavior after A3.
4. **Cold-start latency:** first prediction now waits for frames spanning ≥2.42 s (was: 30 frames). At
   8 fps that's ~20 real frames — comparable, slightly different. Confirm acceptable.

## 8. File change summary
| File | Part | Change |
|---|---|---|
| `Inference_backend/tsl_preprocess.py` | A | `target_fps` config + pure `resample_window` |
| `Inference_backend/inference/engine.py` | A | timestamped buffer + resample in `InferenceSession.add_frame` |
| `Inference_backend/inference/server.py` | A | pass `frame.timestamp_ms` to `add_frame` |
| `Inference_backend/tests/test_preprocess.py`, `test_engine.py` | A | resample + fps-invariance tests |
| `Frontend/android/.../CameraPreviewView.kt` | B | `POSE_FRAME_STRIDE` 3→6 + fps logging |
| `Inference_backend/tsl_live_inference.py` | C | resample reference to 12 fps (optional) |
| Flutter EventChannel + Dart send path | C | propagate capture timestamp (optional) |

## 9. Sequencing recommendation
Do **Part A first** — it is the fix for the reported 60% error and is fully server-side/Python-only, so
it carries no proto/Go/Flutter risk and is unit-provable (the fps-invariance test). Part B is a small,
independent quality-of-life change with limited headroom. Part C is optional hardening. Verify each part
behind its own green check; per `docs/guardrails/VERIFY.md`, claim "fixed" only beside fresh command
output.
