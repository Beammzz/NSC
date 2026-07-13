# State

## Goal (current)
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
All 4 fixes done and verified (go vet/test, flutter analyze/test, live E2E probe on :8091:
401 without token on /stream + /conversation, 200 with Bearer, no Secure attr on plain-HTTP
login cookies). Uncommitted.

## Next
- Commit if approved.
- Note: Frontend/test/.../tsl_stream_service_test.dart (+3 URL tests) and untracked
  Inference_backend/TSL_Output/{active_model.json,uploads/} were changed by a concurrent
  session, not this one — do not revert or commit them blindly.

## Constraints
None stated yet.

## Open items
- Medium/minor review findings deliberately NOT in scope: Flutter token refresh/persistence,
  admin-signup cookie footgun, dangling CountSignupsByIP comment, >72-byte password 500,
  putTuning missing 401-retry.
