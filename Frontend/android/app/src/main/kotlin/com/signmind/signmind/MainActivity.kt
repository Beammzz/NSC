package com.signmind.signmind

import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the native CameraX preview PlatformView and the landmark EventChannel
 * for the scanner (Stage B). Uses [FlutterFragmentActivity] because CameraX's
 * `bindToLifecycle` needs an androidx [androidx.lifecycle.LifecycleOwner].
 */
class MainActivity : FlutterFragmentActivity() {
    private val cameraFactory = CameraPreviewFactory(this)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.platformViewsController.registry
            .registerViewFactory(CAMERA_PREVIEW_VIEW_TYPE, cameraFactory)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LANDMARK_CHANNEL)
            .setStreamHandler(LandmarkStreamHandler)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CONTROL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setLens" -> {
                        val facing = call.argument<String>("facing") ?: "back"
                        cameraFactory.lastView?.setLens(facing)
                        result.success(null)
                    }
                    // Applies ScannerTuning knobs (cadence, delegates,
                    // confidence thresholds, model-file overrides) from Dart —
                    // the OTA-patchable side. Tuning is process-wide, so a
                    // configure call made before the preview exists still
                    // applies when the view is created.
                    "configure" -> {
                        (call.arguments as? Map<*, *>)?.let { ScannerTuning.update(it) }
                        cameraFactory.lastView?.onTuningChanged()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.CAMERA),
                CAMERA_PERMISSION_REQUEST,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_REQUEST &&
            grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            // The preview view may have been created before the grant; start it now.
            cameraFactory.lastView?.startCamera()
        }
    }

    companion object {
        const val CAMERA_PREVIEW_VIEW_TYPE = "signmind/camera_preview"
        const val LANDMARK_CHANNEL = "signmind/landmarks"
        const val CAMERA_CONTROL_CHANNEL = "signmind/camera"
        private const val CAMERA_PERMISSION_REQUEST = 4919
    }
}
