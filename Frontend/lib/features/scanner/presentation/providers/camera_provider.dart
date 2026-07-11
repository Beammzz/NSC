import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// PlatformView type id of the native CameraX preview (Stage B, Android only).
/// Must match `MainActivity.CAMERA_PREVIEW_VIEW_TYPE` in the Android host.
const nativeCameraViewType = 'signmind/camera_preview';

/// Which camera the scanner preview shows. Defaults to the back camera:
/// MediaPipe handedness (Stage B/C) only matches the trained model on a
/// non-mirrored back-camera feed, so the front camera is preview-only.
class SelectedCameraLens extends Notifier<CameraLensDirection> {
  @override
  CameraLensDirection build() => CameraLensDirection.back;

  /// Switches between the back and front camera.
  void flip() {
    state = state == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
  }
}

final selectedCameraLensProvider =
    NotifierProvider<SelectedCameraLens, CameraLensDirection>(
  SelectedCameraLens.new,
);

/// Initializes the [selectedCameraLensProvider] camera for the scanner
/// preview (Stage A).
///
/// Resolves to an initialized [CameraController], or `null` when no usable
/// camera is available — no hardware, permission denied, camera busy, or
/// running under `flutter test` where the platform channel is absent. The UI
/// falls back to its gradient background on `null`, so nothing crashes when a
/// camera cannot be opened.
///
/// Stage B replaces this with a native CameraX session that also feeds
/// MediaPipe; app-lifecycle pause/resume is deferred to that rework.
final cameraControllerProvider = FutureProvider<CameraController?>((ref) async {
  // Android uses the native CameraX PlatformView (Stage B), which also runs
  // MediaPipe. Returning null here keeps the `camera` plugin from opening the
  // camera and colliding with the native session.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return null;

  final lens = ref.watch(selectedCameraLensProvider);
  final List<CameraDescription> cameras;
  try {
    cameras = await availableCameras();
  } catch (_) {
    return null;
  }
  if (cameras.isEmpty) return null;

  final description = cameras.firstWhere(
    (c) => c.lensDirection == lens,
    orElse: () => cameras.first,
  );

  final controller = CameraController(
    description,
    ResolutionPreset.medium,
    enableAudio: false,
  );

  try {
    await controller.initialize();
  } catch (_) {
    await controller.dispose();
    return null;
  }

  ref.onDispose(controller.dispose);
  return controller;
});
