# Backend — Child DOX

Child of root `AGENTS.md` (DOX). Root global contracts apply in full; this doc adds `backend/`-local rules only.

---

## Purpose

Golang REST & WebSocket API server: gateway between the Flutter client and the Python AI inference service, plus auth, conversation, and speech endpoints.

---

## Ownership

| Path | Owns |
|---|---|
| `backend/cmd/server/` | Server entrypoint: config load, route wiring (`/api/v1/stream`, `/api/v1/conversation`, `/healthz`) |
| `backend/internal/config/` | Environment-based configuration (`SIGNMIND_HTTP_ADDR`, `SIGNMIND_AI_ADDR`) |
| `backend/internal/conversation/` | `/api/v1/conversation` REST handler returning Thai reply text, sign gloss, and keypoint transition frames |
| `backend/internal/httpapi/` | RFC 7807 Problem Details type and response writer |
| `backend/internal/stream/` | `/api/v1/stream` WebSocket handler, WS message types (mirrors `docs/api/stream-schema.md`), gRPC AI client (`AIClient`/`AIStream` interfaces + `GRPCClient`) |
| `backend/internal/pb/` | protoc-generated stubs from `docs/api/tsl_inference.proto` — never edit by hand; regenerate (see Work Guidance) |

---

## Local Contracts

- Go 1.22+; standard `cmd/` + `internal/` layout per the root Repository Layout.
- Endpoints per root API rules: `/api/v1/stream` (WSS, landmark frames), `/api/v1/conversation` (NLP + server-side gloss keypoint transitions for client avatar rendering).
- Landmark frames forward to the Python AI service over gRPC bidirectional streaming only — no HTTP fallback on that path.
- Stream payloads carry `schema_version`; the schema lives in `docs/api/stream-schema.md` and breaking changes require a version bump there first.
- Auth per root rules: JWT access (15 min) + refresh (30 days), refresh tokens hashed server-side and revocable.
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
