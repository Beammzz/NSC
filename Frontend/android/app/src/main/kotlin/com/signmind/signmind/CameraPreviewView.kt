package com.signmind.signmind

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.os.SystemClock
import android.util.Log
import android.view.View
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.io.FileInputStream
import java.nio.channels.FileChannel
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Runtime tuning for the native scanner pipeline, settable from Dart via the
 * `signmind/camera` MethodChannel `configure` call (see MainActivity).
 * Shorebird OTA patches Dart only, so these knobs — and the model-file
 * overrides — exist so cadence/accuracy/model changes ship as Dart patches
 * without another Kotlin (store) release. Defaults reproduce the shipped
 * behavior exactly; a `configure` payload missing a key leaves that field
 * unchanged. Fields are @Volatile: written on the platform thread, read on
 * the analysis/pose executors.
 */
object ScannerTuning {
    /**
     * Extraction cap. Matches the ~12fps the model was trained on (the server
     * windows 30 frames regardless of rate, so faster capture would shrink the
     * window's time span).
     */
    @Volatile var targetFps: Int = 12

    /**
     * Pose refresh cadence. Training and tsl_live_inference.py run pose EVERY
     * frame, so pose values that hold then jump are a distribution the model
     * never saw; ~6x/s keeps the step size small (pose CPU run is 58-102ms and
     * the in-flight guard serializes, so this stays comfortably off saturation).
     */
    @Volatile var poseIntervalMs: Long = 150L

    /**
     * How long the 1-hand fast tracker may run before the 2-hand instance
     * probes for a second hand — also the worst-case pickup delay when a
     * second hand enters the frame.
     */
    @Volatile var handProbeIntervalMs: Long = 500L

    /** Hand delegate: GPU measured best on Adreno 619 (see ensureLandmarkers). */
    @Volatile var handDelegate: Delegate = Delegate.GPU

    /** Pose delegate: CPU on purpose so pose never contends with hand on the GPU. */
    @Volatile var poseDelegate: Delegate = Delegate.CPU

    // MediaPipe's 0.5 defaults, spelled out so Dart can tune accuracy OTA.
    @Volatile var minHandDetectionConfidence: Float = 0.5f

    @Volatile var minHandPresenceConfidence: Float = 0.5f

    @Volatile var minHandTrackingConfidence: Float = 0.5f

    @Volatile var minPoseDetectionConfidence: Float = 0.5f

    @Volatile var minPosePresenceConfidence: Float = 0.5f

    @Volatile var minPoseTrackingConfidence: Float = 0.5f

    /**
     * Absolute file paths of replacement .task models (Dart downloads them to
     * app storage — Shorebird cannot patch bundled assets). null / blank / a
     * missing file falls back to the bundled asset.
     */
    @Volatile var handModelPath: String? = null

    @Volatile var poseModelPath: String? = null

    val frameIntervalMs: Long get() = 1000L / targetFps

    /** Applies a Dart `configure` payload: unknown keys ignored, values clamped. */
    fun update(args: Map<*, *>) {
        (args["targetFps"] as? Number)?.let { targetFps = it.toInt().coerceIn(1, 60) }
        (args["poseIntervalMs"] as? Number)?.let { poseIntervalMs = it.toLong().coerceIn(0L, 10_000L) }
        (args["handProbeIntervalMs"] as? Number)?.let { handProbeIntervalMs = it.toLong().coerceIn(0L, 10_000L) }
        (args["handDelegate"] as? String)?.let { handDelegate = parseDelegate(it, handDelegate) }
        (args["poseDelegate"] as? String)?.let { poseDelegate = parseDelegate(it, poseDelegate) }
        (args["minHandDetectionConfidence"] as? Number)?.let { minHandDetectionConfidence = it.toFloat().coerceIn(0f, 1f) }
        (args["minHandPresenceConfidence"] as? Number)?.let { minHandPresenceConfidence = it.toFloat().coerceIn(0f, 1f) }
        (args["minHandTrackingConfidence"] as? Number)?.let { minHandTrackingConfidence = it.toFloat().coerceIn(0f, 1f) }
        (args["minPoseDetectionConfidence"] as? Number)?.let { minPoseDetectionConfidence = it.toFloat().coerceIn(0f, 1f) }
        (args["minPosePresenceConfidence"] as? Number)?.let { minPosePresenceConfidence = it.toFloat().coerceIn(0f, 1f) }
        (args["minPoseTrackingConfidence"] as? Number)?.let { minPoseTrackingConfidence = it.toFloat().coerceIn(0f, 1f) }
        // containsKey so an explicit null / "" clears an override back to the asset.
        if (args.containsKey("handModelPath")) {
            handModelPath = (args["handModelPath"] as? String)?.takeIf { it.isNotBlank() }
        }
        if (args.containsKey("poseModelPath")) {
            poseModelPath = (args["poseModelPath"] as? String)?.takeIf { it.isNotBlank() }
        }
    }

    private fun parseDelegate(name: String, fallback: Delegate): Delegate = when (name.lowercase()) {
        "gpu" -> Delegate.GPU
        "cpu" -> Delegate.CPU
        else -> fallback
    }
}

/**
 * Native CameraX preview + MediaPipe analysis behind the Flutter scanner overlay
 * (Stage B3). A single camera session drives both the [PreviewView] and an
 * [ImageAnalysis] use case that runs HandLandmarker per frame (a 2-hand
 * instance, with a 1-hand fast tracker while exactly one hand is visible) plus
 * PoseLandmarker (1 pose) on its own executor at a fixed cadence, and streams
 * the raw normalized landmarks to Dart via [LandmarkStreamHandler]. The Dart
 * side assembles the 147-dim feature vector.
 */
class CameraPreviewView(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val onDisposed: () -> Unit = {},
) : PlatformView {

    private val previewView = PreviewView(context)
    private var cameraProvider: ProcessCameraProvider? = null
    private var lensSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

    // Landmark inference runs off the main thread on a single analysis thread;
    // the landmarkers are created lazily there (model load is ~hundreds of ms).
    // The landmarker fields are @Volatile because onTuningChanged() closes and
    // nulls them from their owning executors while other threads read them.
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var handLandmarker: HandLandmarker? = null

    @Volatile
    private var poseLandmarker: PoseLandmarker? = null
    private var lastTimestampMs = 0L

    // Backoff so a permanently failing landmarker init (e.g. corrupt model
    // override) retries every LANDMARKER_RETRY_MS instead of logging at frame
    // rate. Analysis thread only.
    private var landmarkerRetryAtMs = 0L

    // Second HandLandmarker with numHands=1: with numHands=2 and only one hand
    // visible, MediaPipe re-runs palm detection EVERY frame searching the empty
    // slot (~130-170ms/frame measured 2026-07-17 on Adreno 619) — the one-hand
    // fps ceiling. Tracking the lone hand on this instance skips that; the
    // 2-hand instance still runs as a probe every ScannerTuning.handProbeIntervalMs
    // so a second hand entering the frame is picked up within that window.
    @Volatile
    private var handLandmarkerSolo: HandLandmarker? = null
    private var soloTimestampMs = 0L // solo instance's own VIDEO-mode timestamp stream
    private var trackedHandCount = 0 // analysis thread only
    private var nextProbeDueMs = 0L // analysis thread only

    // Pose feeds only the slow-moving body normalization + torso overlay, so it
    // runs OFF the hand critical path: at most every ScannerTuning.poseIntervalMs, on its
    // own executor, on its own copy of the frame. Emission never waits for it —
    // each emitted frame carries the latest completed pose result. This also
    // refreshes pose ~6x/s instead of the old every-6th-frame stride, which at
    // low frame rates left the pose skeleton up to ~1s behind the body.
    private val poseExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    @Volatile
    private var lastPoseResult: PoseLandmarkerResult? = null

    @Volatile
    private var poseInFlight = false
    private var poseBitmap: Bitmap? = null // written on the analysis thread, only while not in flight
    private var lastPoseTimestampMs = 0L // pose executor thread only
    private var nextPoseDueMs = 0L // analysis thread only
    private val frameTimestamps = ArrayDeque<Long>()

    // Extraction is capped at ScannerTuning.targetFps (see its doc for why
    // ~12fps). Advancing by the interval (not from "now") keeps the average
    // rate at the cap despite the camera delivering frames on ~33ms boundaries.
    private var nextDueMs = 0L

    // Analysis frames are all the same size, so the RGBA source bitmap is
    // allocated once and overwritten per frame (detectForVideo is synchronous,
    // nothing holds it across frames).
    private var reusableBitmap: Bitmap? = null

    // Upright (rotated) frame, also allocated once: Bitmap.createBitmap with a
    // rotation matrix allocated a full frame per analyzed frame (GC churn).
    private var rotatedBitmap: Bitmap? = null

    // Drops frames that arrive while the previous one is still being analyzed so
    // the executor queue never backs up (STRATEGY_KEEP_ONLY_LATEST + this guard).
    @Volatile
    private var analyzing = false

    @Volatile
    private var isDisposed = false

    init {
        // TextureView (not the default SurfaceView) so the preview composites
        // inside Flutter's view hierarchy. A SurfaceView draws in its own
        // window and bleeds across pages / ignores clipping.
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        startCamera()
    }

    /** Binds the preview + analysis use cases, once the CAMERA permission is granted. */
    fun startCamera() {
        if (isDisposed) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (isDisposed) return@addListener
            val provider = future.get()
            cameraProvider = provider
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
                .also { it.setAnalyzer(analysisExecutor, ::analyze) }
            try {
                provider.unbindAll()
                provider.bindToLifecycle(lifecycleOwner, lensSelector, preview, analysis)
            } catch (_: Exception) {
                // No camera for this lens / already bound — preview stays blank.
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Switches the bound camera between "back" and "front" and rebinds. */
    fun setLens(facing: String) {
        if (isDisposed) return
        lensSelector = if (facing == "front") {
            CameraSelector.DEFAULT_FRONT_CAMERA
        } else {
            CameraSelector.DEFAULT_BACK_CAMERA
        }
        startCamera()
    }

    /**
     * Applies a ScannerTuning change: tears the landmarkers down on their own
     * executors so the next frame lazily rebuilds them with the new delegates,
     * thresholds, and model overrides. Cadence fields (fps / pose / probe
     * intervals) are read live per frame and need no rebuild. An in-flight
     * pose detect can race the close and throw once; its catch handles that.
     */
    fun onTuningChanged() {
        if (isDisposed) return
        analysisExecutor.execute {
            try {
                handLandmarker?.close()
            } catch (_: Exception) {}
            handLandmarker = null
            try {
                handLandmarkerSolo?.close()
            } catch (_: Exception) {}
            handLandmarkerSolo = null
            trackedHandCount = 0
            nextProbeDueMs = 0L
            landmarkerRetryAtMs = 0L
        }
        poseExecutor.execute {
            try {
                poseLandmarker?.close()
            } catch (_: Exception) {}
            poseLandmarker = null
            lastPoseResult = null
        }
    }

    /** Runs on [analysisExecutor]: one frame -> hands + pose -> emit to Dart. */
    private fun analyze(image: ImageProxy) {
        if (isDisposed || analyzing) {
            image.close()
            return
        }
        val arrivalMs = SystemClock.elapsedRealtime()
        if (arrivalMs < nextDueMs) {
            image.close()
            return
        }
        nextDueMs = maxOf(nextDueMs + ScannerTuning.frameIntervalMs, arrivalMs)
        analyzing = true
        try {
            ensureLandmarkers()
            if (isDisposed) return
            val t0 = SystemClock.elapsedRealtime()
            val uprightBitmap = image.toUprightBitmap()
            val mpImage = BitmapImageBuilder(uprightBitmap).build()
            val t1 = SystemClock.elapsedRealtime()
            // VIDEO mode requires strictly increasing timestamps per landmarker,
            // and PoseLandmarker's built-in landmark smoothing derives its filter
            // strength from the timestamp deltas — a 1ms-per-frame counter made it
            // over-smooth ~70x, so the pose skeleton trailed the body. Feed real
            // elapsed milliseconds instead (guarded to stay strictly increasing).
            val nowMs = SystemClock.elapsedRealtime()
            val handResult = detectHands(mpImage, nowMs)
            val t2 = SystemClock.elapsedRealtime()
            // Pose runs on its own executor (see maybeSubmitPose); the emitted
            // frame pairs this hand result with the latest completed pose so
            // emission never stalls on pose inference.
            maybeSubmitPose(uprightBitmap, t2)
            LandmarkStreamHandler.emit(
                buildFrame(handResult, lastPoseResult, uprightBitmap.width, uprightBitmap.height),
            )
            frameTimestamps.addLast(t2)
            while (frameTimestamps.isNotEmpty() && t2 - frameTimestamps.first() > 1000L) {
                frameTimestamps.removeFirst()
            }
            val fps = frameTimestamps.size
            Log.d(TAG, "frame ms: bitmap=${t1 - t0} hand=${t2 - t1} hands=$trackedHandCount total=${t2 - t0} fps=$fps")
        } catch (e: Exception) {
            // A dropped/garbled frame just skips one overlay update, but never
            // silently: a per-frame throw here otherwise looks like a dead feed.
            Log.e(TAG, "analyze failed", e)
        } finally {
            analyzing = false
            image.close()
        }
    }

    /**
     * Runs on the analysis thread: routes the frame to the cheap 1-hand tracker
     * while exactly one hand is tracked, falling back to the 2-hand instance
     * otherwise — and as a periodic probe (every ScannerTuning.handProbeIntervalMs)
     * so a second hand entering the frame is picked up within that window. Each
     * instance keeps its own strictly-increasing VIDEO-mode timestamp stream.
     */
    private fun detectHands(mpImage: MPImage, nowMs: Long): HandLandmarkerResult? {
        val solo = handLandmarkerSolo
        val useSolo = solo != null && trackedHandCount == 1 && nowMs < nextProbeDueMs
        val result = if (useSolo) {
            val ts = if (nowMs > soloTimestampMs) nowMs else soloTimestampMs + 1
            soloTimestampMs = ts
            solo.detectForVideo(mpImage, ts)
        } else {
            val ts = if (nowMs > lastTimestampMs) nowMs else lastTimestampMs + 1
            lastTimestampMs = ts
            handLandmarker?.detectForVideo(mpImage, ts)
        }
        val count = result?.landmarks()?.size ?: 0
        if (count == 1) {
            // A 2-hand run (initial detection or an expired-window probe) that
            // sees exactly one hand arms/re-arms the solo window; solo runs
            // ride out the window they were given.
            if (!useSolo) nextProbeDueMs = nowMs + ScannerTuning.handProbeIntervalMs
        } else {
            nextProbeDueMs = 0L // 0 or 2 hands: the 2-hand instance takes every frame
        }
        trackedHandCount = count
        return result
    }

    /**
     * Runs on the analysis thread: hands the pose executor its own copy of the
     * upright frame at most once per ScannerTuning.poseIntervalMs. The copy is required
     * because the analyzer overwrites the reusable analysis bitmap on the next
     * frame while the pose graph may still be reading; the copy itself is only
     * rewritten between pose runs (guarded by [poseInFlight]). Pose uses the
     * CPU delegate (see ensureLandmarkers) so the overlap costs the hand graph
     * no GPU contention.
     */
    private fun maybeSubmitPose(source: Bitmap, nowMs: Long) {
        if (poseInFlight || nowMs < nextPoseDueMs) return
        val landmarker = poseLandmarker ?: return
        nextPoseDueMs = nowMs + ScannerTuning.poseIntervalMs
        val copy = poseBitmap
            ?.takeIf { it.width == source.width && it.height == source.height }
            ?: Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
                .also { poseBitmap = it }
        Canvas(copy).drawBitmap(source, 0f, 0f, null)
        poseInFlight = true
        poseExecutor.execute {
            try {
                if (!isDisposed) {
                    val nowPoseMs = SystemClock.elapsedRealtime()
                    val ts = if (nowPoseMs > lastPoseTimestampMs) nowPoseMs else lastPoseTimestampMs + 1
                    lastPoseTimestampMs = ts
                    val t0 = SystemClock.elapsedRealtime()
                    lastPoseResult = landmarker.detectForVideo(BitmapImageBuilder(copy).build(), ts)
                    Log.d(TAG, "pose ms: ${SystemClock.elapsedRealtime() - t0}")
                }
            } catch (e: Exception) {
                // A failed pose run just keeps the previous pose for a beat;
                // logged so a permanently dead pose feed is visible.
                Log.e(TAG, "pose detect failed", e)
            } finally {
                poseInFlight = false
            }
        }
    }

    private fun ensureLandmarkers() {
        if (isDisposed) return
        if (handLandmarker != null && handLandmarkerSolo != null && poseLandmarker != null) return
        val nowMs = SystemClock.elapsedRealtime()
        if (nowMs < landmarkerRetryAtMs) return
        // Delegate defaults (ScannerTuning): hand GPU, pose CPU.
        // Hand stays on the GPU. Re-measured 2026-07-12 on the release build
        // (Redmi Note 12 5G, two hands tracked): GPU 70-98ms vs CPU/XNNPACK
        // 51-115ms — same ~8.9fps either way, but CPU-hand made the GPU pose
        // slower (56-81ms vs 33-45ms) and steals big cores from Dart. Two-hand
        // tracking is compute-bound on this class of device; <=1 hand hits the
        // 12fps cap.
        if (handLandmarker == null) {
            handLandmarker = buildHandLandmarkerOrNull(numHands = 2)
        }
        if (handLandmarkerSolo == null) {
            handLandmarkerSolo = buildHandLandmarkerOrNull(numHands = 1)
        }
        // Pose runs on CPU on purpose: it executes concurrently with hand (own
        // executor), and on the GPU the two contend — measured 2026-07-17 while
        // signing: hand inflated 143-244ms (vs ~100ms alone) whenever a ~100ms
        // GPU pose overlapped, capping the pipeline at ~6fps. CPU/XNNPACK pose
        // costs a few big-core bursts ~6x/s but leaves the GPU hand-exclusive.
        if (poseLandmarker == null) {
            poseLandmarker = buildPoseLandmarkerOrNull()
        }
        if (handLandmarker == null || handLandmarkerSolo == null || poseLandmarker == null) {
            landmarkerRetryAtMs = nowMs + LANDMARKER_RETRY_MS
        }
    }

    /**
     * Builds a HandLandmarker on the ScannerTuning delegate, falling back to
     * CPU when GPU init throws (unsupported driver / emulator). If init fails
     * outright while a model override is set (e.g. a corrupt download), the
     * override is cleared and the bundled asset tried once — a bad OTA model
     * must never kill the scanner. Returns null when even that fails so
     * ensureLandmarkers backs off instead of logging at frame rate.
     */
    private fun buildHandLandmarkerOrNull(numHands: Int): HandLandmarker? {
        val built = buildHandLandmarkerAnyDelegate(numHands)
        if (built == null && ScannerTuning.handModelPath != null) {
            Log.w(TAG, "hand model override rejected — reverting to bundled $HAND_MODEL")
            ScannerTuning.handModelPath = null
            return buildHandLandmarkerAnyDelegate(numHands)
        }
        return built
    }

    private fun buildHandLandmarkerAnyDelegate(numHands: Int): HandLandmarker? {
        val preferred = ScannerTuning.handDelegate
        return try {
            buildHandLandmarker(preferred, numHands)
        } catch (e: Exception) {
            if (preferred == Delegate.GPU) {
                Log.w(TAG, "HandLandmarker($numHands) GPU delegate unavailable, using CPU", e)
                try {
                    buildHandLandmarker(Delegate.CPU, numHands)
                } catch (e2: Exception) {
                    Log.e(TAG, "HandLandmarker($numHands) init failed", e2)
                    null
                }
            } else {
                Log.e(TAG, "HandLandmarker($numHands) init failed", e)
                null
            }
        }
    }

    /** Pose counterpart of [buildHandLandmarkerOrNull], same override self-heal. */
    private fun buildPoseLandmarkerOrNull(): PoseLandmarker? {
        val built = buildPoseLandmarkerAnyDelegate()
        if (built == null && ScannerTuning.poseModelPath != null) {
            Log.w(TAG, "pose model override rejected — reverting to bundled $POSE_MODEL")
            ScannerTuning.poseModelPath = null
            return buildPoseLandmarkerAnyDelegate()
        }
        return built
    }

    private fun buildPoseLandmarkerAnyDelegate(): PoseLandmarker? {
        val preferred = ScannerTuning.poseDelegate
        return try {
            buildPoseLandmarker(preferred)
        } catch (e: Exception) {
            if (preferred == Delegate.GPU) {
                Log.w(TAG, "PoseLandmarker GPU delegate unavailable, using CPU", e)
                try {
                    buildPoseLandmarker(Delegate.CPU)
                } catch (e2: Exception) {
                    Log.e(TAG, "PoseLandmarker init failed", e2)
                    null
                }
            } else {
                Log.e(TAG, "PoseLandmarker init failed", e)
                null
            }
        }
    }

    private fun buildHandLandmarker(delegate: Delegate, numHands: Int): HandLandmarker =
        HandLandmarker.createFromOptions(
            context,
            HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(baseOptions(delegate, ScannerTuning.handModelPath, HAND_MODEL))
                .setRunningMode(RunningMode.VIDEO)
                .setNumHands(numHands)
                .setMinHandDetectionConfidence(ScannerTuning.minHandDetectionConfidence)
                .setMinHandPresenceConfidence(ScannerTuning.minHandPresenceConfidence)
                .setMinTrackingConfidence(ScannerTuning.minHandTrackingConfidence)
                .build(),
        )

    private fun buildPoseLandmarker(delegate: Delegate): PoseLandmarker =
        PoseLandmarker.createFromOptions(
            context,
            PoseLandmarker.PoseLandmarkerOptions.builder()
                .setBaseOptions(baseOptions(delegate, ScannerTuning.poseModelPath, POSE_MODEL))
                .setRunningMode(RunningMode.VIDEO)
                .setNumPoses(1)
                .setMinPoseDetectionConfidence(ScannerTuning.minPoseDetectionConfidence)
                .setMinPosePresenceConfidence(ScannerTuning.minPosePresenceConfidence)
                .setMinTrackingConfidence(ScannerTuning.minPoseTrackingConfidence)
                .build(),
        )

    /**
     * Base options for a landmarker: memory-maps the model from
     * [overridePath] when that file exists (Dart downloads replacement models
     * there — Shorebird cannot patch bundled assets), else loads the bundled
     * [assetName]. A missing or unreadable override never kills the pipeline;
     * it logs and falls back to the asset.
     */
    private fun baseOptions(delegate: Delegate, overridePath: String?, assetName: String): BaseOptions {
        val builder = BaseOptions.builder().setDelegate(delegate)
        if (overridePath != null) {
            try {
                val file = File(overridePath)
                if (file.isFile && file.length() > 0L) {
                    FileInputStream(file).use { stream ->
                        // The mapping stays valid after the stream closes; the
                        // buffer itself holds it.
                        builder.setModelAssetBuffer(
                            stream.channel.map(FileChannel.MapMode.READ_ONLY, 0, file.length()),
                        )
                    }
                    return builder.build()
                }
                Log.w(TAG, "model override not found: $overridePath — using bundled $assetName")
            } catch (e: Exception) {
                Log.w(TAG, "model override unreadable: $overridePath — using bundled $assetName", e)
            }
        }
        return builder.setModelAssetPath(assetName).build()
    }

    /**
     * Builds the EventChannel payload:
     *   { 'pose': [x,y,z * 33] | [], 'hands': [ {'handedness', 'landmarks': [x,y,z*21]} ],
     *     'width': <analysis image px>, 'height': <analysis image px> }
     * with MediaPipe normalized image coordinates (x,y in 0..1, z relative depth).
     * width/height are the upright analysis image dimensions so the Dart overlay
     * can replicate the PreviewView FILL_CENTER cover-crop when mapping points.
     */
    private fun buildFrame(
        hand: HandLandmarkerResult?,
        pose: PoseLandmarkerResult?,
        imageWidth: Int,
        imageHeight: Int,
    ): Map<String, Any?> {
        val hands = mutableListOf<Map<String, Any?>>()
        if (hand != null) {
            val handednesses = hand.handedness()
            hand.landmarks().forEachIndexed { i, marks ->
                val coords = ArrayList<Double>(marks.size * 3)
                for (lm in marks) {
                    coords.add(lm.x().toDouble())
                    coords.add(lm.y().toDouble())
                    coords.add(lm.z().toDouble())
                }
                val label = handednesses.getOrNull(i)?.firstOrNull()?.categoryName() ?: ""
                hands.add(mapOf("handedness" to label, "landmarks" to coords))
            }
        }

        val poseCoords = ArrayList<Double>()
        val poseMarks = pose?.landmarks()
        if (!poseMarks.isNullOrEmpty()) {
            for (lm in poseMarks[0]) {
                poseCoords.add(lm.x().toDouble())
                poseCoords.add(lm.y().toDouble())
                poseCoords.add(lm.z().toDouble())
            }
        }

        return mapOf(
            "pose" to poseCoords,
            "hands" to hands,
            "width" to imageWidth,
            "height" to imageHeight,
        )
    }

    /**
     * Copies the RGBA_8888 analysis frame into an upright ARGB bitmap. Follows
     * the MediaPipe Android sample: the analysis buffer is tightly packed for
     * these preview resolutions, then rotated by the reported sensor rotation
     * so MediaPipe sees the image the same way up as the user.
     */
    private fun ImageProxy.toUprightBitmap(): Bitmap {
        val bitmap = reusableBitmap?.takeIf { it.width == width && it.height == height }
            ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                .also { reusableBitmap = it }
        bitmap.copyPixelsFromBuffer(planes[0].buffer)
        val rotation = imageInfo.rotationDegrees
        if (rotation == 0) return bitmap
        val outW = if (rotation % 180 == 0) width else height
        val outH = if (rotation % 180 == 0) height else width
        val out = rotatedBitmap?.takeIf { it.width == outW && it.height == outH }
            ?: Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
                .also { rotatedBitmap = it }
        // Rotate about the center, then shift into the output's frame. 90°
        // multiples are pixel-exact, so no filtering paint is needed.
        val matrix = Matrix().apply {
            postTranslate(-width / 2f, -height / 2f)
            postRotate(rotation.toFloat())
            postTranslate(outW / 2f, outH / 2f)
        }
        Canvas(out).drawBitmap(bitmap, matrix, null)
        return out
    }

    override fun getView(): View = previewView

    override fun dispose() {
        isDisposed = true
        cameraProvider?.unbindAll()
        cameraProvider = null
        analysisExecutor.execute {
            try {
                handLandmarker?.close()
            } catch (_: Exception) {}
            handLandmarker = null
            try {
                handLandmarkerSolo?.close()
            } catch (_: Exception) {}
            handLandmarkerSolo = null
        }
        // Pose closes on its own executor so the close queues behind any
        // in-flight detect instead of racing it.
        poseExecutor.execute {
            try {
                poseLandmarker?.close()
            } catch (_: Exception) {}
            poseLandmarker = null
        }
        analysisExecutor.shutdown()
        poseExecutor.shutdown()
        onDisposed()
    }

    companion object {
        private const val TAG = "SignMindCamera"
        private const val HAND_MODEL = "hand_landmarker.task"
        // FULL variant on purpose, matching training and tsl_live_inference.py:
        // every feature is normalized by the 3D shoulder width (z included),
        // and lite's noisier z rescaled the whole vector in ways the model
        // never saw — confidently-wrong predictions on-device while the Python
        // reference recognized the same signs. Full is affordable now that
        // pose runs ~6x/s on the CPU executor instead of inline per frame.
        private const val POSE_MODEL = "pose_landmarker_full.task"
        // Cadence knobs (fps, pose interval, hand probe) live in ScannerTuning
        // so Dart can retune them OTA.
        private const val LANDMARKER_RETRY_MS = 3000L
    }
}
