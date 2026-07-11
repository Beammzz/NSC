package com.signmind.signmind

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native CameraX preview + MediaPipe analysis behind the Flutter scanner overlay
 * (Stage B3). A single camera session drives both the [PreviewView] and an
 * [ImageAnalysis] use case that runs HandLandmarker (2 hands) + PoseLandmarker
 * (1 pose) per frame and streams the raw normalized landmarks to Dart via
 * [LandmarkStreamHandler]. The Dart side assembles the 147-dim feature vector.
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
        analyzing = true
        try {
            ensureLandmarkers()
            if (isDisposed) return
            val t0 = SystemClock.elapsedRealtime()
            val mpImage = BitmapImageBuilder(image.toUprightBitmap()).build()
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
            val poseResult = poseLandmarker?.detectForVideo(mpImage, ts)
            val t3 = SystemClock.elapsedRealtime()
            LandmarkStreamHandler.emit(buildFrame(handResult, poseResult))
            Log.d(TAG, "frame ms: bitmap=${t1 - t0} hand=${t2 - t1} pose=${t3 - t2} total=${t3 - t0}")
        } catch (_: Exception) {
            // A dropped/garbled frame just skips one overlay update.
        } finally {
            analyzing = false
            image.close()
        }
    }

    private fun ensureLandmarkers() {
        if (isDisposed) return
        // Both models default to CPU, which caps two-model throughput at ~6fps on
        // this device; run them on the GPU delegate and fall back to CPU only if
        // GPU init throws (unsupported driver / emulator).
        if (handLandmarker == null) {
            handLandmarker = try {
                buildHandLandmarker(Delegate.GPU)
            } catch (e: Exception) {
                Log.w(TAG, "HandLandmarker GPU delegate unavailable, using CPU", e)
                buildHandLandmarker(Delegate.CPU)
            }
        }
        if (poseLandmarker == null) {
            poseLandmarker = try {
                buildPoseLandmarker(Delegate.GPU)
            } catch (e: Exception) {
                Log.w(TAG, "PoseLandmarker GPU delegate unavailable, using CPU", e)
                buildPoseLandmarker(Delegate.CPU)
            }
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
     *   { 'pose': [x,y,z * 33] | [], 'hands': [ {'handedness', 'landmarks': [x,y,z*21]} ] }
     * with MediaPipe normalized image coordinates (x,y in 0..1, z relative depth).
     */
    private fun buildFrame(
        hand: HandLandmarkerResult?,
        pose: PoseLandmarkerResult?,
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

        return mapOf("pose" to poseCoords, "hands" to hands)
    }

    /**
     * Copies the RGBA_8888 analysis frame into an upright ARGB bitmap. Follows
     * the MediaPipe Android sample: the analysis buffer is tightly packed for
     * these preview resolutions, then rotated by the reported sensor rotation
     * so MediaPipe sees the image the same way up as the user.
     */
    private fun ImageProxy.toUprightBitmap(): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
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
            try {
                poseLandmarker?.close()
            } catch (_: Exception) {}
            handLandmarker = null
            poseLandmarker = null
        }
        analysisExecutor.shutdown()
    }

    companion object {
        private const val TAG = "SignMindCamera"
        private const val HAND_MODEL = "hand_landmarker.task"
        private const val POSE_MODEL = "pose_landmarker_full.task"
    }
}
