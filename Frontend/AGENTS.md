# Frontend — Child DOX

Child of root `AGENTS.md` (DOX). Root global contracts apply in full; this doc adds `frontend/`-local rules only.

---

## Purpose

Flutter mobile client (Android 9+ / iOS 13+): real-time TSL scanner, AI sign-language tutor, and conversational bridge UI. Extracts pose + hand landmarks on-device and streams feature vectors to the Golang backend.

---

## Ownership

| Path | Owns |
|---|---|
| `frontend/lib/core/` | Core theme (`app_theme.dart`), router (`app_router.dart`), and shared shell (`main_scaffold.dart`) |
| `frontend/lib/features/<name>/` | One folder per feature (`scanner`, `settings`, `ai_tutor`, `conversation`, `learn`) with `presentation/`, `domain/`, `data/` layers |
| `frontend/lib/features/scanner/data/services/tsl_stream_service.dart` | `TslStreamService` interface + `SimulatedTslStreamService` (demo loop) + `WebSocketTslStreamService` (real client for `<serverUrl>/api/v1/stream` per `docs/api/stream-schema.md`); provider picks one from the settings `useSimulatedStream` / `serverUrl` fields |
| `frontend/lib/features/settings/` | App settings incl. `serverUrl` and demo-mode toggle; persisted via `shared_preferences` behind `sharedPreferencesProvider` (overridden in `main()` and in tests) |
| `frontend/pubspec.yaml` | Dependencies (including `google_fonts` / Kanit typography) and app metadata |
| `frontend/test/` | Automated unit and widget tests per feature and core module |

---

## Local Contracts

- State management: Riverpod only. Navigation: GoRouter only. (Root rules — non-negotiable.)
- Naming: `snake_case` files, `PascalCase` classes, `camelCase` variables.
- Real-time recognition streams feature vectors over WebSocket to `/api/v1/stream`; vector layout follows the root **Feature Vector Spec** — do not restate dimensions in frontend code comments, reference the spec.
- Conversational AI and Speech Recognition use REST/WebSocket per root API rules.
- Every new feature ships with a corresponding test file (root Test Creation Mandate).

---

## Work Guidance

- Keep landmark extraction (MediaPipe on-device) isolated in a `data/` layer service so the WebSocket transport and UI stay decoupled.
- Scanner camera preview uses the `camera` plugin (back camera, `enableAudio: false`) behind `cameraControllerProvider` in `scanner/presentation/providers/`; needs `android.permission.CAMERA`. The provider resolves to `null` when no camera is usable (no permission/hardware, or under `flutter test`) so the viewport falls back to its gradient. Stage B will move capture to a native CameraX session that also feeds MediaPipe.
- Tests that touch `settingsProvider` (directly or via widgets that watch it) must call `SharedPreferences.setMockInitialValues({})` and override `sharedPreferencesProvider`.
- WS payloads follow `docs/api/stream-schema.md` (schema_version 1); change the schema doc first, then `tsl_stream_service.dart`.
- Feature folders own their state; shared widgets/utilities only get promoted out of a feature once a second feature needs them.

---

## Verification

- Root mandate: `flutter analyze` and `flutter test` whenever Flutter code is touched.

---

## Child DOX Index

None yet. Create per-feature child docs only if a feature grows rules this file can't hold concisely.
