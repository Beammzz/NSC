# State

## Goal (2026-07-19 evening): freeze Kotlin for Shorebird OTA
User adopting Shorebird; patches cover Dart only, so Kotlin (+ bundled .task assets,
gradle, manifest) is frozen at each store release. Made native scanner a configurable
engine so future changes stay Dart-side:
1. ScannerTuning object (CameraPreviewView.kt): @Volatile knobs — targetFps (12),
   poseIntervalMs (150), handProbeIntervalMs (500), hand/pose delegates (GPU/CPU),
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

## Constraints
- Do not git push (user has never asked for a push).
- Do not commit until the user asks; whole tree deliberately uncommitted.
- Shorebird OTA (`shorebird patch`) only when the user says they are satisfied.
- Never delete files without pasting what will be lost and getting approval in-conversation.
- 2026-07-19 user: "Delete lite model and also do Anything that will fix the low fps
  problem and also improve the app performance and Accuracy" (lite-model deletion approved).
- 2026-07-19 user (Shorebird prep): "So I want you to look at the kotlin side and see if
  it can optimize or fix anything. So that I dont need to touch the Kotlin side again"
  — keep native layer frozen; future scanner changes go through Dart + `configure`.

## Open items
- Medium/minor review findings deliberately NOT in scope: Flutter token refresh/persistence,
  admin-signup cookie footgun, dangling CountSignupsByIP comment, >72-byte password 500,
  putTuning missing 401-retry.
