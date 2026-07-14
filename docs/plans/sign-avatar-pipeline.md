# Plan — Real Sign Example via Avatar (dictionary + AI conversation)

Status: **APPROVED FOR PHASE 1 pending green-light** · Author session: 2026-07-13 · Owner-facing plan for other agents.

This document is the single source of truth for the "Sign Example via Avatar" feature. Read it
top to bottom before touching any file in its scope. It complements — never overrides — the DOX
chain (`Agents.md` + child `AGENTS.md`) and `CLAUDE.md` guardrails.

---

## 1. Goal

Make the app show a **real** sign demonstration through the skeletal `SignAvatar`:

- **Dictionary** (Learn tab): each word's avatar plays real recorded keypoint frames instead of the
  procedural placeholder.
- **AI conversation**: the avatar signs the AI's reply like a real signer; the text transcript is
  **hidden by default** so the user practices reading the sign, revealable per message.
- **Admin webui**: an operator **records a sign in-browser** (webcam), uploads it, and the Go backend
  runs a Python script to **extract keypoints** that both surfaces above consume.

## 2. Locked design decisions (confirmed with the user)

1. **Extraction transport:** Go execs a standalone Python CLI (`extract_keypoints.py`) via `os/exec`.
   Rationale: extraction from a recorded clip is an offline batch job, not the realtime landmark
   stream, so it stays off the gRPC path and leaves the realtime service untouched. Fallback if the
   x64/MediaPipe environment proves unworkable: a gRPC `ExtractKeypoints` RPC on the inference service.
2. **Admin capture:** in-browser webcam recording (MediaRecorder) → preview → upload the clip.
3. **Conversation signing source:** backend **stitches each gloss word's recorded keypoint frames**
   from the shared dictionary library into one sequence. Missing words are skipped (client renders the
   procedural fallback for them). Dictionary and conversation share ONE recorded library.
4. **Conversation UX:** avatar-forward. Transcript (reply text + gloss) hidden by default, one toggle
   per AI message reveals it. TTS "ฟังเสียง" stays.

## 3. Current state of the code (verified by reading, 2026-07-13)

- `SignAvatar` renders `[[{x,y,z}…]…]` frames or a procedural placeholder —
  `Frontend/lib/features/learn/presentation/widgets/sign_avatar.dart`. It expects the 7-point pose
  order `[nose, Lshoulder, Rshoulder, Lelbow, Relbow, Lwrist, Rwrist]` followed by hand points.
  Frames with `<7` points currently draw as bare dots (see Phase 1 fallback fix).
- Table `learn_signs(word PRIMARY KEY, category, keypoint_frames TEXT)` and
  `GET /api/v1/learn/dictionary/{word}` already store/serve frames —
  `Backend/internal/learn/store.go`, `Backend/internal/learn/handler.go`.
  **There is no admin CRUD for signs yet** (only topics/exercises).
- Dictionary already mounts the avatar in a bottom sheet (`_SignDetailAvatar`) —
  `Frontend/lib/features/learn/presentation/screens/learn_screen.dart`. It shows procedural output
  today because no real `keypoint_frames` data exists.
- Conversation returns a **stub** `keypoint_transitions` (2 points × 2 frames) and the Flutter screen
  renders **only the gloss text chip — no avatar** —
  `Backend/internal/conversation/conversation.go` (`buildReply`),
  `Frontend/lib/features/conversation/presentation/screens/conversation_screen.dart`.
- The exact extraction math to reuse lives in `Inference_backend/tsl_live_inference.py`
  (pose landmark indices `[0,11,12,13,14,15,16]`; hands 2×21, MediaPipe VIDEO mode).
- Admin webui is Next.js (`Backend/webui/app/*`); model uploads already exist at `app/upload/page.tsx`;
  learn admin CRUD pattern at `app/learn/page.tsx`; API client in `Backend/webui/lib/api.ts`.
- Server wiring is `Backend/cmd/server/main.go` (routes registered on a `http.ServeMux`).

### Load-bearing contract detail
The **classifier** normalizes landmarks to shoulder-center / shoulder-width (person-invariant). The
**avatar** needs **raw normalized image coordinates (0–1)** so the figure sits in frame. Therefore
`extract_keypoints.py` emits a *different, simpler* transform than the training pipeline — do not reuse
`tsl_preprocess.preprocess_sequence` for avatar output.

---

## 4. Phases

Each phase ends with its own green check. Do not start a phase before the prior one is green. Post a
`TASK` block (per `docs/guardrails/PLAN.md` P4) before the first Edit of each phase.

### Phase 1 — Conversation avatar UX (frontend only; zero backend/ARM64 risk)

**Goal:** AI replies sign via the avatar; transcript hidden by default with a per-message reveal.

- FILES:
  - `Frontend/lib/features/conversation/presentation/screens/conversation_screen.dart` (edit AI bubble)
  - `Frontend/lib/features/learn/presentation/widgets/sign_avatar.dart` (fallback fix)
  - `Frontend/test/features/conversation/conversation_screen_test.dart` (new)
- Behavior: AI bubble shows `SignAvatar(word: signGloss, frames: keypointTransitions)` prominently;
  reply text + gloss collapse behind a "แสดงข้อความ / ซ่อนข้อความ" toggle (default hidden). User
  bubbles unchanged. Keep the TTS control.
- Fallback fix: `SignAvatar` should treat frames with `<7` points as no-data → procedural figure
  (today it draws bare dots). Makes the current 2-point stub look correct until real data lands.
- ASSUMPTION: hidden default hides BOTH reply text and gloss (maximizes sign-reading practice); one
  toggle reveals both. Revisit if the gloss should always show.
- DONE-WHEN: `cd Frontend && flutter analyze && flutter test` clean; avatar animates in AI bubble;
  transcript toggles.
- EST: ~90 lines across 3 files.

### Phase 2 — Keypoint extraction pipeline (backend + Python)

**Goal:** an admin can attach real keypoint frames to a dictionary word from a recorded clip.

Split into ordered steps, each with its own check (total exceeds 150 lines):

- **2a. `Inference_backend/extract_keypoints.py`** (new CLI)
  - Signature: `extract_keypoints.py <video_path> [--frames 16]` → stdout JSON
    `[[{x,y,z}, … 7 pose then hand points …], … N frames]` in **raw normalized 0–1** coords, in the
    `SignAvatar` order.
  - Reuses MediaPipe Pose+Hands (VIDEO mode) as in `tsl_live_inference.py`; downsamples to N frames.
  - Structure the pure `landmarks → avatar-frame-order + downsample` transform as its own function so
    it is unit-testable **without** mediapipe/cv2 (tests pass synthetic landmark arrays).
  - Check: `cd Inference_backend && ruff check && pytest` (+ a smoke/dry-run of the CLI arg parse).
- **2b. `Backend/internal/keypoint/`** (new package)
  - `Extractor` runs `exec.CommandContext(ctx, python, script, videoPath)` with timeout + temp-file
    cleanup; parses/validates the JSON. The command runner is an injected interface so tests use a
    fake (no Python needed).
  - Check: `cd Backend && go test ./internal/keypoint/...`.
- **2c. `Backend/internal/learn/store.go`** (extend)
  - Add `UpsertSign(word, category)`, `SetKeypointFrames(word, json.RawMessage)`, `DeleteSign(word)`.
  - Check: `go test ./internal/learn/...`.
- **2d. `Backend/internal/learn/handler.go` + `Backend/cmd/server/main.go`** (extend + wire)
  - Admin routes (admin role, matching existing stacking):
    `GET /api/v1/admin/learn/signs`, `POST /api/v1/admin/learn/signs` (upsert word+category),
    `POST /api/v1/admin/learn/signs/{word}/recording` (multipart video → extractor → SetKeypointFrames),
    `DELETE /api/v1/admin/learn/signs/{word}`.
  - Inject the `keypoint.Extractor` into the learn `Handler`.
  - Config keys (in `Backend/internal/config`): `SIGNMIND_KEYPOINT_PY` (x64 python path),
    `SIGNMIND_EXTRACT_SCRIPT` (path to `extract_keypoints.py`).
  - Check: `go vet ./... && go test ./...`.
- DONE-WHEN: all sub-checks green; live: upload clip → `GET /api/v1/learn/dictionary/{word}` returns
  frames; dictionary avatar plays them.
- EST: ~320 lines across ~7 files.

### Phase 3 — Admin recording page (Next.js webui)

**Goal:** in-browser record → upload UX to build the library.

- FILES:
  - `Backend/webui/app/dictionary/page.tsx` (new) — modeled on `app/learn/page.tsx`: list signs with a
    `has_animation` badge; create sign (word + category); **record via MediaRecorder** (start/stop/
    preview); upload to the recording endpoint; delete.
  - `Backend/webui/lib/api.ts` — add `fetchAdminSigns`, `createSign`, `uploadSignRecording` (FormData),
    `deleteSign`.
  - `Backend/webui/app/layout.tsx` — add a nav link.
- DONE-WHEN: `cd Backend/webui && npm run build` ok; manual: record → upload → badge flips to
  "has animation".
- EST: ~250 lines across 3 files.

### Phase 4 — Gloss → keypoint stitching (conversation realism)

**Goal:** the conversation avatar signs the actual sentence from recorded words.

- FILES:
  - `Backend/internal/conversation/conversation.go` — replace the stub. `Handler` takes a lookup
    (`func(word string) (json.RawMessage, bool)`) backed by the learn store; split `reply_sign_gloss`
    into words; concatenate each word's `keypoint_frames` (short rest gap between); return as
    `keypoint_transitions`. Missing word → skipped. Keep conversation decoupled from learn via the
    interface (no direct import).
  - `Backend/cmd/server/main.go` — wire the lookup.
  - `Backend/internal/conversation/conversation_test.go` — stitch test with a fake lookup.
- DONE-WHEN: `go vet ./... && go test ./...` green; live: recorded words in a reply animate as a
  sequence.
- EST: ~120 lines across ~3 files.

---

## 5. Tests (per DOX "Test Creation Mandate")

- **Go:** learn store (upsert / set frames / delete), learn handler (admin sign endpoints, recording
  with a fake extractor injected), keypoint extractor (fake command runner), conversation stitching
  (fake lookup). Verify: `go vet ./... && go test ./...`.
- **Python:** `Inference_backend/tests/test_extract_keypoints.py` covering the pure transform with
  synthetic landmarks (no mediapipe/cv2 runtime — mirror the existing fake-interpreter approach).
  Verify: `ruff check && pytest`.
- **Flutter:** conversation screen widget test (avatar present for AI msg with frames; transcript
  hidden by default; toggle reveals), sign_avatar `<7`-point fallback test. Verify:
  `flutter analyze && flutter test`.

## 6. DOX / docs updates (per `Agents.md` Closeout Checklist)

- `docs/api/` — document the admin sign + recording endpoints; note conversation
  `keypoint_transitions` is now stitched from the recorded library.
- `Backend/AGENTS.md` — new `internal/keypoint` package + admin sign endpoints.
- `Inference_backend/AGENTS.md` — `extract_keypoints.py` ownership + x64/MediaPipe runtime note.
- `Frontend/AGENTS.md` — conversation avatar + transcript-hidden behavior.
- `docs/STATE.md` — new goal/next each phase.
- Landing registry: this **enhances existing features** (dictionary, conversation), not a brand-new
  feature, so no new landing card is expected — confirm during closeout.

## 7. ⚠️ Top risk — verify before writing Phase 2 code

The service x64 venv (`.venv-x64`) currently holds only `grpcio numpy protobuf ai-edge-litert`
(`Inference_backend/AGENTS.md`). Extraction additionally needs **`mediapipe` + `opencv-python`**, and
Windows/ARM64 has no wheels for some of these — the CLI must run under **x64 Python**.
`tsl_live_inference.py` imports both, so they are presumably installable on x64, but the FIRST action
of Phase 2 is to confirm a working x64 env and that Go can invoke it. If not viable, switch to the
gRPC `ExtractKeypoints` fallback (decision #1).

## 8. Sequencing recommendation

Phase 1 first (pure frontend, immediate runnable demo), then 2 → 3 → 4 for the real-data path, each
behind its own green check. Never carry more than one failing step at a time
(`docs/guardrails/PLAN.md` P6).
