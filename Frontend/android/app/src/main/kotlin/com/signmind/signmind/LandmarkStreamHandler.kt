package com.signmind.signmind

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Bridges native MediaPipe landmark frames to the Dart
 * `MediaPipeLandmarkExtractionService` over the `signmind/landmarks`
 * EventChannel. The CameraX analyzer (Stage B3) calls [emit]; results are
 * posted to the main thread as required by Flutter EventSinks.
 */
object LandmarkStreamHandler : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Posts one landmark frame to Dart; a no-op when nothing is listening. */
    fun emit(frame: Map<String, Any?>) {
        val current = sink ?: return
        mainHandler.post { current.success(frame) }
    }
}
