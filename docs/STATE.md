# State

## Goal (2026-08-30): CI/CD for Android + server, Docker images, Traefik HTTPS compose
User: "I want you to build a CI/CD for both Android and Server on merge also run test and for
the server build make it docker and also make an example-compose.yaml for docker compose with
https for traefik."
KEY CONSTRAINT FOUND FIRST: `Backend/internal/webui/webui.go:13` does `//go:embed all:dist`, and
`internal/webui/dist` is gitignored — so on a fresh clone EVERY Go command (`go vet`, `go test`,
`go build`) fails with `pattern all:dist: no matching files found`. Both the CI backend job and
the Dockerfile therefore build `Backend/webui` (npm ci + npm run build) BEFORE any Go step.
Do not "simplify" that step away.
DELIVERED:
- `.github/workflows/ci.yml` — tests on PR + push to main (backend vet/test -race/build,
  inference ruff/pytest, frontend analyze/test); publish jobs gated on `needs:` + push to
  main. Android: debug APK on PR, release APK (split-per-abi) + AAB on merge. Docker: matrix over
  backend/inference -> GHCR, with a boot smoke test on the backend image.
- `Backend/Dockerfile` (3 stages: node webui -> go build -> alpine runtime, 39.1 MB, non-root
  uid 10001, network-free final stage) + `.dockerignore`.
- `Inference_backend/Dockerfile` (python:3.12-slim + ai-edge-litert 2.2.0, 418 MB, non-root)
  + `.dockerignore`. Runtime deps are read out of pyproject.toml with tomllib so they cannot drift.
- `example-compose.yaml` + `.env.example` — traefik v3.7, HTTP->HTTPS redirect, Let's Encrypt
  HTTP-01; inference sits on an `internal: true` network and is never published.
- `Frontend/android/app/build.gradle.kts` — optional release signing from key.properties or
  ANDROID_* env vars, falling back to the debug key exactly as before when absent.
NO FORMAT GATES ON PURPOSE: `gofmt -l Backend` lists 5 of 37 files already unformatted on main
(cmd/server/main.go, internal/admin/handler.go, internal/admin/handler_test.go, internal/auth/jwt.go,
internal/predlog/store_test.go), so a gofmt step would land CI red on the first merge; reformatting
them was out of scope for this task. `dart format --set-exit-if-changed` was dropped for the same
reason plus being unverifiable here (no Flutter in the container). To adopt: `cd Backend && gofmt -w .`
then re-add the step. `go test -race` IS enabled — unlike the format gates it was measured green
first (race_exit=0, ~111s).
VERIFIED 2026-08-30 (local, Docker 29.3.1): both images build; backend boots in Prod, `/healthz`
200, embedded webui serves real HTML (proves the cross-stage go:embed chain), HEALTHCHECK healthy,
SQLite WAL writes as uid 10001; inference loads the model (150 classes) and serves gRPC on
0.0.0.0:50051; `docker compose up backend inference` -> both healthy, `depends_on: service_healthy`
gates correctly, ZERO gRPC errors (shared-secret link works), `signmind_internal` has internal=true.
`actionlint` clean; `docker compose config` valid and the `:?` guards reject an empty env.
NOT VERIFIED LOCALLY: Flutter is not installed in this container, so `flutter analyze/test` and the
Gradle signing change have never been executed — CI is their first run.
NOTED (not done): `Inference_backend/TSL_Output/active_model.json` holds a Windows path
(`uploads\20260725T022950901648Z`); on Linux `_resolve_artifact_dir` cannot find it and falls back
to the TSL_Output root, which logs a WARNING on every boot. The fallback model is correct, so this
is cosmetic today, but a Linux deploy can never activate an uploaded model until it is fixed.

## Goal (2026-07-24): S25 FE 5fps — analysis stream bound at 2992x2992
User: "Why is my performance is terrible? even in the flagship (S25 FE)? like I currently get
5 fps with no hand."
ROOT CAUSE (not the model, not the phone): `ImageAnalysis.Builder().setTargetResolution(1280x720)`
at CameraPreviewView.kt:285. CameraX 1.3.4's legacy matcher groups supported sizes by aspect
ratio first; the S25 FE front camera exposes only SQUARE output sizes, so a 1280x720 target
rejects 1088x1088 for being narrower than 1280 and binds the next square up — 2992x2992.
Evidence `adb shell dumpsys media.camera`: `Consumer name: ImageReader-2992x2992f23m4-20135-2`
(preview got `SurfaceTexture` 1088x1088). 2992^2 = 8.95 MP vs 720p 0.92 MP = 9.7x the pixels.
toUprightBitmap (CameraPreviewView.kt:692) therefore moved ~34 MiB/frame (copyPixelsFromBuffer,
then a software Canvas rotate = read + transposed write), plus a 3rd 34 MiB blit in
maybeSubmitPose -> `bitmap=79-101ms` EVERY frame before any inference, and MediaPipe got a
9.7x oversized image -> `hand=70-140ms`. Total 160-215ms = 5-6fps.
FIX (Dart only — native layer stayed frozen): wired the `configure` MethodChannel, which NOTHING
had ever called, so every ScannerTuning knob had been sitting at its Kotlin default and the
Settings resolution dropdown was a no-op on Android. Default cameraResolution 720p -> 480p
(854x480 target fits 1088x1088). Files: camera_viewport.dart (initState `ref.listenManual` +
`_applyNativeTuning`), settings_models.dart:61, settings_screen.dart (recommended label moved).
VERIFIED 2026-07-24 on SM-S731B, release build installed via adb:
`ImageReader-1088x1088f23m4-31395-2`; logcat `frame ms: bitmap=5 hand=21 hands=0 total=26 fps=13`
(bitmap 80ms -> 4-9ms, hand 70-140 -> 13-32ms, 5-6fps -> 12-13fps at the targetFps=12 cap);
pose runs 53 per 121 frames (was 76 per 75 — the 150ms gate now actually bites).
NOT DONE (user approved for the next store release): replace setTargetResolution with
`ResolutionSelector` + `ResolutionStrategy(Size(1280,720), FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)`
in CameraPreviewView.kt so the bound size is deterministic on every device instead of relying on
480p happening to land well. Kotlin = store release, not Shorebird-patchable.

## Facts
- CameraPreviewView.kt (761 lines): `object ScannerTuning` knobs+`update()` 47-155; class
  `CameraPreviewView` 166+; `startCamera` (use-case bind, resolution choice) 261-297;
  `analyze` (per-frame critical path, the `frame ms:` log) 346-394; `detectHands` (solo/2-hand
  routing) 406-437; `maybeSubmitPose` 448-481; `ensureLandmarkers`/delegate builders 483-607;
  `buildFrame` (EventChannel payload) 647-684; `toUprightBitmap` (copy + rotate) 692-716.
- MainActivity.kt:42 handles `configure`; ScannerTuning is process-wide, so a configure sent
  before the PlatformView exists still applies when the view binds.
- Device profiling limits on this phone: simpleperf is SELinux-blocked (cpu-clock:u and
  cpu-cycles:u both "Permission denied" despite perf_event_paranoid=-1). Use
  `dumpsys media.camera` + the SignMindCamera logcat timings instead.

## Goal (2026-07-23): revert pose cadence to 150ms
User: "revert hand+pose back to full model". Investigated first — model ASSETS were already
full on every side (pose_landmarker_full.task 9,398,198 B in Frontend assets + Backend;
hand_landmarker has no lite variant upstream; no `lite` reference in Frontend/lib or Kotlin),
so nothing to revert there. What was actually downgraded in commit 51e7c7b was cadence:
`ScannerTuning.poseIntervalMs` 150L -> 250L. User chose to revert that knob (accuracy over the
fps/heat headroom); solo numHands=1 tracker left as is.
Change: CameraPreviewView.kt:67 `poseIntervalMs` 250L -> 150L + doc comment rewritten to record
the measured cost (p50 pose 107-112ms, ~72% executor busy, ~52% duty of one thermally-clamped
core) instead of the 250ms rationale.
EDITED-UNVERIFIED: no build run — user is away from the phone (no adb) and asked not to build.
To confirm, run: `cd Frontend && flutter build apk --release`.
SHIPPING NOTE: this is a Kotlin default, so it is NOT Shorebird-patchable — needs
`shorebird release android`. The freeze-respecting alternative (still not built) is a Dart
`configure` caller on the `signmind/camera` channel sending `{'poseIntervalMs': 150}`; there is
still no Dart caller for `configure`.

## Goal (2026-07-21): scanner performance optimization round
User: requested investigation and fix for scanner performance issues.
Optimizations implemented across Flutter and Native layers:
1. `_ScannerHeader` extracted into `const` widget in `scanner_screen.dart` to isolate top header from full-screen rebuilds.
2. `MediaPipeLandmarkExtractionService` checks `hasListener` before calling `parsePrimaryHand(event)` to eliminate unused parsing and list allocations.
3. `FeatureVectorFrame.fullVector` pre-computes 441-element list on construction; `buildFeatureVector` reuses static zeroed padding lists (`_zeroes147`).
4. `WebSocketTslStreamService` prunes `_recentSends` using head-pruning `while` loop instead of O(N) `removeWhere` linear scans per frame.
5. `CameraPreviewView.kt` reuses member `rotatedCanvas`, `poseCanvas`, and `rotationMatrix` to eliminate per-frame Bitmap/Matrix/Canvas instantiations.
6. `LandmarkStreamHandler.kt` added `isPending` backpressure guard to drop landmark frame emissions if main UI thread is busy.
7. `_LandmarkOverlayPainter` in `camera_viewport.dart` reuses static `Paint` objects (`_linePaint`, `_circleFill`, `_circleStroke`) and inlined neck midpoint calculation.
Verified: `flutter analyze` clean; `flutter test` 51/51 tests pass. Uncommitted.

## Goal (2026-07-21): two-hand dropout — solo tracker blinds the second hand
User: fast-movement TSL gestures drop a hand and take "a while" to regain it; suspected the
one-hand fps optimization. Correct.
MEASURED (36s two-hand signing, Redmi Note 12 5G, release build, 375 frames = 10.4fps):
hands=2 n=277 p50=86ms; hands=1 n=94 p50=53ms; pose 181 runs p50=107ms. hands=1 dropout
durations: 59/58/165ms (real transitions) then 571, 582, 1073, 1132, 1168, 1185, 1759ms —
quantized to 1x/2x/3x handProbeIntervalMs=500.
CAUSE: CameraPreviewView.kt detectHands armed the solo window on ANY 2-hand-instance run
returning count==1, including a momentary blur dropout from 2. The solo instance is
numHands=1 and CANNOT represent a second hand, so the returning hand stayed invisible for a
full window; a probe frame landing mid-blur re-armed it (hence the 2x/3x buckets).
FIX: new ScannerTuning.soloArmCooldownMs (default 1000ms, OTA-tunable, 0 = old behavior) +
lastTwoHandMs; solo is not armed while two hands were tracked within the cooldown. Costs one
extra 2-hand frame (~+33ms, once) per genuine 2->1 transition; one-hand fps path unchanged.
NOT REPRODUCED: the user's "6 fps". Native ran 10.4fps (mode 10-11, floor 8). The UI chip is
`fps: _recentSends.length` (tsl_stream_service.dart:259) = WebSocket sends in the trailing
second, refreshed only on server reply — measures round-trip cadence, not extraction rate.
Likely source of the 6; UNVERIFIED.
THERMAL (separate ceiling, not code-fixable): all 8 cores pinned at 61% of hardware max
(A55 1113/1804MHz, A78 1228/2016MHz), GPU 700/950MHz, for the entire 36s — while Android
reports `Thermal Status: 0` and battery saver is off. Vendor daemon capping below the API.
Skin 45.6 -> 46.8C across the session. Steady-state, not progressive.
NOTED (not done): pose = 107ms p50 x 5Hz = ~50% duty on a thermally-clamped big core, feeding
only shoulder-width normalization + torso overlay. poseIntervalMs 150->250 would cut heat and
free CPU, but STATE.md 2026-07-19 raised it 250->150 for accuracy — user's call, OTA-tunable.
NOTED (not done): pose-driven probe (wrists 15/16 + visibility) would remove the blind
handProbeIntervalMs timer entirely. Kotlin, larger change.
Kotlin freeze deliberately broken this turn — user: "You can do what ever you want but after
confirming the issue is fixed. please do shorebird release android again." Kotlin change
cannot ship as a Shorebird patch, so `shorebird release android` is the correct command.

## Goal (2026-07-19 evening): freeze Kotlin for Shorebird OTA
User adopting Shorebird; patches cover Dart only, so Kotlin (+ bundled .task assets,
gradle, manifest) is frozen at each store release. Made native scanner a configurable
engine so future changes stay Dart-side:
1. ScannerTuning object (CameraPreviewView.kt): @Volatile knobs — targetFps (12),
   poseIntervalMs (150), handProbeIntervalMs (500), soloArmCooldownMs (1000, added
   2026-07-21), hand/pose delegates (GPU/CPU),
   6 MediaPipe min-confidences (0.5), handModelPath/poseModelPath file overrides.
   Defaults = shipped behavior exactly; no configure call = no change.
2. MainActivity: `configure` method on `signmind/camera` channel -> ScannerTuning.update
   + lastView.onTuningChanged() (closes landmarkers on their executors; next frame
   rebuilds with new settings). Tuning process-wide, works before view creation.
3. Model override: baseOptions() memory-maps a .task from an absolute file path
   (Dart downloads it), falls back to bundled asset when missing/unreadable — makes
   landmark models OTA-updatable despite Shorebird not patching assets.
4. Fixes: landmarker init failure now backs off 3s (was: throw+log at frame rate);
   CameraPreviewFactory.lastView cleared on view dispose (leak); pre-existing
   compiler warning (unnecessary safe call, detectHands) removed.
5. Self-heal: corrupt/rejected model override clears itself and retries the bundled
   asset (buildHand/PoseLandmarkerOrNull) — a bad OTA model download cannot kill the
   scanner.
Verified: :app:compileDebugKotlin exit 0; flutter analyze clean; flutter test 51/51;
release APK 50.5MB built + adb install Success; app launch clean (8s logcat: no FATAL/
AndroidRuntime/SignMindCamera errors). Scanner-in-use on-device check pending user.
No Dart caller for `configure` yet — added when first tuning need arises (that IS the
OTA path). Contract documented in Frontend/AGENTS.md Work Guidance.
NOTED (not done): flutter_tts still applies Kotlin Gradle Plugin — future Flutter
versions will refuse to build (build warning); fixing = plugin upgrade = native/store
release. gradle.properties android.builtInKotlin=false / android.newDsl=false
deprecated, removed in AGP 10. Both are native-side items to batch into the NEXT
store release, not OTA-patchable.

## Active goal (2026-07-13): Sign Example via Avatar
Plan of record: docs/plans/sign-avatar-pipeline.md (4 phases — other agents read that first).
Locked: Go-exec Python CLI for keypoint extraction; in-browser webcam recording in admin webui;
conversation avatar signs by stitching recorded per-word keypoints; conversation transcript
hidden by default with per-message reveal.
PHASE 1 DONE (verified 2026-07-13): AI conversation replies now lead with SignAvatar; text +
gloss hidden until "แสดงข้อความ" is tapped. SignAvatar treats <7-point frames (the 2-point
server stub) as procedural. Files: conversation_screen.dart (_AiMessageBubble), sign_avatar.dart;
tests: new test/features/conversation/conversation_screen_test.dart + updated the older
presentation/conversation_screen_test.dart to the new UX. Verified: flutter analyze clean,
flutter test 55/55. Uncommitted.
PHASE 2 CODE DONE + UNIT-VERIFIED (2026-07-13): env risk cleared — .venv-x64 is Python 3.12 x64;
`pip install --dry-run mediapipe opencv-python-headless` resolves cleanly (mediapipe 0.10.35, no
numpy downgrade). Built: Inference_backend/extract_keypoints.py (pure helpers landmarks_to_frame/
downsample + deferred cv2/mediapipe extract()); Backend/internal/keypoint (Extractor execs the CLI
via injectable Runner; ExtractReader temp-file lifecycle; validateFrames); learn store
UpsertSign/SetKeypointFrames/DeleteSign; learn admin sign endpoints (GET/POST /admin/learn/signs,
POST .../signs/{word}/recording, DELETE .../signs/{word}) behind a KeypointExtractor interface;
config SIGNMIND_KEYPOINT_PY + SIGNMIND_EXTRACT_SCRIPT; wired in main.go. Verified: go vet/test all
green; ruff clean, pytest 60. Uncommitted.
PHASE 2 LIVE (synthetic) VERIFIED 2026-07-13: installed mediapipe 0.10.35 + opencv-python-headless
5.0.0 into .venv-x64 (numpy stayed 2.5.1). Ran extract_keypoints.py on a synthetic mp4 exactly as
Go execs it -> exit 0, MediaPipe loaded, stdout clean JSON (no BOM), 8 frames x 7 pose points,
{x,y,z} keys. Plumbing proven. NOTE: extract_keypoints downloads the MediaPipe .task models into
cwd on first run — in production that's the Go server's cwd (Backend/); consider downloading beside
the script or into TSL_Output (Phase 2 refinement, NOT done).
STILL UNVERIFIED: real-human-clip extraction QUALITY (deferred to Phase 3 webcam) and the full HTTP
path (multipart -> handler -> real extractor -> store) end-to-end.
PHASE 3 CODE DONE + BUILD-VERIFIED 2026-07-14: admin webui dictionary page. Files: Backend/webui/
app/dictionary/page.tsx (new — list signs with has_animation badge; create sign; SignRecorder
inlined = getUserMedia -> MediaRecorder -> preview -> upload; delete), Backend/webui/lib/api.ts
(+fetchAdminSigns/createSign/deleteSign/uploadSignRecording; recording is multipart field
"recording", FormData rebuilt per attempt for the 401 refresh-retry), Backend/webui/components/
nav.tsx (+Dictionary link; plan said layout.tsx but nav lives in components/nav.tsx). Verified:
`cd Backend/webui && npm run build` -> 11/11 static pages, /dictionary emitted, copy-dist ok.
COMBINED HTTP E2E VERIFIED 2026-07-14 (server-side, synthetic clip): built signmind-e2e.exe, ran it
from the scratchpad cwd (reuses cached .task models) with SIGNMIND_KEYPOINT_PY=.venv-x64 python +
SIGNMIND_EXTRACT_SCRIPT=extract_keypoints.py. Python E2E client (scratchpad/e2e_client.py) exercised:
login 200 -> create sign (Thai "สวัสดี" round-trips in JSON body AND %-encoded {word} path) 200 ->
POST .../signs/สวัสดี/recording with an mp4 (200, server exec'd real MediaPipe in 11.1s) -> GET
dictionary returns keypoint_frames (16 frames x 7 pts) -> repeat with a webm (200, 6.5s) -> frames
returned. has_animation flips false->true. So the FULL PLUMBING is proven end-to-end through the
running server, and opencv DECODES a VP8 webm (the MediaRecorder container) — the open WebM risk is
CLEARED. Repo not polluted (models stayed in scratchpad; the .task files in Frontend/android are the
pre-existing mobile assets). Note: the server binary embeds the freshly-built webui incl. /dictionary.
STILL UNVERIFIED: real-person landmark QUALITY. The synthetic clip zero-fills pose (any_nonzero_coord
=False) because MediaPipe finds no body — expected. Only a real camera clip of a person signing can
prove non-zero, correctly-ordered coords. Path to close it: open http://127.0.0.1:8099 (localhost =
secure context, so getUserMedia works), log in agent@example.com/Agent123, Dictionary -> Record.
PHASE 3 ADDITION 2026-07-14: "Show animation" preview on the dictionary page. Per-row toggle (only
when has_animation) fetches the sign's keypoint_frames (new api.ts fetchSign -> GET /learn/dictionary/
{word}) and plays them on a <canvas> via AvatarPreview — a faithful port of Flutter's
_SignAvatarPainter (7-pose layout, connections [[1,2],[1,3],[3,5],[2,4],[4,6]], head circle, hand
dots, 2400ms loop, #3987e5 accent). BUGFIX during verify: AvatarPreview scheduled the first paint
only inside requestAnimationFrame, which browsers pause while the tab is hidden -> blank canvas;
fixed by painting frame 0 synchronously in the effect, then rAF drives animation when visible.
Verified: npm run build clean (/dictionary 4.48kB); live in browser (canvas getImageData: bg #121211
filled + blue skeleton pixels, 0 transparent, after fix; was all (0,0,0,0) before). Files:
Backend/webui/app/dictionary/page.tsx (+AvatarPreview/renderAvatarFrame/preview state),
Backend/webui/lib/api.ts (+fetchSign, KeypointFrame/SignDetail types).
PHASE 4 DONE + UNIT-VERIFIED 2026-07-14: conversation avatar signs the reply by stitching each gloss
word's recorded keypoint_frames from the shared dictionary library. conversation.Handler now takes a
KeypointLookup (func(word)(json.RawMessage,bool)); buildReply -> stitchGloss (concatenate per-word
frames, restGapFrames=3 hold between signs, missing/nil words skipped, empty => client procedural).
Wired in main.go via signLookup over learnStore.GetSign (conversation stays decoupled: depends on the
func, not the learn pkg). Files: Backend/internal/conversation/conversation.go + conversation_test.go
(+StitchesGlossFrames, +NoRecordingsEmptyTransitions, fake lookup helpers), Backend/cmd/server/main.go;
DOX: Backend/AGENTS.md conversation rows. Verified: `cd Backend && go vet ./... && go test ./...` all
ok; conversation pkg 5/5 (stitch test asserts 2+gap3+3=8 frames, "พบ" skipped). Frontend already
null/empty-safe (conversation_repository.dart guards `is List`; SignAvatar <7pts => procedural) — no
frontend change needed. All Phase 4 work UNCOMMITTED.
PHASE 4 LIVE (endpoint) VERIFIED 2026-07-14: dev.ps1 stack up (Python gRPC :50051 model-loaded 219
classes; Go backend :8080, DB Backend/data/predictions.db, admin id=7 agent@example.com). curl:
healthz 200; login agent@example.com/Agent123 200 (role admin); POST /api/v1/conversation {msg=hello}
-> 200, reply_sign_gloss "สวัสดี พบ ยินดี", keypoint_transitions=0 frames — CORRECT: all 150 seeded
signs have has_animation=false (0 recordings) so every gloss word is skipped -> empty -> client
procedural fallback. A non-empty STITCHED sequence needs words with recordings (record-a-sign flow).
RELEASE APK: flutter build apk --release -> build/app/outputs/flutter-apk/app-release.apk (46.9MB, exit
0); adb install -r -> Success on Redmi Note 12 5G (sunstone); com.signmind.signmind v1.0.0 confirmed.
App server URL for on-device test: ws://192.168.30.2:8080 (phone on same Wi-Fi); login agent creds or sign up.
STILL UNVERIFIED (live): the Flutter app visibly animating a stitched *reply sentence* — needs a
dictionary word carrying recorded frames (record via admin Dictionary page or the app), then the
conversation avatar signs the reply stitched. Backend stitch logic itself is unit-proven (5/5).
NEXT: user records signs on-device / admin, then observe stitched conversation avatar; DOX closeout per
plan §6; commit when the user asks. Dev stack still running (bg task bw1d0ufh5).
RECORDING-CONFIG FIX 2026-07-14: user hit "Recording unavailable: keypoint extraction is not configured
on this server" (learn/handler.go:311 503) when recording. ROOT CAUSE: dev.ps1 exported only
SIGNMIND_HTTP_ADDR/SIGNMIND_AI_ADDR, never SIGNMIND_KEYPOINT_PY/SIGNMIND_EXTRACT_SCRIPT -> config
defaults them "" -> extractor.Configured()=false. NOT a code bug (the HTTP extract path was already E2E-
proven line 38 with the vars set manually). FIX: dev.ps1 now exports SIGNMIND_KEYPOINT_PY=$python (the
.venv-x64 interpreter, has mediapipe 0.10.35+cv2 5.0.0) + SIGNMIND_EXTRACT_SCRIPT=Inference_backend/
extract_keypoints.py, and cleans them up in finally. .gitignore now ignores /Backend/{pose_landmarker_
full,hand_landmarker}.task (extract_keypoints downloads ~16MB models into the backend cwd on first run).
Verified after restart (new bg stack b03r3rw7q): same recording POST that was 503 -> now passes the gate
(400 w/o file); full HTTP upload of a synthetic mp4 to throwaway word "zz_keypoint_test" -> 200
has_animation:true, 12 frames stored, then DELETE 204 / GET 404 (dictionary left clean). Direct
extract_keypoints run exit 0 (4 frames x 7 pts; models downloaded to Backend/, now gitignored). Files:
dev.ps1, .gitignore. UNCOMMITTED. Old stack bw1d0ufh5 replaced by b03r3rw7q.

## Goal (current)
Setup app icon both inside the app and for native launcher (2026-07-16): copy provided image to `Frontend/assets/icons/app_icon.png`, configure `pubspec.yaml` and `flutter_launcher_icons` to generate native Android/iOS launcher icons (`icon app`), and replace text badge placeholders (`'⌘'` / `'มือ'`) across `login_screen.dart`, `landing_screen.dart`, and `scanner_screen.dart` with `Image.asset('assets/icons/app_icon.png')` (`inside the app`).

## Prior goal: theme fixes (done, uncommitted)
Fix white/light theme across entire app UI (2026-07-16): replace hardcoded AppTheme static dark colors across all UI screens with dynamic Theme.of(context) properties and theme extensions (`AppThemeContextExtension`). All 48 tests pass cleanly.

## Prior goal: learning tab (done, uncommitted)
Learning tab (2026-07-13): dictionary + Duolingo-style exercise roadmap, full stack.
User decisions: full stack now; dictionary shows avatar keypoint animation (procedural
fallback — no real keypoint data exists yet, learn_signs.keypoint_frames column ready);
progress server-side per user; pass check client-driven via existing /api/v1/stream
(exercise passes at model confidence >= per-exercise threshold, default 0.80, editable
in admin webui; server derives `passed` on POST /api/v1/learn/progress).
DONE (verified): Backend internal/learn (store/seed/handler + tests; wired in main.go;
seeds 8 topics + 150-word dictionary idempotently) — go vet/test ok. Admin webui /learn
page (topic + exercise CRUD, threshold editing) — npm run build ok. Flutter learn feature
(models/repository/providers, learn_screen roadmap+dictionary, /learn/practice full-screen
route reusing scanner camera via new cameraMountOverrideProvider, SignAvatar widget,
7 new tests; landing card updated) — flutter analyze clean, 53/53 tests pass.
NOTE: demo mode grants a simulated pass after 3 detected frames (simulated stream never
emits exercise vocabulary). Uncommitted, like the rest of the tree.

## Prior goal: scanner perf (done, uncommitted)
Scanner landmark pipeline on Redmi Note 12 5G runs 7.2fps vs TARGET_FPS=12. Fix to >=11fps.
Cause chain: permanent 60Hz blink anim (scanner_screen.dart) + hybrid-composition platform
view merging raster onto main thread -> GPU contention with MediaPipe; plus heavy
pose_landmarker_full model.

## Goal addendum (2026-07-19): recognition quality bug
User: app doesn't recognize signs (e.g. รัก/Love) that tsl_live_inference.py recognizes;
confidence numbers look confident-but-wrong. CAUSE (hypothesis, strongest code mismatch):
mobile used pose_landmarker_LITE while training + tsl_live_inference.py:73 use FULL; every
feature is normalized by 3D shoulder width incl. z, lite z noisier -> whole 147-vector scale
wobble the model never saw. Secondary: pose refreshed 4x/s on mobile (Python: every frame) ->
steppy pose velocity features. Ruled out: mirroring (both unmirrored), handedness mapping,
hand model file, min-confidence defaults, fps (server resamples onto 12fps grid,
engine.py InferenceSession/resample_window). FIX: restored pose_landmarker_full.task from
git (cbf8840) into android assets, POSE_MODEL -> full (CPU executor, 250ms cadence).
pose_landmarker_lite.task left in assets (deletion needs user approval; +9.4MB APK).
RESULT 2026-07-19 14:40 (real server, user signing ILY on front camera): รัก recognized —
sentence "ถูก รัก ถูก รัก ถูก รัก" on screen; overlay aligned (hand skeleton on hand, nose dot
on nose). pose full CPU 58-102ms @ ~2.4Hz effective (in-flight guard), hand 161-175ms while
signing, ~6-8fps. APK 56.0MB (both pose models shipped; lite deletable with user approval).
Open: ถูก interleaves during transitions (model behavior, not pipeline); one-hand fps floor
~8 stands unless two-instance numHands scheme is built.

## Goal (2026-07-19 PM): one-hand fps + perf/accuracy round
User approved: delete pose_landmarker_lite.task; fix one-hand fps ceiling; improve perf +
accuracy. Changes (CameraPreviewView.kt only):
1. Dual HandLandmarker: solo numHands=1 instance tracks when exactly 1 hand tracked
   (skips the every-frame palm re-detection that cost 130-170ms); numHands=2 instance
   probes every HAND_PROBE_INTERVAL_MS=500ms (worst-case 2nd-hand pickup delay) and
   handles 0/2-hand frames. Separate VIDEO-mode timestamp streams per instance.
   detectHands() owns routing; log line now includes hands=N.
2. POSE_INTERVAL_MS 250 -> 150 (~6x/s; training/reference run pose every frame —
   smaller pose-hold steps in the feature stream).
3. toUprightBitmap: rotation now draws into reused rotatedBitmap (was per-frame
   Bitmap.createBitmap allocation).
4. pose_landmarker_lite.task git rm'd (user-approved); APK should drop ~5.8MB to ~50MB.
RESULT 2026-07-19 15:05 (partial): release build exit 0, APK 50.5MB (was 56.0), installed.
On-device 15s logcat x2 (back + front camera, NOBODY in frame): 187-189 frames/15s =
12.5fps cap holds, hands=0 all frames (2-hand instance path = old behavior, no regression),
pose full CPU 59-116ms at 88 runs/15s = 5.9Hz (was 2.4Hz), 0 error/exception tokens,
scanner streamed to real server (chip 12-13 FPS, latency 0.035-0.179s).
RESULT 2026-07-19 16:5x (user in frame, real server signmind.harumi.dev):
- One-hand (perf4.log, 18s): 154 hands=1 frames, hand p50 69ms (was 130-170ms — solo
  instance works), fps chip mode 10-11 peaking 13 (was ~8). DONE-WHEN >=10 MET.
- Two-hand (perf3.log, 30s): hands=2 all frames, hand p50 87ms, settled 10fps (was 8.8).
- Recognition: ฉัน 97% confidence, sentence "ถูก เรียน ดื่ม ชา มา ฉัน" building; overlay
  aligned (screenshot scanner3.png). Pose 78 runs/18s = 4.3Hz under load (110-145ms).
- 0 error/exception tokens across all captures.
GOAL ACHIEVED; everything uncommitted; shorebird not run (both need user's word).

## Failed attempts (2026-07-21 two-hand dropout)
- ATTEMPT 1 [L1]: ScannerTuning.soloArmCooldownMs=1000 + lastTwoHandMs — do not arm the
  numHands=1 tracker while two hands were tracked within the cooldown.
  GOOD: two-hand coverage 73.7% -> 89.9% of frames; two-hand frames delivered 7.66/s -> 8.39/s;
  dropouts >=1000ms fell from 50% to 6% of all dropouts; hands=2 inter-frame gap p50 unchanged
  at 100ms. flutter analyze clean, flutter test 51/51, compileDebugKotlin ok, 0 errors in 889
  frames, recognition verified on-device (ดื่ม 89%, overlay aligned).
  BAD (user caught it, I under-weighted the tail): hands=2 latency p90 100->130ms, p99 131->243,
  max 145->267; 11.7% of frames fell to <=7fps spread across the whole session (baseline floor
  was 8fps, never lower); 17 of 82 dropouts still >=500ms so the symptom is NOT gone.
  DIAGNOSIS of the tail: 68% of >150ms hands=2 frames are the frame where the second hand
  REAPPEARS (vs 8% enrichment on fast frames); pre-fix had zero frames >150ms. The spikes are
  palm re-detection — real work the old code skipped by staying blind. Not a regression in the
  pipeline, a cost that was previously hidden by the bug.
  CONCLUSION: fixing the routing was necessary but treats a symptom. Root cause is the LOSS
  RATE: ~0.8 second-hand losses/sec, each costing a 150-267ms re-acquisition.
- NEXT HYPOTHESIS [L2]: minHandPresenceConfidence / minHandTrackingConfidence sit at MediaPipe's
  0.5 default. Fast TSL motion at ~10fps indoors blurs a hand below 0.5 presence -> tracker
  releases it -> full palm re-detection. Lowering both to ~0.3 (keeping minHandDetection at 0.5
  so no phantom hands spawn) should cut the loss rate, which removes BOTH the dropouts and the
  expensive re-acquisitions. UNTESTED — needs a build + a user signing capture.
- ATTEMPT 2 [L2, hypothesis: loss rate is root; 0.5 presence/tracking releases blurred hands]:
  minHandPresenceConfidence + minHandTrackingConfidence 0.5 -> 0.3 (detection stays 0.5).
  RESULT: hypothesis NOT confirmed. fps floor still broken — min=5, 10.1% of frames <=7fps
  (sign4 was 11.7%, pre-fix baseline 0%). Dropouts >=1000ms did fall to 1 (from 5). hands=2
  latency p50 88->95, p90 130->146: no better.
- METHODOLOGY PROBLEM (the real blocker): every capture has different scene content — hands=0
  share was 1.1% (sign2) / 8.8% (sign4) / 24.7% (sign5). fps and coverage depend heavily on what
  is in frame, so cross-run diffs CANNOT be attributed to code. Only claim that survives: the
  pre-fix build showed min fps 8 / zero frames <=7fps, and BOTH post-fix builds show a low tail
  (min 4, min 5) across independent captures — so the routing fix does cost fps.
- UNPULLED LEVER: pose is 4.8-5.0 runs/s at p50 107-112ms = ~52% duty of ONE core, stable across
  all three runs (good control variable), on a chip thermally clamped to 61%. poseIntervalMs
  150->250 returns to the cadence that shipped 2026-07-19 and frees real budget WITHOUT trading
  hand visibility. Untested. Largest remaining lever.
- ATTEMPT 3 [L2, user-chosen]: revert ATTEMPT 2 (confidences back to 0.5), keep the routing
  fix, cut poseIntervalMs 150 -> 250. Pose measured 4.8/s -> 3.4/s, duty ~52% -> ~39% of a core.
  RESULT (sign6, 388 frames/40s; compare sign5 — nearest scene, 22.9% vs 24.7% hands=0):
  frames <=7fps 10.1% -> 3.9%; hands=2 spikes >150ms 10 -> 4; sustained fps 9.6 -> 9.8; p90 gap
  137 -> 119ms; total dropouts 40 -> 27, of which >=1000ms = 2 (7%). vs sign4 (pose 150): <=7fps
  11.7% -> 3.9%, spikes 19 -> 4. 0 errors. Recognition verified on-device (sentence
  "ดื่ม ชา กาแฟ เช้า ชา ถูก"; hand visibly motion-blurred with skeleton still latched).
- MEASUREMENT NOTE: raw fps is scene-dependent and NOT comparable across runs. Use the
  scene-controlled metric instead: inter-frame gap inside runs of >=10 consecutive hands=2
  frames. On that metric sustained two-hand fps is ~10.0 for pre-fix AND the routing fix —
  the routing fix costs nothing while two hands are tracked. Its cost is confined to TRANSITION
  frames (palm re-detection when the 2nd hand reappears), which is real work the old code
  skipped by staying blind.
- NET vs shipped build: second hand invisible >=1s on 50% of dropouts -> 7%; low-fps tail 3.9%
  of frames (was 0%, but the pre-fix capture had 1.1% hands=0 and only 10 dropouts — far fewer
  transitions, so not a like-for-like scene).
- NOT RELEASED YET. User halted the first release attempt on seeing the 4fps floor; correct
  call. Awaiting user decision on releasing + version bump (1.0.0+1 android already active on
  Shorebird, so a bump is required).

## Failed attempts (2026-07-17 signing-fps bug)
- ATTEMPT 1 [L1]: pose moved off hand critical path (own executor, 250ms cadence, GPU) +
  overlay cover-crop fix -> idle scene 11.6fps OK, but user signing still ~6fps (chip 4).
  Logcat while signing: hand=143-244ms exactly when pose ms=79-128 overlapped on GPU;
  hand alone ~100ms. GPU contention replaced the emit stall — net zero.
- ATTEMPT 2 [L2, hypothesis: Adreno 619 serializes concurrent hand+pose GPU work]:
  pose -> Delegate.CPU (GPU hand-exclusive), cadence kept 250ms. RESULT (2026-07-17 00:57,
  real server, person + one hand raised): 97 frames/12s = 8.1fps (was 5.9), chip 7 (was 4),
  pose CPU 44-81ms, hand 77-169ms. Overlay alignment VERIFIED by screenshot (nose dot on
  nose, hand skeleton on palm). REMAINING CEILING: one-hand-visible with numHands=2 makes
  MediaPipe re-run palm detection EVERY frame (searching the empty 2nd slot) -> hand
  ~130-170ms; two-hands-tracked is cheaper (~90ms). ~8fps is the floor without a pipeline
  redesign (LIVE_STREAM overlap est. +1fps) or model-level change. 12fps only holds when
  both hand slots are tracked or no hands present.

## Failed attempts
- ATTEMPT 1 [L1]: removed 60Hz blink anim (Timer 700ms toggle) + swapped pose full->lite
  -> pose 46-180ms -> 31-52ms, UI rasters 33->20.5/s, but hand still ~85ms and fps still 7.2
  (measured 87 frames/12s logcat, debug build, hand in frame).
  Instrumentation (L3-grade): with scanner PAUSED (UI static, native analyzer still running)
  -> hand drops to ~58ms, 134 frames/12s = 11.2fps. Remaining bottleneck = per-landmark-frame
  full-screen rebuild/raster on merged main thread contending with MediaPipe GPU.
  Next candidate: split currentFrame out of ScannerState into its own provider so only the
  overlay CustomPaint (in a RepaintBoundary) repaints per frame; optional pose stride 2->3;
  fallback: TLHC platform view (initAndroidView). Scope exceeds TASK EST 2x -> stopped for
  user approval per PLAN.md. (User approved; also moved to SERVER prediction mode, 8fps.)
- ATTEMPT 2 [L1]: currentFrame split into currentFrameProvider (+RepaintBoundary overlay),
  equality-based dedupe of translation writes, pose stride 2->3 -> server mode: 7.9fps,
  hand 113-198ms, UI rasters 29/s. Guard defeated: fps=_recentSends.length jitters 7<->8<->9
  per message so equality never holds; server mode adds JSON/WS/TTS load absent in demo mode.
  Paused control run: 8.9fps, hand ~76ms, thermal 0 -> UI contention still dominant.
- ATTEMPT 3 [L2, new evidence: jitter defeats equality dedupe]: replace guard with 500ms
  time-coalescing of cosmetic fields (word/sentence/phase changes stay immediate).
  Debug build: 7.2fps still. LEARNED: gfxinfo "frames rendered" includes the camera
  TextureView's own invalidations (~camera rate), so it never isolated Flutter rasters.
- DISCOVERY: release builds were COMPLETELY broken (scanner dead): R8 strips protobuf-lite
  reflection fields MediaPipe needs ("Field platform_ ... not found"). Fixed with
  android/app/proguard-rules.pro. Second crash: R8 -optimize inlines MediaPipe's
  caller-sensitive native loader (Graph.<clinit> "no caller found on the stack") ->
  -dontoptimize + -keep com.google.mediapipe.** + -dontwarn com.google.mediapipe.proto.**.
  AGP rejects getDefaultProguardFile("proguard-android.txt") — use the optimize file +
  -dontoptimize in custom rules.
- RESULT (2026-07-12 03:05): release build runs the scanner at 8.7fps measured in demo mode
  with NO hands in frame (worst case for palm detection; phone aimed at a fan). Jank
  20% (was 57-60%). Target >=11fps NOT yet confirmed; needs re-test with a person in frame
  and server mode (user must sign in; token doesn't persist across restarts — known open item).

## Next (perf task)
- GOAL ACHIEVED 2026-07-12 19:52: release build + real server (ws://192.168.30.2:8080,
  JWT login via Gemini's remember-credentials) = 145 frames/12s = 12.1fps (TARGET_FPS cap),
  hand 43-62ms, pose 40-45ms every 3rd frame, fps chip shows 12, latency 0.151s.
  Scene had no hands in frame; re-check with a person signing (hands-tracked stretches
  measured 35-60ms yesterday, so the cap should hold).
- TLHC platform-view swap NOT needed; leave hybrid composition as is.
- DONE 2026-07-12 20:05: pose_landmarker_full.task deleted (git rm, user-approved);
  APK 55.7MB -> 46.7MB.
- Two-hand tracking measured 8.8-8.9fps on BOTH delegates (GPU hand 70-98ms; CPU/XNNPACK
  hand 51-115ms but pose degraded 33-45 -> 56-81ms). Kept GPU. Official MediaPipe docs
  confirm only ONE hand_landmarker model exists (no lite variant) -> two-hand ~9fps is the
  floor on Adreno 619 without a pipelining redesign (LIVE_STREAM overlap, est. +1fps).
  <=1 hand holds the 12fps cap. Verified final build: 145 frames/12s = 12.1fps.
- All perf + release-fix changes remain uncommitted alongside the earlier auth work.

## Prior goal: auth fixes (done, uncommitted)
Fix the 4 high-priority findings from the JWT auth review of commit f06309e:
1. Require JWT on /api/v1/stream and /api/v1/conversation; Flutter sends Bearer tokens.
2. Cookie Secure flag derived from request scheme (fixes webui login over plain-HTTP LAN).
3. Logout clears signmind_refresh with its real path (/api/v1/auth/).
4. Trust X-Forwarded-For only when SIGNMIND_TRUST_PROXY=true; bound RateLimiter memory.

## Goal (2026-07-17): scanner pose-map + fps fix
User report: hand overlay fine, pose overlay map wrong, 5-6 fps while signing; emit waited on
hand+pose sequentially. Two causes fixed:
1. Overlay geometry: painter stretched normalized coords across the viewport, ignoring
   PreviewView FILL_CENTER cover-crop -> pose (spans whole body) visibly off, hands (center)
   fine. Native now emits upright analysis width/height in the landmark payload; painter
   replicates the cover transform (falls back to stretch when dims absent — simulated feed).
2. Pose off the hand critical path: PoseLandmarker moved to its own executor + frame copy,
   cadence 250ms (~4x/s, was stride-6 ≈ <=2x/s and inline — emission stalled 35-45ms on stride
   frames and pose skeleton lagged up to ~1s at low fps). Emission pairs each hand result with
   the latest completed pose.
Files: CameraPreviewView.kt, landmark_extraction_service.dart, scanner_models.dart,
camera_viewport.dart, landmark_extraction_service_test.dart (+dims test).
Verified 2026-07-17: flutter analyze clean; flutter test 51/51; release APK built + installed
on Redmi Note 12 5G; 12s logcat = 139 frames = 11.6fps sustained, pose 44 runs/12s = 3.7Hz on
own thread (74-99ms, overlapped), no errors. NOT yet verified: fps + overlay alignment with a
PERSON SIGNING in frame (two-hand worst case) — needs the user in front of the camera.
Uncommitted. Shorebird OTA deliberately NOT run (changes unverified by user).

## Prior goal: app icon (done)
Completed app icon update and installation across both native mobile launcher and Flutter UI screens (`inside the app`). Copied the user-provided sign-language outline icon over `assets/icons/app_icon.png`, regenerated native Android/iOS launcher icons (`dart run flutter_launcher_icons`), built release APK (`flutter build apk`), and installed to connected phone via `adb install -r`.

## Next
- [x] Step 1: Copy image to `assets/icons/app_icon.png`, configure `pubspec.yaml` and `flutter_launcher_icons`, and run generator.
- [x] Step 2: Update `login_screen.dart`, `landing_screen.dart`, `scanner_screen.dart`, `settings_screen.dart` with `Image.asset('assets/icons/app_icon.png')` and verify via `flutter analyze && flutter test`.
- [x] Step 3: Replace `app_icon.png` with provided sign-language outline icon, regenerate `flutter_launcher_icons`, rebuild release APK (`app-release.apk`), and install via `adb`.

## Goal (2026-08-10): fix all monorepo security/bug audit findings, in severity order
User: "Fix all in order based on how critical it is" — following a 3-subsystem parallel-agent
security audit (Go backend, Flutter frontend, Python inference) this same session. 18 findings
ranked Critical/High/Medium/Low.
DONE (Critical, all VERIFIED — RESULT: `pytest -q` Inference_backend "76 passed in 0.80s",
`go vet ./... && go test ./...` Backend all ok):
1. Inference_backend gRPC service had zero auth (server.py add_insecure_port, no interceptors) —
   any network client could UploadModel/SetTuning/StreamLogs. FIX: new
   inference/auth_interceptor.py SharedSecretInterceptor (metadata key
   x-signmind-shared-secret, hmac.compare_digest); wired via build_server(shared_secret=...) in
   server.py, enforced only when SIGNMIND_AI_SHARED_SECRET is set (warns loudly if unset).
   Go side: Backend/internal/stream/ai_client.go sharedSecretCreds (PerRPCCredentials, applies to
   ALL RPCs incl. admin's aiClient.Raw() since it's channel-wide); config.AISharedSecret
   (env SIGNMIND_AI_SHARED_SECRET); main.go resolveAISharedSecret fails fast in Prod if unset,
   like resolveJWTSecret. dev.ps1 generates+exports a fresh secret for both child processes.
2. engine.py activate_artifacts cast confidence_threshold to float() AFTER the model/config were
   already swapped and OUTSIDE the try/except — a non-numeric value left a broken model live,
   uncaught. FIX: tsl_preprocess._validate_config (confidence_threshold/target_fps/
   sequence_length range+type checked) runs inside load_preprocess_config, so bad values raise
   ValueError BEFORE activate_artifacts's try block even reaches load_model — rollback path
   already existed, just never reached.
3. Same validation closes target_fps<=0: previously unchecked, persisted via active_model.json,
   crashed every subsequent stream (ZeroDivisionable at 1000.0/target_fps in
   InferenceSession.add_frame) — permanent DoS surviving restart. Now rejected at UploadModel time.
DONE (High, Go VERIFIED — RESULT: go test ./internal/stream/... -race ok, all 4 new tests pass):
4. No conn.SetReadLimit on /api/v1/stream — one oversized WS frame could OOM the process. FIX:
   handler.go maxClientMessageBytes=64KiB via conn.SetReadLimit right after Upgrade.
5. No cap on concurrent /api/v1/stream connections (signup is public by default) — resource
   exhaustion DoS from any account. FIX: handler.go connLimiter (mutex+map), maxStreamsPerUser=4,
   maxStreamsTotal=500, acquire/release around ServeHTTP keyed on auth.ClaimsFromContext(...).Sub;
   429 RFC7807 problem on rejection.
DONE (High, Flutter EDITED-UNVERIFIED — no flutter SDK in this sandbox; needs
`cd Frontend && flutter analyze && flutter test` to confirm):
6. Saved login password stored in plaintext SharedPreferences, rememberCredentials defaults true.
   FIX: added flutter_secure_storage: ^9.2.4 dep. settings_provider.dart: new
   secureStorageProvider/savedPasswordProvider; SettingsNotifier reads password via
   ref.watch(savedPasswordProvider) (loaded async, unlike sync build()); writes go through
   _secureStorage.write/delete (unawaited, fire-and-forget from sync Notifier methods). main.dart:
   _migrateSavedPassword reads any legacy plaintext value at startup, moves it into secure
   storage, deletes the old prefs key, then loads+overrides savedPasswordProvider before runApp.
   Updated test/features/auth/presentation/login_screen_test.dart's 3rd test to override
   savedPasswordProvider instead of seeding the now-dead SharedPreferences key.
   NOTED (not done): rememberCredentials default stays `true` — now safe since storage is secure;
   changing the default would be a UX call outside this security fix's scope.
7. android:allowBackup was unset (defaults true), no dataExtractionRules — adb backup/cloud
   backup could extract the plaintext password even before finding #6. FIX: AndroidManifest.xml
   `android:allowBackup="false"` on <application>. XML validated via `xmllint --noout`.
VERIFICATION GAP: no Flutter SDK, no pwsh, no Android/iOS toolchain in this sandbox — Flutter and
dev.ps1 changes are code-reviewed carefully (matched existing SharedPreferences-override pattern
in main.dart; flutter_secure_storage API is the well-known stable read/write/delete) but NOT
executed. Go and Python changes ARE executed and verified (see RESULT lines above).
DONE (Medium, 5 of 6 — Go VERIFIED via go vet/go test, Flutter EDITED-UNVERIFIED, same gap as
above; 6th item SKIPPED, see conflict below):
8. Go SSRF in learn/handler.go importFromThsl (admin-gated th-sl.com sign import fetched any
   admin-supplied URL, echoing content back). FIX: thslAllowedHosts allow-list (th-sl.com/
   www.th-sl.com only) checked on pageURL before fetching; thslFetchClient custom
   http.Transport.DialContext resolves the host itself and rejects non-public IPs (private/
   loopback/link-local/multicast/unspecified via isPublicIP) before dialing — closes DNS
   rebinding, covers the video URL too (which may legitimately be a different domain, so it's
   IP-gated rather than host-allow-listed). Tests override the package-level vars for the
   existing loopback-mock-server test; new TestImportFromThslRejectsNonAllowedHost +
   TestIsPublicIP with the real production vars.
9. Go internal gRPC error strings relayed verbatim (stream/handler.go 4 sites, admin/handler.go
   grpcProblem fallback) — leaked dial/transport errors (addresses, "connection refused") to
   clients. FIX: new aiProblem()/fixed grpcProblem() use the gRPC status message when the error
   is a genuine status.FromError() (safe, AI-service-chosen text); anything else -> fixed "AI
   service connection error" detail, real error still log.Printf'd server-side.
10. Flutter cleartext http/ws fallback in auth_provider.dart _toHttpUrl / tsl_stream_service.dart
    _streamUri — a bare host (no scheme) silently defaulted to http/ws. FIX: bare host now
    defaults to https/wss (matches the login field's own hint text "https://signmind.harumi.dev");
    explicit http:// or ws:// still works unchanged for self-hosted LAN/dev servers.
11. Flutter scanner state (recognized sentence) surviving logout on a shared device. FIX:
    scanner_provider.dart ScannerNotifier.build() now watches
    authProvider.select((s) => s.isAuthenticated); _savedState is cleared whenever unauthenticated.
12. Python unbounded upload retention in inference/server.py UploadModel — every accepted upload
    grew disk forever. FIX: MAX_RETAINED_UPLOADS=5 + _prune_old_uploads() (lexicographic ==
    chronological, since dir names are UTC timestamps) called after a successful
    activate_artifacts; always keeps the currently-active dir.
SKIPPED (conflict, see Open items): Flutter refresh-token flow.
DONE (Low, all 5 — Go VERIFIED, Python VERIFIED, Flutter EDITED-UNVERIFIED):
13. Go LLM API key plaintext at rest (llm/store.go). FIX: AES-256-GCM, key = SHA-256("signmind-
    llm-apikey-v1" + jwtSecret) via new DeriveEncryptionKey (domain-separated, not raw JWT bytes
    reused). Store.Open/OpenWith signatures gained an encKey param (RS done — updated
    cmd/server/main.go, admin/handler_test.go, llm/store_test.go openTemp). CAVEAT documented in
    main.go: Dev mode with no SIGNMIND_JWT_SECRET set regenerates jwtSecret every restart (same
    tradeoff Dev already accepts for login sessions), so a saved LLM key needs re-entering after
    each Dev restart; Prod is stable (JWTSecret required, fatal if unset). New
    TestAPIKeyIsNotStoredInPlaintext asserts the raw DB column isn't/doesn't contain the plaintext
    key and that a differently-derived key can't decrypt it.
14. Go X-Forwarded-Proto trusted unconditionally while clientIP's X-Forwarded-For was correctly
    gated on trustProxy. FIX: requestIsSecure(r, trustProxy) — proto header only honored when
    trustProxy is true, mirroring clientIP. New tests split the old
    TestCookieSecureFollowsRequestScheme into 3: default(no header)/ignores-forwarded-without-
    trustProxy/honors-forwarded-with-trustProxy.
15. Python NaN/Infinity landmark floats unvalidated before feeding the model. FIX:
    np.isfinite(position).all() check in StreamInference, INVALID_ARGUMENT abort otherwise (same
    pattern as the existing feature-count check). Tests: nan + inf frames rejected.
16. Flutter HttpLearnRepository._request had no timeout (could hang the Learn tab forever). FIX:
    mirrors auth_provider.dart's _postWithTimeout pattern — client.connectionTimeout +
    .timeout(10s) wrapping the extracted _performRequest, TimeoutException on expiry.
VERIFICATION GAP (unchanged): no Flutter SDK, no pwsh, no Android/iOS toolchain in this sandbox —
every Flutter/dev.ps1 change above is EDITED-UNVERIFIED. Go: `go vet ./... && go test ./...` all
ok after every fix (last full run confirmed here). Python: `ruff check . && pytest -q` -> "79
passed" after every fix (last full run confirmed here).
Files changed (git diff --stat HEAD, package-lock.json churn from an unrelated `npm install` was
reverted): 32 files, +1117/-101. New: Backend/internal/stream/ai_client_test.go,
Inference_backend/inference/auth_interceptor.py. All uncommitted per the Constraints below (user
has not asked to commit in this task's conversation).

## Constraints
- 2026-08-30 user (CI/CD task): asked, when offered the choice, to "Commit and push to that
  branch" — supersedes the two blanket rules below FOR THE CI/CD BRANCH
  `claude/cicd-android-server-docker-xrd1tr` ONLY. Everywhere else the rules below still hold:
  ask before committing, and never push without the user saying so in that conversation.
- Do not git push (unless the user asks for a push in that conversation).
- Do not commit until the user asks; whole tree otherwise deliberately uncommitted.
- Shorebird OTA (`shorebird patch`) only when the user says they are satisfied.
- Never delete files without pasting what will be lost and getting approval in-conversation.
- 2026-07-19 user: "Delete lite model and also do Anything that will fix the low fps
  problem and also improve the app performance and Accuracy" (lite-model deletion approved).
- 2026-07-19 user (Shorebird prep): "So I want you to look at the kotlin side and see if
  it can optimize or fix anything. So that I dont need to touch the Kotlin side again"
  — keep native layer frozen; future scanner changes go through Dart + `configure`.
- 2026-07-24 user (LLM scope): "please dont add any feature that I will implement in the
  final (Coach and conversation). Just auto correct and swap OSV first." Coach AI and AI
  Conversation are OUT of scope — WebUI placeholder only, no backend/Flutter code.
- 2026-07-24 user (LLM provider): "Cloud api. due to it is thai model I whine I will use
  TyphoonAI that is made by SCB DataX" — LLM provider is Typhoon (OpenAI-compatible HTTP),
  NOT Anthropic. Do not write Anthropic SDK code on this path.
- 2026-07-25 user (scan vocabulary): "I need to reduce amount of sign available for scan.
  Please dont change it and also dont change the dictionary database." Do NOT edit label_map.json /
  the model, and do NOT modify the learn dictionary DB or seed.go (user is expanding seed.go
  themselves, uncommitted). Scan-reduction owner + mechanism + what "it" refers to NOT yet
  confirmed — asked user 2026-07-25.

- 2026-07-25 user (avatar style toggle): "I said the option to change between cartoon and keypoint
  need to be in the setting page not in the dictionary." Toggle belongs in Settings, not the
  dictionary sign sheet.

## Open items
- Medium/minor review findings deliberately NOT in scope (2026-07 decision, unrelated JWT-review
  session): Flutter token refresh/persistence, admin-signup cookie footgun, dangling
  CountSignupsByIP comment, >72-byte password 500, putTuning missing 401-retry.
  CONFLICT (2026-08-10): today's "fix all in order of criticality" 18-item audit independently
  flagged "Flutter refresh-token flow" as Medium-severity — same underlying gap this line already
  deferred. Not auto-resolved; asked the user which instruction wins before touching it.

## Goal (2026-07-25): cartoon sign avatar (done, uncommitted)
User: avatar "is kinda like nothing but show hand keypoint as dot and face is just circle" —
redraw cute, keep every keypoint correct, NO re-extraction. Decisions: cartoon + a Flutter
toggle back to skeleton; missing hands hold last-seen pose; update both renderers.
DATA (measured from Backend/data/backups/dictionary_keypoints_latest.json): 220 entries /
3520 frames; frame = 7 pose points + 21 MediaPipe landmarks PER DETECTED HAND, so lengths are
7 (1832 frames, no hand), 28 (943, one hand), 49 (745, two hands). Pose never zero-filled.
The old painter threw the hand structure away as 2.6px dots — the redraw is pure rendering.
BUILT:
1. sign_avatar.dart: SignAvatarStyle {cartoon, skeleton}; cartoon = filled shirt torso
   (synthesized hips — no hip landmarks exist), skin neck/forearms, sleeved upper arms, head
   with hair cap + eyes + blush + smile drawn in a frame rotated to the shoulder tilt, and real
   five-finger hands (palm polygon [0,1,5,9,13,17] + 5 finger chains) from the recorded
   landmarks. Hands are matched to wrists by distance (MediaPipe emits detection order, not
   L/R). A wrist with no hand this frame reuses the most recent hand, re-anchored on the current
   wrist (search wraps the loop); a wrist with none in the whole clip gets a mitten. All sizes
   are multiples of shoulder width. New _ViewFit: uniform scale+offset over the bbox of ALL
   frames (+ reserved torso room in cartoon) — recorded coords span the camera frame, so the old
   raw x*width mapping ran off the widget edges in both styles.
2. Style switch: FIRST built as a SegmentedButton in the dictionary sign sheet; user rejected the
   placement ("need to be in the setting page not in the dictionary"), so it MOVED to Settings ->
   การแสดงผลและธีม as SwitchListTile "อวาตาร์แบบการ์ตูน (Cartoon Avatar)". Persisted:
   AppSettings.cartoonAvatar (default true, pref key settings.cartoonAvatar, toggleCartoonAvatar).
   learn_screen _SignDetailAvatar watches settingsProvider.select((s) => s.cartoonAvatar); the
   in-memory signAvatarStyleProvider that briefly lived in learn_provider.dart is deleted.
   Test: settings_screen_test "cartoon avatar defaults on and the toggle persists".
3. webui dictionary page.tsx: same cartoon renderer ported; renderAvatarFrame signature is now
   (ctx, frames, index, size) because held hands and the fit need the whole clip. Skeleton style
   is Flutter-only; the sparse-frame dot fallback stayed.
FINGER-CLARITY PASS (user: "Make the finger seperation look clearer"): finger chains now start at
the knuckle (1/5/9/13/17) instead of the wrist — five chains through the palm were stacking into a
blob; each finger draws outline-then-fill in sequence (all-outlines-first let the next finger's
fill erase the line between them); fingers sort farthest-first by mean landmark z; finger width
0.115 -> 0.105 shoulder width and hand outline halved (curled hands filled in solid black at body
outline weight). Palm is stroked now, not just filled.
Verified: flutter analyze clean, flutter test 60/60; `npm run build` clean (/dictionary 4.48 ->
7.63 kB). Cartoon + skeleton rendered to PNG from real recorded frames (word ถ่ายรูป, 16 frames,
two hands) via a temp widget test and inspected — figure fits the box, fingers correct, held
hands track the wrist on the 7-point frames. Temp test deleted.
UNVERIFIED: the webui canvas visually (build + type-check only, no browser run this session).

## Goal (2026-07-25): Typhoon LLM gloss-refine — autocorrect + reorder/insert ONLY
Scope: gloss autocorrect + topic-fronting/function-word insertion ONLY (Coach + AI Conversation
OUT, see Constraints 2026-07-24). Placement planned (NOT built): Backend/internal/llm +
POST /api/v1/translate/refine (JWT, RFC 7807, fail-open to raw gloss); API key = server env, never APK.
FACTS verified 2026-07-25:
- Typhoon model typhoon-v2.5-30b-a3b-instruct; endpoint POST https://api.opentyphoon.ai/v1/chat/completions.
- Typhoon has NO response_format json_object/json_schema (docs.opentyphoon.ai api-reference+examples).
  So: strict-JSON system prompt + parse text + server-side validate + 1 retry + hard filter (reject
  any output word not in the input lattice) — fall back to raw gloss on any failure.
RESEARCH delivered (claude.ai, 3 files in C:\Users\Sorra\Downloads\files\: tsl_grammar_spec.md,
tsl_annotated_pairs.json[51 pairs], tsl_ambiguity_cases.json[10]). KEY FINDING: "TSL = OSV
(กรรม กริยา ประธาน)" is UNSUPPORTED by any source — treat as false. Real job = detect topic-comment
fronting + INSERT function words (numeral classifiers, ที่/ใน/บน/ด้วย/กับ, เป็น/คือ/อยู่,
จะ/แล้ว/กำลัง, politeness) + FLAG ambiguity — negation & yes/no-questions are invisible to a
hands+7-pose recognizer; never silently guess "loves" vs "doesn't love".
NOTE: user is expanding seed.go (adds ไม่, ที่ไหน/อย่างไร/อะไร) which partly closes the wh/negator
gaps IF those signs get recorded+trained; the 51 pairs were built on the pre-expansion 150-word set
(additive only, no removals — existing pairs stay in-vocab).

## Goal (2026-07-25 PM): LLM sentence composition — BUILT, uncommitted
User: "turn words into sentences … 'ฉัน รัก เธอ' -> 'ฉันรักเธอ' and then do the tts after it detect a
long pause"; plus "inside the LLM page in admin UI have LLM logs. and settings page … edit system
prompt, openai-compatible endpoint, API key".
DECISIONS (user answered 4 questions this session, all recommended options): full scope
(backend + admin UI + Flutter); sentence ends on a server-side silence timeout; delivery via a new
WS `sentence` message on /api/v1/stream (NOT the previously planned POST /api/v1/translate/refine);
API key in SQLite, admin-editable, masked on read (NOT env-only as the earlier plan assumed).
BUILT:
1. Backend/internal/llm — store.go (llm_settings + llm_logs tables, partial-patch settings with
   clamping, auto-clean prune) and service.go (OpenAI-compatible /chat/completions, Typhoon defaults,
   output validation, RawJoin fallback). Compose NEVER errors: every failure path returns the joined
   glosses and logs why. Validation rejects empty/fenced/quoted/multi-line/runaway output and any
   reply that dropped a recognized word (the research's in-vocab hard filter).
2. Backend/internal/stream/sentence.go — per-connection word buffer. Dedupes the repeated top-1 of
   one gesture, ignores idle/uncertain windows, composes on the silence timer or at max_words,
   `reset` drops the buffer without composing. NewHandler gained a third arg (SentenceComposer).
3. admin: GET/PUT /api/v1/admin/llm/settings, GET/DELETE /api/v1/admin/llm/logs. admin.New gained an
   *llm.Store arg. Key masked as ••••abcd; a PUT echoing the mask is a 400.
4. webui /llm page (tabs LLM Logs + Settings), nav "LLM Model" no longer "Coming soon",
   globals.css got textarea/password/url input styling.
5. Flutter: ComposedSentence model + ScannerState.composedSentence; parseServerSentence;
   TslStreamService.sentenceStream/supportsSentences; scanner_provider speaks the composed sentence
   and STOPS per-word autoSpeak when the server composes (simulated stream keeps word-by-word).
Verified: go vet ./... + go test ./... all ok; npm run build clean (/llm 4.03 kB); flutter analyze
clean; flutter test 63/63 (baseline 61).
RUNTIME: user ran the app 2026-07-25 and reported "the app run as expected" — first real-world
confirmation of the pipeline. Not covered by that report: whether a Typhoon key was configured, so
it may have exercised only the RawJoin fallback path.
UNVERIFIED: no live Typhoon call observed from this side — every LLM test uses an httptest stub, so
the real endpoint, model id, and API key have never been exercised end-to-end in a run we measured.
DEFERRED (not built, deliberately): retry on 429/5xx (one attempt then fallback, to protect the
1.5s end-to-end latency target); gloss autocorrect (would violate the in-vocab filter — needs its
own decision); Coach AI + AI Conversation stay out per the 2026-07-24 constraint.

## Goal (2026-07-25): Learn tab — "แบบฝึกหัด" -> "เรียนรู้", 3-step exercise flow (done, uncommitted)
User: rename the tab and rework it so each exercise (1) shows the dictionary example plus a note
the user writes by hand in the Admin UI, (2) then goes to the practice step with the accuracy
threshold, (3) then reports "how many attempt out of the correct" for analytics.
DECISIONS (user-answered, 2026-07-25): note lives on the DICTIONARY SIGN (one per word, reused by
every exercise using it); an attempt is an EXPLICIT try button with a bounded 3s capture window;
the summary is PER TOPIC; analytics visible to BOTH the learner in-app and the Admin UI.
SCHEMA — additive only, no migration, dictionary rows never rewritten (honors the 2026-07-25
"dont change the dictionary database" constraint): two NEW tables joined on read, `learn_sign_notes
(word PK, note)` and append-only `learn_attempts(id, user_id, exercise_id, confidence, passed,
created_ms)`. `learn_signs`/`learn_progress` are untouched, so the live data/predictions.db needs
no ALTER; `seed.go` was not edited.
BUILT:
1. Backend `internal/learn`: Sign.Note + LEFT JOIN in ListSigns/GetSign; SetSignNote (trim, empty
   clears the row, ErrNotFound when the word has no dictionary row, note deleted with the sign);
   RecordAttempt also appends to learn_attempts; Progress gains attempts/correct_attempts via
   `progressSelect`; new ListExerciseStats rollup. Routes: PUT /api/v1/admin/learn/signs/{word}/note
   (max 4000 bytes) and GET /api/v1/admin/learn/analytics.
2. Flutter: 3 routes over the tab shell — /learn/example (new sign_example_screen.dart: avatar +
   note + "เริ่มฝึกทำท่า"), /learn/practice (rewritten: explicit try button, 3s window, posts the
   window's best confidence — 0.0 when the word never appeared, so misses count), /learn/summary
   (new topic_summary_screen.dart: correct/attempts + accuracy + per-word rows). PracticeArgs now
   carries the whole LearnTopic (was topicTitle) so the screen can detect topic completion.
   Segment label -> "เรียนรู้"; SimulatedLearnRepository tallies attempts and ships demo notes.
3. WebUI: LearnSign.note + setSignNote + fetchLearnAnalytics in lib/api.ts; inline note textarea
   column on /dictionary; "Practice Analytics" table on /learn.
VERIFIED 2026-07-25: go vet ./... clean; go test ./... all ok (learn 0.140s, 5 new/extended tests
named PASS); flutter analyze "No issues found!"; flutter test "All tests passed!" (65, was 63);
npm run build exported 13 routes. Live probe on a throwaway :8099 + scratch DB (the user's server
on :8080 was left running): PUT note -> 200 and the Thai note reads back intact off
GET /learn/dictionary/{word}; three POSTs (0.92, 0.10, 0.0) -> attempts 1,2,3 with
correct_attempts stuck at 1; analytics -> attempts 3 / correct 1 / learners 1 / avg 0.34.
NOTE: an earlier probe showed the note as "?????" — that was Git Bash mangling a non-ASCII
command-line argument, not the server; resending the same body from a UTF-8 file round-tripped.
DOX synced: Backend/AGENTS.md (routes, attempt-log/note tables, webui sections), Frontend/AGENTS.md
(learn feature row, attempt semantics), landing_screen.dart per the Feature Registry Sync Rule.

## Goal (2026-07-25, round 2): Duolingo-style lesson map (done, uncommitted)
User screenshot showed the PRE-CHANGE build (label still "แบบฝึกหัด") — the round-1 rename and the
example step were already in source, just not on the phone. Real new asks: (a) roadmap must show
lesson ICONS only, no topic name and no word chips; (b) pressing the icon opens a detail popup with
a start button, Duolingo-style; (c) the emoji was not tappable — only the word chip was.
DECISIONS (user-answered): Start runs the WHOLE topic end to end (example -> practice -> next word
-> ... -> summary); the popup shows title + progress + Start only, no word list.
BUILT:
1. learn_screen.dart: `_TopicNode`/`_ExerciseChip` (card with title + word chips) DELETED, replaced
   by `_LessonNode` (86px progress ring + 68px emoji disc, whole disc is an InkWell — this is the
   "emoji dont work" fix; padlock when locked, check badge when complete) laid out on a meandering
   path via `_pathOffsets`, plus `_LessonSheet` bottom sheet (icon, title, `ผ่านแล้ว N จาก M คำ`,
   Start / เรียนต่อ / ฝึกซ้ำอีกครั้ง; locked topics get the unlock hint and no button).
2. Chaining: `ExampleArgs`/`PracticeArgs` now carry `(topic, index)` instead of a bare exercise.
   Practice `_advance()` replaces `_leavePractice()` — on pass it pushReplacement's the next word's
   example, or the summary after the last. Both screens show `คำที่ N/M` in the app bar.
   Start index = first unpassed exercise, or 0 when the topic is already complete (replay).
3. app_router.dart passes `index`; learn_screen_test.dart rewritten for the new design (asserts the
   path names NOTHING, that the icon tap opens the sheet, and that a locked topic has no Start).
VERIFIED 2026-07-25: flutter analyze "No issues found!"; flutter test "All tests passed!" (67).
DEBUG note: first run of the new roadmap test failed — `Expected: exactly 8 matching candidates /
Actual: Found 4 widgets with type "CircularProgressIndicator"`. CAUSE was the assertion, not the
widget: ListView only builds nodes inside the 800x600 test viewport. Count assertion dropped for
`findsWidgets`; production code untouched.

## Failed attempts
- ATTEMPT 1 [L1] (2026-07-25, ฝึกทำใหม่ widget test): seeded topic progress with
  `await repo.fetchTopics()` directly inside `testWidgets` -> `TimeoutException after
  0:10:00.000000: Test timed out after 10 minutes.` Cause: `SimulatedLearnRepository.fetchTopics`
  sleeps on `Future.delayed(300ms)` and testWidgets' fake clock only advances on `tester.pump`.
  Fix: wrap the seeding in `tester.runAsync`.

## Goal (2026-07-25, round 3): "ฝึกทำใหม่" resets topic progress (done, uncommitted)
User: "Make the ฝึกทำใหม่ Reset all progress. Currently it skip all the exercise. and dont let
user do again."
CAUSE of the skip (traced, not guessed): exercise_practice_screen.dart initState seeds
`_passed = stored.passed` from saved progress, so a already-passed word renders `_PassedCard`
before any try and `_startAttempt()` early-returns on `if (_passed ...)`. The only live control is
"คำต่อไป", which walks every passed word straight to the summary.
DECISIONS (user-answered): reset scope = THIS TOPIC ONLY (other topics keep progress, unlock chain
intact); the learn_attempts log is KEPT (admin analytics never loses history — consequence: a
replayed topic's summary counts the old tries plus the new ones).
BUILT:
1. Backend: `Store.ResetTopicProgress(userID, topicID) (int, error)` deletes learn_progress rows
   for the topic's exercises only, never learn_attempts. Route
   `DELETE /api/v1/learn/progress/topic/{id}` (user role) always scopes to claims.Sub, so a
   client-supplied topic id cannot touch another learner. Returns {topic_id, cleared}.
2. Flutter: `LearnRepository.resetTopicProgress` (http + simulated), `LearnProgressNotifier.
   resetTopic(topic)` (clears the same keys locally, THROWS on failure), and `_LessonSheet` is now
   stateful — completed topics show `ฝึกทำใหม่`, which opens a confirm dialog
   ("ล้างและเริ่มใหม่" / "ยกเลิก"), resets, then starts at index 0. A failed reset does NOT
   navigate (starting would reproduce the skip bug) and shows an inline error instead.
VERIFIED 2026-07-25: go vet ./... clean; go test -count=1 ./... all ok; flutter analyze
"No issues found!"; flutter test "All tests passed!" (69, was 67).
Live probe on throwaway :8099 + scratch DB: 6 progress rows -> DELETE topic 1 -> {"cleared":5,
"topic_id":1} HTTP 200 -> 1 row left (exercise 6, the other topic, untouched). Analytics after the
reset still reports attempts=1 per word with learners_passed dropped to 0 (log kept, pass cleared).
Re-practising exercise 1 at 0.4 -> {"best_confidence":0.4,"passed":false,"attempts":2} — i.e.
practisable again from zero, tally continuing. Bad topic id -> HTTP 400; no token -> HTTP 401.
