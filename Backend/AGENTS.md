# Backend — Child DOX

Child of root `AGENTS.md` (DOX). Root global contracts apply in full; this doc adds `backend/`-local rules only.

---

## Purpose

Golang REST & WebSocket API server: gateway between the Flutter client and the Python AI inference service, plus auth and speech endpoints.

---

## Ownership

| Path | Owns |
|---|---|
| `backend/cmd/server/` | Server entrypoint: config load, shared SQLite DB, admin + learn seeding, route wiring (`/api/v1/auth/*`, `/api/v1/admin/*`, `/api/v1/learn/*`, `/api/v1/stream`, `/healthz`) |
| `backend/internal/config/` | Environment-based configuration (`SIGNMIND_HTTP_ADDR`, `SIGNMIND_AI_ADDR`, `SIGNMIND_JWT_SECRET`, `SIGNMIND_ADMIN_EMAIL`, `SIGNMIND_ALLOW_SIGNUP`, `SIGNMIND_TRUST_PROXY`) |
| `backend/internal/auth/` | Pure stdlib HMAC-SHA256 JWT auth (`/api/v1/auth/*`), user management (`/api/v1/admin/users`, `PUT /api/v1/admin/users/{id}/role`), sliding-window rate limiter, SQLite user/refresh token store |
| `backend/internal/httpapi/` | RFC 7807 Problem Details type and response writer |
| `backend/internal/stream/` | `/api/v1/stream` WebSocket handler, WS message types (mirrors `docs/api/stream-schema.md`), gRPC AI client (`AIClient`/`AIStream` interfaces + `GRPCClient`), per-connection sentence buffer (`sentence.go`: pause-triggered composition, `SentenceComposer` interface) |
| `backend/internal/llm/` | Sentence composition for the sign stream: SQLite settings + request log (`store.go`) and the OpenAI-compatible chat client with output validation and raw-gloss fallback (`service.go`) |
| `backend/internal/pb/` | protoc-generated stubs from `docs/api/tsl_inference.proto` — never edit by hand; regenerate (see Work Guidance) |
| `backend/internal/admin/` | `/api/v1/admin/*` REST handlers (status, settings/tuning, auto-clean config, predictions listing and clearing via `DELETE`, model upload, SSE log stream, LLM settings/logs at `/api/v1/admin/llm/*`) + `SyncDebugMode` background goroutine |
| `backend/internal/learn/` | Learning tab API: SQLite store + seed (topics/exercises/dictionary/progress), `/api/v1/learn/*` user routes and `/api/v1/admin/learn/*` CRUD routes (including th-sl.com sign link import via `POST /api/v1/admin/learn/signs/import-thsl`) |
| `backend/internal/predlog/` | Pure-Go SQLite (`modernc.org/sqlite`) prediction history store supporting insertion, paginated query, count, clearing, and configurable auto-cleaning (`SetAutoCleanMax`/`Prune`) |
| `backend/internal/webui/` | Embeds and serves the compiled Next.js admin static export (`dist/`) at `/` |
| `backend/webui/` | Next.js 15 + React 19 static admin web application source code (nav sidebar: Server dashboard, TSL Model [Predictions Log, AI Logs, Settings (Model Upload, Prediction Log Auto-Cleaning, Runtime Model Tuning, Active Model Summary, Guide)], LLM Model [LLM Logs, Settings (Endpoint + API key, System Prompt, Sentence Boundary & Limits)], Learning [topics/exercises CRUD, Practice Analytics table (attempts, correct, accuracy, learners passed, avg confidence per exercise)], Dictionary [Dictionary Words (webcam recorder, file upload, th-sl.com link import, preview, inline Note editor for the app's example step), Settings (custom label_map.json upload & reindex)], Users; including AuthProvider, login page, parameter documentation, and user management UI) |
| `backend/scripts/` | Maintenance and utility scripts (`backup.py` for database binary backup, SQL dump, and dictionary keypoint animation JSON/SQL export to `data/backups/`) |

---

## Local Contracts

- Go 1.22+; standard `cmd/` + `internal/` layout per the root Repository Layout.
- Endpoints per root API rules: `/api/v1/stream` (WSS, landmark frames).
- Admin web UI served at `/` and admin API at `/api/v1/admin/*` (status, tuning, paginated predictions listing & clearing via `DELETE`, multipart model upload, SSE logs).
- Learning tab API (`internal/learn`): `/api/v1/learn/{topics,dictionary,dictionary/{word},progress}` require any authenticated JWT; `/api/v1/admin/learn/{topics,exercises,signs,signs/import-thsl,signs/{word}/note,analytics}` CRUD requires the admin role. `POST /api/v1/admin/learn/signs/import-thsl` fetches th-sl.com entry pages, extracts the word and video URL, downloads the video, runs MediaPipe keypoint extraction, and stores the animated sign entry. Exercises carry a per-exercise `pass_confidence` (default 0.8) editable in the webui; `POST /api/v1/learn/progress` derives `passed` server-side from that threshold and progress never regresses. Every posted try is also appended to `learn_attempts`, from which the per-user `attempts`/`correct_attempts` on each progress row and the admin rollup `GET /api/v1/admin/learn/analytics` are aggregated — `learn_progress` still stores only the never-regressing best. `PUT /api/v1/admin/learn/signs/{word}/note` writes the hand-written explanation the app shows on its example step (max 4000 bytes, empty clears it, 404 when the word has no dictionary row). Both the note (`learn_sign_notes`) and the attempt log are separate tables joined on read, so the seeded `learn_signs`/`learn_progress` tables need no migration and existing dictionary rows are never rewritten. Content seeds idempotently on startup from the 150-word vocabulary (`seed.go` — keep `dictionaryCategories` in sync with `label_map.json`); topics seed only when none exist so admin edits survive restarts.
- Landmark frames forward to the Python AI service over gRPC bidirectional streaming only — no HTTP fallback on that path.
- Sentence composition (`internal/llm`): the stream handler buffers recognized words per connection and composes them after a configurable signing pause (`silence_ms`, default 2000) or once `max_words` accumulate, then pushes a `sentence` WS message. The LLM is an OpenAI-compatible `/chat/completions` endpoint (Typhoon by default); settings and the request log live in the shared SQLite DB and are edited at `/api/v1/admin/llm/*`. The API key is stored server-side and only ever leaves the server towards the endpoint — the admin API returns it masked and rejects a PUT that echoes the mask. Every failure path falls back to joining the raw glosses, so speech never depends on the LLM being reachable, and a reply that drops one of the recognized words is rejected (the model may reorder and insert function words, never invent or remove meaning).
- Stream payloads carry `schema_version`; the schema lives in `docs/api/stream-schema.md` and breaking changes require a version bump there first.
- Configuration loads optional `Backend/.env` (`ENV=Dev|Prod`); `ENV=Dev` enables full debug output end-to-end, and `admin.SyncDebugMode` propagates `debug_mode` to the Python AI inference service.
- Auth per root rules: JWT access (15 min) + refresh (30 days), refresh tokens hashed server-side and revocable.
- `/api/v1/stream` requires a valid JWT (any role) via `Authorization: Bearer` header or the `signmind_access` cookie; the token rides the WS upgrade request.
- Cookies are marked `Secure` only when the request arrived over HTTPS (direct TLS or `X-Forwarded-Proto: https`) so plain-HTTP LAN deployments keep working.
- `X-Forwarded-For` is honored for rate-limit keying only when `SIGNMIND_TRUST_PROXY=true` (default false); never enable it without a proxy that overwrites the header.
- Errors follow RFC 7807. Never log sensitive user progress data in plain text.

---

## Work Guidance

- Keep handlers thin; business logic and the gRPC client live under `internal/`.
- WebSocket writes go through the single writer goroutine in `internal/stream/handler.go` (gorilla/websocket allows one concurrent writer); never call `WriteJSON` from another goroutine.
- Regenerate `internal/pb/` after any `docs/api/tsl_inference.proto` change. No system `protoc` is installed; `grpcio-tools` drives the Go plugins (`protoc-gen-go` v1.36.11, `protoc-gen-go-grpc` v1.6.2 via `go install` to `~/go/bin`). Both language stubs regenerate together — full command in `Inference_backend/AGENTS.md` (run from repo root).
- Dependencies: `github.com/gorilla/websocket` (WS server), `google.golang.org/grpc` + `google.golang.org/protobuf` (AI client).

---

## Verification

- Root mandate: `go vet ./...` and `go test ./...` from `backend/` whenever Go code is touched.

---

## Child DOX Index

None yet. Create a child doc for `internal/` if it grows domain-specific rules beyond this file.
