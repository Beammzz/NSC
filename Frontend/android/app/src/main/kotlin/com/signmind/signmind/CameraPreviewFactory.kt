package com.signmind.signmind

import android.content.Context
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Creates the native CameraX [CameraPreviewView] for the Flutter `AndroidView`
 * of type [MainActivity.CAMERA_PREVIEW_VIEW_TYPE]. Keeps a reference to the last
 * created view so the activity can (re)start it once the camera permission is
 * granted.
 */
class CameraPreviewFactory(
    private val lifecycleOwner: LifecycleOwner,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    var lastView: CameraPreviewView? = null
        private set

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val view = CameraPreviewView(context, lifecycleOwner)
        lastView = view
        return view
    }
}
