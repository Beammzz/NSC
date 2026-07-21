# Frontend — Child DOX

Child of root `AGENTS.md` (DOX). Root global contracts apply in full; this doc adds `frontend/`-local rules only.

---

## Purpose

Flutter mobile client (Android 9+ / iOS 13+): real-time TSL scanner and dictionary/exercise learning UI. Extracts pose + hand landmarks on-device and streams feature vectors to the Golang backend.

---

## Ownership

| Path | Owns |
|---|---|
| `frontend/lib/core/` | Core theme (`app_theme.dart`), router (`app_router.dart`), and shared shell (`main_scaffold.dart`) |
| `frontend/lib/features/<name>/` | One folder per feature (`auth`, `landing`, `scanner`, `settings`, `learn`) with `presentation/`, `domain/`, `data/` layers |
| `frontend/lib/features/auth/` | Authentication feature (`authProvider`, `LoginScreen`) supporting live JWT login/signup or offline simulated demo mode. Contains embedded Server IP configuration card (`serverUrl`). |
| `frontend/lib/features/scanner/data/services/tsl_stream_service.dart` | `TslStreamService` interface + `SimulatedTslStreamService` (demo loop) + `WebSocketTslStreamService` (real client for `<serverUrl>/api/v1/stream` per `docs/api/stream-schema.md`, sends `Authorization: Bearer` from `authProvider` on the WS handshake); provider picks one from the settings `useSimulatedStream` / `serverUrl` fields and the auth access token |
| `frontend/lib/features/settings/` | App settings view displaying 3-way theme switcher (`ThemeMode.system`, `ThemeMode.dark`, `ThemeMode.light`), connected Server IP, and demo-mode status; persisted via `shared_preferences` behind `sharedPreferencesProvider` (overridden in `main()` and in tests) |
| `frontend/lib/features/learn/` | Learn tab: TSL dictionary (searchable, category-grouped, `SignAvatar` keypoint animation with procedural fallback) and exercise roadmap (topics -> perform-the-sign exercises, pass at model confidence >= the exercise's admin-set threshold). `LearnRepository` (HTTP `/api/v1/learn/*` + simulated demo variant fully synced with the 150-word Server Dictionary and 8 starter roadmap topics); full-screen practice route `/learn/practice` reuses the scanner camera pipeline |
| `frontend/pubspec.yaml` | Dependencies (including `google_fonts` / Kanit typography, `flutter_launcher_icons`), app icon asset (`assets/icons/app_icon.png`), and app metadata |
| `frontend/test/` | Automated unit and widget tests per feature and core module |

---

## Local Contracts

- State management: Riverpod only. Navigation: GoRouter only. (Root rules — non-negotiable.)
- Naming: `snake_case` files, `PascalCase` classes, `camelCase` variables.
- Entrypoint & Authentication Flow: The application initializes at `/login` (`LoginScreen`). `GoRouter.redirect` verifies `authProvider.isAuthenticated`; unauthenticated users or users who disconnect/logout are automatically returned to `/login`. `LoginScreen` includes a "Remember credentials" checkbox that saves and pre-populates email/password across sessions via `settingsProvider` and `SharedPreferences`. Live authentication requests (`login`/`signup`) enforce a 3-second connection and response timeout (`_postWithTimeout`), displaying a clear error banner when a timeout (`TimeoutException`) or connection failure occurs.
- Server IP Configuration: Configured directly on the Login Page (`LoginScreen`) before authenticating or entering demo mode. Settings Page displays the active server IP read-only with a shortcut back to `/login` to switch servers.
- Real-time recognition streams feature vectors over WebSocket to `/api/v1/stream`; vector layout follows the root **Feature Vector Spec** — do not restate dimensions in frontend code comments, reference the spec.
- Mobile Testing & Debugging: During testing or debugging, check `adb devices` for connected devices. If no device is connected, build an APK (`flutter build apk`) for the user to test instead.
- OTA Release Mandate: When building the app for updates or release, make it release via OTA using Shorebird (`shorebird patch`).
- Admin UI Access: Accessible via `http://127.0.0.1:8080` or `https://signmind.harumi.dev` (Agent credentials — email: `agent@example.com`, password: `Agent123`).
- Every new feature ships with a corresponding test file (root Test Creation Mandate).
- **Feature Introduction Registry Sync Rule**: After authentication or entering demo mode, the application routes to `/landing` (`LandingScreen`) which introduces all implemented SignMind AI features with interactive launch cards. Whenever a new feature is added or an existing feature is removed, developers MUST update `Frontend/lib/features/landing/presentation/screens/landing_screen.dart` alongside DOX (`AGENTS.md`) so the Landing Page remains synchronized as the single source of truth for implemented capabilities.

---

## Work Guidance

- Keep landmark extraction (MediaPipe on-device) isolated in a `data/` layer service so the WebSocket transport and UI stay decoupled.
- Native scanner is Shorebird-frozen: OTA patches Dart only, so the Kotlin side (`android/app/src/main/kotlin/com/signmind/signmind/`) is a fixed engine — all tuning lives in `ScannerTuning` (CameraPreviewView.kt) and is set from Dart via MethodChannel `signmind/camera` method `configure` (map payload; keys: `targetFps`, `poseIntervalMs`, `handProbeIntervalMs`, `handDelegate`/`poseDelegate` ("gpu"/"cpu"), `minHand*`/`minPose*` confidences, `handModelPath`/`poseModelPath`). Missing keys leave fields unchanged; a null/blank model path reverts to the bundled asset. Replacement `.task` models: Dart downloads to app storage and passes the absolute path — never ship model changes as Kotlin/asset edits. Do not touch Kotlin for tunables; change the Dart caller instead.
- Scanner camera preview uses the `camera` plugin (back camera, `enableAudio: false`) behind `cameraControllerProvider` in `scanner/presentation/providers/`; needs `android.permission.CAMERA`. The provider resolves to `null` when no camera is usable (no permission/hardware, or under `flutter test`) so the viewport falls back to its gradient. Stage B will move capture to a native CameraX session that also feeds MediaPipe.
- Tests that touch `settingsProvider` (directly or via widgets that watch it) must call `SharedPreferences.setMockInitialValues({})` and override `sharedPreferencesProvider`.
- The native camera preview mounts only on the scanner tab; full-screen flows outside the tab shell that need it (exercise practice) must set `cameraMountOverrideProvider` while visible and release it on dispose. In demo mode the simulated stream never emits exercise vocabulary, so the practice screen grants a simulated pass after a few detected frames (`useSimulatedStream` only).
- WS payloads follow `docs/api/stream-schema.md` (schema_version 1); change the schema doc first, then `tsl_stream_service.dart`.
- Feature folders own their state; shared widgets/utilities only get promoted out of a feature once a second feature needs them.

---

## Verification

- Root mandate: `flutter analyze` and `flutter test` whenever Flutter code is touched.

---

## Child DOX Index

None yet. Create per-feature child docs only if a feature grows rules this file can't hold concisely.
