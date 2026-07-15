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
| `backend/internal/auth/` | Pure stdlib HMAC-SHA256 JWT auth (`/api/v1/auth/*`), user management (`/api/v1/admin/users`), sliding-window rate limiter, SQLite user/refresh token store |
| `backend/internal/httpapi/` | RFC 7807 Problem Details type and response writer |
| `backend/internal/stream/` | `/api/v1/stream` WebSocket handler, WS message types (mirrors `docs/api/stream-schema.md`), gRPC AI client (`AIClient`/`AIStream` interfaces + `GRPCClient`) |
| `backend/internal/pb/` | protoc-generated stubs from `docs/api/tsl_inference.proto` — never edit by hand; regenerate (see Work Guidance) |
| `backend/internal/admin/` | `/api/v1/admin/*` REST handlers (status, tuning, predictions listing and clearing via `DELETE`, model upload, SSE log stream) + `SyncDebugMode` background goroutine |
| `backend/internal/learn/` | Learning tab API: SQLite store + seed (topics/exercises/dictionary/progress), `/api/v1/learn/*` user routes and `/api/v1/admin/learn/*` CRUD routes |
| `backend/internal/predlog/` | Pure-Go SQLite (`modernc.org/sqlite`) prediction history store supporting insertion, paginated query, count, and clearing |
| `backend/internal/webui/` | Embeds and serves the compiled Next.js admin static export (`dist/`) at `/` |
| `backend/webui/` | Next.js 15 + React 19 static admin web application source code (including AuthProvider, login page, dictionary recording and animation preview via modal pop-up, direct file upload, and user management UI) |

---

## Local Contracts

- Go 1.22+; standard `cmd/` + `internal/` layout per the root Repository Layout.
- Endpoints per root API rules: `/api/v1/stream` (WSS, landmark frames).
- Admin web UI served at `/` and admin API at `/api/v1/admin/*` (status, tuning, paginated predictions listing & clearing via `DELETE`, multipart model upload, SSE logs).
- Learning tab API (`internal/learn`): `/api/v1/learn/{topics,dictionary,dictionary/{word},progress}` require any authenticated JWT; `/api/v1/admin/learn/{topics,exercises}` CRUD requires the admin role. Exercises carry a per-exercise `pass_confidence` (default 0.8) editable in the webui; `POST /api/v1/learn/progress` derives `passed` server-side from that threshold and progress never regresses. Content seeds idempotently on startup from the 150-word vocabulary (`seed.go` — keep `dictionaryCategories` in sync with `label_map.json`); topics seed only when none exist so admin edits survive restarts.
- Landmark frames forward to the Python AI service over gRPC bidirectional streaming only — no HTTP fallback on that path.
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
