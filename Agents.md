# DOX framework — SignMind AI

- DOX is a binding AGENTS.md hierarchy installed at the project root
- Agent must follow DOX instructions across all edits
- Re-read the full DOX chain before touching any file in a given session

---

## Project Overview

**SignMind AI** is a cross-platform mobile application (Flutter / Dart) that translates Thai Sign Language (TSL) into text and speech in real-time, acts as a personalized AI Sign Language Tutor, and provides a Conversational AI bridge between deaf users and hearing individuals.

**Target platforms:** Android 9+ · iOS 13+
**Primary users:** Deaf/hard-of-hearing individuals, sign language learners, general public
**Core stack:** Golang (backend gateway) · Flutter + Dart (frontend mobile client) · Python (AI training & server-side LSTM inference engine) · RESTful & WebSocket API

---

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- All source code, model artifacts, data pipelines, and documentation must remain understandable from the nearest applicable AGENTS.md plus every parent above it
- No child AGENTS.md may override or weaken DOX global rules
- Read CLAUDE.md for more guardrails or instructions

---

## Read Before Editing

1. Read this root AGENTS.md fully
2. Identify every file or folder you expect to touch
3. Walk from the repo root to each target path and read every AGENTS.md along the route
4. Consult the Child DOX Index to identify the owning child doc for the target area
5. Use the nearest AGENTS.md as the local contract; parent docs supply repo-wide rules
6. If docs conflict, the closer doc controls local details — but never weakens DOX
7. **Mandatory Child DOX Read**: Every time the Agent needs to change content in `Frontend/`, `Backend/`, or `Inference_backend/`, it MUST read the corresponding child AGENTS.md every time before editing.
8. **Missing Child DOX Fallback**: If a child AGENTS.md listed in the Child DOX Index does not exist yet, the Agent MUST create it first (following the Child Doc Shape) before editing any code in that subtree. Never skip the read step because the doc is missing.
9. **Mandatory Guardrails Read**: Read CLAUDE.md for more guardrails or instructions before editing any file or executing tasks.

Do not rely on memory. Re-read the applicable DOX chain and CLAUDE.md at the start of every session.

---

## Repository Layout

```
signmind-ai/
├── Agents.md                  ← this file (root DOX)
├── Frontend/                  ← Flutter mobile application
│   ├── AGENTS.md              ← Flutter / Dart contracts
│   ├── pubspec.yaml
│   └── lib/                   ← Flutter app source
├── Backend/                   ← Golang REST & WebSocket API server
│   ├── AGENTS.md              ← Golang backend contracts
│   ├── go.mod
│   ├── cmd/                   ← application entrypoints
│   └── internal/              ← business logic, API handlers, AI service client
├── Inference_backend/         ← Python AI inference service (replaces the former ai/ tree)
│   ├── AGENTS.md              ← AI/ML contracts
│   ├── tsl_preprocess.py      ← training-matching preprocessing (reconstruction)
│   ├── tsl_live_inference.py  ← webcam demo / reference implementation
│   ├── inference/             ← gRPC inference service (engine, server, logstream, pb stubs)
│   ├── TSL_Output/            ← model artifacts (tflite, label_map, preprocess_config, uploads)
│   └── tests/                 ← pytest suite (fake interpreter — no TFLite runtime needed)
└── docs/                      ← project documentation
    └── AGENTS.md              ← documentation contracts
```

Training and evaluation pipelines from the former `ai/` tree were lost in the
repository split and are not yet rebuilt; recreate them under
`Inference_backend/` (`training/`, `evaluation/`) when needed.

---

## Global Contracts

### AI / Model Targets
| Metric | Minimum |
|---|---|
| TSL recognition accuracy | ≥ 85% (target: 89.4%) |
| End-to-end translation latency | ≤ 1.5 s / gesture (target: 1.2 s) |
| Gesture Accuracy Detection module | ≥ 90% (target: 91.2%) |
| Speech Recognition accuracy | ≥ 90% (target: 92.7%) |
| Vocabulary coverage | 200 basic TSL words |

**Latency measurement definition:**
- End-to-end latency is measured from the timestamp of the *last frame of a gesture captured on-device* to the timestamp the *translated text is rendered in the Flutter UI*.
- This includes: on-device landmark extraction, WebSocket network transit, backend forwarding, Python inference, and response delivery. Nothing is excluded.
- Benchmarks in `Inference_backend/evaluation/` (to be rebuilt) must report p50 and p95 latency under a reference network condition (4G, ~50 ms RTT) and note the test device model.

### Feature Vector Spec (single source of truth)
- Hands: 2 hands × 21 MediaPipe hand landmarks × 3 coords (x, y, z) = 126
- Pose: 7 landmarks (Nose, L/R Shoulder, L/R Elbow, L/R Wrist) × 3 coords = 21
- Position features: 126 + 21 = **147**
- Full feature vector: position + velocity + acceleration = 147 × 3 = **441 dims**
- Any code, doc, or comment referencing feature dimensions must match this spec exactly. Child docs must reference this section instead of restating numbers.

### Flutter / Dart Rules
- State management: Riverpod only — no Provider, no setState at feature level
- Navigation: GoRouter only
- Naming: `snake_case` files, `PascalCase` classes, `camelCase` variables
- Each feature lives in `Frontend/lib/features/<name>/` with its own `presentation/`, `domain/`, `data/` layers
- Real-time recognition (scanner & tutor) extracts pose + hand landmarks locally and streams feature vectors via WebSocket to the Golang backend. The feature vector layout is defined in the Feature Vector Spec above — do not restate numbers here.
- Conversational AI connects via REST/WebSocket API (`/api/v1/conversation`); Speech Recognition (STT) and Text-to-Speech (TTS) run on-device on the mobile client.
- **Verification Mandate**: Whenever Flutter code is touched, the Agent MUST run `flutter analyze` and `flutter test`.
- **Test Creation Mandate**: When developing a new feature, the Agent MUST create a corresponding test file so that future bug fixes cause less damage to production.

### Python / AI Pipeline Rules
- Train exclusively on Python 3.10+ with TensorFlow ≥ 2.13 or PyTorch ≥ 2.1
- MediaPipe Hands v0.10+ for hand landmark extraction; MediaPipe Pose for the 7 upper-body pose landmarks. Combined output must conform to the Feature Vector Spec above.
- **Data leakage rule:** GroupShuffleSplit by `video_session_id` before any augmentation — never split after augmentation
- Server inference model format: SavedModel / ONNX / PyTorch exported models deployed to the Python inference worker
- Quantization: INT8 / FP16 optimization for server inference throughput
- All training runs must log: epoch, loss, val_loss, accuracy, val_accuracy, confusion matrix on test split
- **Verification Mandate**: Whenever Python code in `Inference_backend/` is touched, the Agent MUST run `ruff check` and `pytest` on the affected package. Training scripts without unit tests must at minimum pass `ruff check` and a dry-run/smoke invocation.

### API / Backend Rules
- Golang (Go 1.22+) backend architecture
- RESTful JSON over HTTPS + WebSockets over WSS for real-time sign stream processing
- Auth: JWT (access + refresh token pair)
  - Access token lifetime: 15 minutes; refresh token lifetime: 30 days
  - Refresh tokens are stored server-side (hashed) and are revocable; logout invalidates the refresh token
  - Tokens are transmitted only via HTTPS/WSS; never in URL query parameters
- Real-time TSL translation frames are streamed to `/api/v1/stream`; backend forwards landmark sequences to the internal Python AI service via **gRPC** (bidirectional streaming). HTTP fallback is not permitted for the landmark stream path.
- The WebSocket message payload schema for `/api/v1/stream` is versioned and defined in `docs/api/stream-schema.md`; every payload includes a `schema_version` field. Breaking changes require a version bump and a DOX update.
- NLP and Conversational AI bridge calls go through `/api/v1/conversation` (returns `reply_text`, `reply_sign_gloss`, and server-generated `keypoint_transitions` with LLM auto-correction for client avatar rendering); STT and TTS execute on-device on the client
- Error responses follow RFC 7807 (Problem Details for HTTP APIs)
- Sensitive user progress data must never be logged in plain text
- **Verification Mandate**: Whenever Go code is touched, the Agent MUST run `go vet ./...` and `go test ./...`.

### Version Control
- All code managed via Git + GitHub
- Branch naming: `feature/<name>` · `fix/<name>` · `model/<name>` · `data/<name>`
- No direct commits to `main`; PRs required
- Commit messages: `<type>(<scope>): <summary>` (Conventional Commits)

---

## Update After Editing

Every meaningful change requires a DOX pass before the task is complete.

Update the closest owning AGENTS.md when a change affects:
- purpose, scope, ownership, or module responsibilities
- model architecture, feature engineering, or accuracy targets
- API contracts, endpoint signatures, or auth flow
- Flutter widget hierarchy, state management approach, or routing
- required inputs, outputs, permissions, or artifacts
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure or child index changes.
Remove stale or contradictory text immediately.

---

## Hierarchy

- This root AGENTS.md is the DOX rail: project-wide instructions, global contracts, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific contracts and their own Child DOX Index
- Each parent doc explains what its direct children cover and what stays at the parent level
- The closer a doc is to the work, the more specific and practical it must be

---

## Child Doc Shape

Default section order for every child AGENTS.md:
1. Purpose
2. Ownership
3. Local Contracts
4. Work Guidance
5. Verification
6. Child DOX Index

Create a child AGENTS.md when a folder is a durable boundary with its own purpose, rules, or quality standards.

---

## Style

- Concise, current, operational — not diary entries
- Broad rules in parent docs; concrete details in child docs
- Direct bullets with explicit names
- No duplication across files unless each scope needs its own version
- Delete stale notes instead of annotating history
- No warnings for risks that no longer exist

---

## Closeout Checklist

Before marking any task done:
1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run mandatory verification (`flutter analyze` + `flutter test` for Flutter edits; `go vet ./...` + `go test ./...` for backend edits; `ruff check` + `pytest` for `Inference_backend/` edits)
6. Report any docs intentionally left unchanged and why

---

## User Preferences

- Flutter state management: Riverpod (non-negotiable)
- Repository structure: Monorepo (Golang Backend + Flutter Frontend + Python AI)
- Server-side LSTM inference: Flutter client extracts landmarks and streams to Golang backend server
- Data split: always GroupShuffleSplit by session before augmentation
- Model optimization: INT8 / FP16 quantization for server serving
- Commit style: Conventional Commits

---

## Child DOX Index

| Path | AGENTS.md | Covers |
|---|---|---|
| `Frontend/` | `Frontend/AGENTS.md` | Flutter mobile app structure, Riverpod patterns, feature layer conventions, WebSocket landmark streaming |
| `Backend/` | `Backend/AGENTS.md` | Golang REST & WebSocket API server, gRPC AI inference client, auth, DB schema |
| `Inference_backend/` | `Inference_backend/AGENTS.md` | Preprocessing spec, gRPC inference service (predict/upload/logs/tuning), model artifacts, TFLite runtime notes |
| `docs/` | `docs/AGENTS.md` | Documentation standards, API schemas (incl. stream payload), storyboard assets, proposal alignment |