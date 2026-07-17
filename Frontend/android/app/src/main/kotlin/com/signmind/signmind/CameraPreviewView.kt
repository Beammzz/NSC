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
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult
import io.flutter.plugin.platform.PlatformView
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native CameraX preview + MediaPipe analysis behind the Flutter scanner overlay
 * (Stage B3). A single camera session drives both the [PreviewView] and an
 * [ImageAnalysis] use case that runs HandLandmarker (2 hands) per frame plus
 * PoseLandmarker (1 pose) on its own executor at a fixed cadence, and streams
 * the raw normalized landmarks to Dart via [LandmarkStreamHandler]. The Dart
 * side assembles the 147-dim feature vector.
 */
class CameraPreviewView(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
) : PlatformView {

    private val previewView = PreviewView(context)
    private var cameraProvider: ProcessCameraProvider? = null
    private var lensSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

    // Landmark inference runs off the main thread on a single analysis thread;
    // the landmarkers are created lazily there (model load is ~hundreds of ms).
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var handLandmarker: HandLandmarker? = null
    private var poseLandmarker: PoseLandmarker? = null
    private var lastTimestampMs = 0L

    // Pose feeds only the slow-moving body normalization + torso overlay, so it
    // runs OFF the hand critical path: at most every POSE_INTERVAL_MS, on its
    // own executor, on its own copy of the frame. Emission never waits for it —
    // each emitted frame carries the latest completed pose result. This also
    // refreshes pose ~4x/s instead of the old every-6th-frame stride, which at
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

    // Extraction is capped at TARGET_FPS to match the ~12fps the model was
    // trained on (the server windows 30 frames regardless of rate, so faster
    // capture would shrink the window's time span). Advancing by the interval
    // (not from "now") keeps the average rate at TARGET_FPS despite the camera
    // delivering frames on ~33ms boundaries.
    private var nextDueMs = 0L

    // Analysis frames are all the same size, so the RGBA source bitmap is
    // allocated once and overwritten per frame (detectForVideo is synchronous,
    // nothing holds it across frames).
    private var reusableBitmap: Bitmap? = null

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
        nextDueMs = maxOf(nextDueMs + FRAME_INTERVAL_MS, arrivalMs)
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
            val ts = if (nowMs > lastTimestampMs) nowMs else lastTimestampMs + 1
            lastTimestampMs = ts
            val handResult = handLandmarker?.detectForVideo(mpImage, ts)
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
            Log.d(TAG, "frame ms: bitmap=${t1 - t0} hand=${t2 - t1} total=${t2 - t0} fps=$fps")
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
     * Runs on the analysis thread: hands the pose executor its own copy of the
     * upright frame at most once per POSE_INTERVAL_MS. The copy is required
     * because the analyzer overwrites the reusable analysis bitmap on the next
     * frame while the pose graph may still be reading; the copy itself is only
     * rewritten between pose runs (guarded by [poseInFlight]). Pose uses the
     * CPU delegate (see ensureLandmarkers) so the overlap costs the hand graph
     * no GPU contention.
     */
    private fun maybeSubmitPose(source: Bitmap, nowMs: Long) {
        if (poseInFlight || nowMs < nextPoseDueMs) return
        val landmarker = poseLandmarker ?: return
        nextPoseDueMs = nowMs + POSE_INTERVAL_MS
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
        // Both models default to CPU, which caps two-model throughput at ~6fps on
        // this device; run them on the GPU delegate and fall back to CPU only if
        // GPU init throws (unsupported driver / emulator).
        // Hand stays on the GPU. Re-measured 2026-07-12 on the release build
        // (Redmi Note 12 5G, two hands tracked): GPU 70-98ms vs CPU/XNNPACK
        // 51-115ms — same ~8.9fps either way, but CPU-hand made the GPU pose
        // slower (56-81ms vs 33-45ms) and steals big cores from Dart. Two-hand
        // tracking is compute-bound on this class of device; <=1 hand hits the
        // 12fps cap.
        if (handLandmarker == null) {
            handLandmarker = try {
                buildHandLandmarker(Delegate.GPU)
            } catch (e: Exception) {
                Log.w(TAG, "HandLandmarker GPU delegate unavailable, using CPU", e)
                buildHandLandmarker(Delegate.CPU)
            }
        }
        // Pose runs on CPU on purpose: it executes concurrently with hand (own
        // executor), and on the GPU the two contend — measured 2026-07-17 while
        // signing: hand inflated 143-244ms (vs ~100ms alone) whenever a ~100ms
        // GPU pose overlapped, capping the pipeline at ~6fps. CPU/XNNPACK pose
        // costs a few big-core bursts 4x/s but leaves the GPU hand-exclusive.
        if (poseLandmarker == null) {
            poseLandmarker = buildPoseLandmarker(Delegate.CPU)
        }
    }

    private fun buildHandLandmarker(delegate: Delegate): HandLandmarker =
        HandLandmarker.createFromOptions(
            context,
            HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath(HAND_MODEL)
                        .setDelegate(delegate)
                        .build(),
                )
                .setRunningMode(RunningMode.VIDEO)
                .setNumHands(2)
                .build(),
        )

    private fun buildPoseLandmarker(delegate: Delegate): PoseLandmarker =
        PoseLandmarker.createFromOptions(
            context,
            PoseLandmarker.PoseLandmarkerOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath(POSE_MODEL)
                        .setDelegate(delegate)
                        .build(),
                )
                .setRunningMode(RunningMode.VIDEO)
                .setNumPoses(1)
                .build(),
        )

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
        val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, width, height, matrix, true)
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
    }

    companion object {
        private const val TAG = "SignMindCamera"
        private const val HAND_MODEL = "hand_landmarker.task"
        // Lite variant on purpose: pose only feeds the slow-moving torso
        // normalization + overlay, and full cost 46-180ms/frame on the GPU of
        // a Redmi Note 12 5G vs ~15-40ms for lite.
        private const val POSE_MODEL = "pose_landmarker_lite.task"
        // Pose refreshes ~4x/s on its own executor — enough for the
        // slow-moving torso normalization + overlay it feeds.
        private const val POSE_INTERVAL_MS = 250L
        private const val TARGET_FPS = 12
        private const val FRAME_INTERVAL_MS = 1000L / TARGET_FPS
    }
}
