# Docs — Child DOX

Child of root `AGENTS.md` (DOX). Root global contracts apply in full; this doc adds `docs/`-local rules only.

---

## Purpose

Project documentation: API schemas (including the versioned stream payload schema), storyboard assets, and proposal-alignment material.

---

## Ownership

| Path | Owns |
|---|---|
| `docs/api/stream-schema.md` | Versioned WebSocket payload schema for `/api/v1/stream` (schema_version 1) |
| `docs/api/tsl_inference.proto` | gRPC contract between the Golang backend and the Python inference service — source of truth; generated stubs live in `Backend/internal/pb/` and `Inference_backend/inference/pb/` |

---

## Local Contracts

- `docs/api/stream-schema.md` is the single source of truth for the stream payload; every payload includes `schema_version`, and breaking changes bump the version here before any code changes.
- Docs must not restate the Feature Vector Spec or AI targets — link to the root AGENTS.md sections instead.
- Follow root Style rules: concise, operational, delete stale text instead of annotating history.

---

## Work Guidance

- Changes to `docs/api/tsl_inference.proto` require regenerating both language stubs (commands in `Backend/AGENTS.md` and `Inference_backend/AGENTS.md`) in the same task.
- Storyboard or media assets that are videos fall under the repo-wide Git LFS tracking (`.gitattributes` at root).

---

## Verification

- No automated checks. Before closing a docs change, confirm no contradiction with root AGENTS.md contracts.

---

## Child DOX Index

None yet.
