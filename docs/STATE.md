# State

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

## Now
Completed app icon setup across both native mobile launcher (`icon app`) and Flutter UI screens (`inside the app`). Configured `pubspec.yaml` and generated native Android/iOS launcher icons via `flutter_launcher_icons` using `assets/icons/app_icon.png`. Replaced text badge placeholders (`'⌘'` and `'มือ'`) with `Image.asset('assets/icons/app_icon.png')` across `LoginScreen`, `LandingScreen`, `ScannerScreen`, and `SettingsScreen`.

## Next
- [x] Step 1: Copy image to `assets/icons/app_icon.png`, configure `pubspec.yaml` and `flutter_launcher_icons`, and run generator.
- [x] Step 2: Update `login_screen.dart`, `landing_screen.dart`, `scanner_screen.dart`, `settings_screen.dart` with `Image.asset('assets/icons/app_icon.png')` and verify via `flutter analyze && flutter test`.

## Constraints
None stated yet.

## Open items
- Medium/minor review findings deliberately NOT in scope: Flutter token refresh/persistence,
  admin-signup cookie footgun, dangling CountSignupsByIP comment, >72-byte password 500,
  putTuning missing 401-retry.
