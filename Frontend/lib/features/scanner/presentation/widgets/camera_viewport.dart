import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/core/widgets/main_scaffold.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
import 'package:signmind/features/scanner/presentation/providers/camera_provider.dart';
import 'package:signmind/features/scanner/presentation/providers/scanner_provider.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

/// Control channel for the native CameraX session (Stage B), e.g. switching
/// the bound lens. Matches `MainActivity.CAMERA_CONTROL_CHANNEL`.
const _cameraControlChannel = MethodChannel('signmind/camera');

class CameraViewport extends ConsumerStatefulWidget {
  const CameraViewport({
    super.key,
    required this.state,
    required this.onToggleScan,
  });

  final ScannerState state;
  final VoidCallback onToggleScan;

  @override
  ConsumerState<CameraViewport> createState() => _CameraViewportState();
}

class _CameraViewportState extends ConsumerState<CameraViewport> {
  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cameraAsync = ref.watch(cameraControllerProvider);
    // The front preview is mirrored by PreviewView, so mirror the overlay to
    // match it; the underlying MediaPipe analysis stays un-mirrored.
    final mirrorOverlay =
        ref.watch(selectedCameraLensProvider) == CameraLensDirection.front;
    final isDetecting = state.isScanning && state.demoPhase == 0;
    final isDetected = state.isScanning && !isDetecting;
    final confPercent = (state.confidence * 100).round();
    final okColor = state.confidence >= 0.85
        ? AppTheme.successGreen
        : AppTheme.warningOrange;

    return Container(
      constraints: const BoxConstraints(maxHeight: 380, minHeight: 180),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF17222F),
            Color(0xFF101A26),
            Color(0xFF0C141E),
          ],
        ),
        border: Border.all(color: context.borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              // Live back-camera preview. Falls back to the gradient
              // background when the camera is unavailable (no permission,
              // no hardware, or under `flutter test`).
              Positioned.fill(child: _buildCameraLayer(cameraAsync)),



              // MediaPipe body skeleton — both 21-point hands plus the 7 upper
              // pose points — painted over the full preview so it tracks the
              // real body in the camera feed (matches the 147-dim layout).
              Positioned.fill(
                child: _LandmarkOverlay(
                  isDetected: isDetected,
                  accentColor: isDetected ? okColor : AppTheme.primaryAccent,
                  mirror: mirrorOverlay,
                ),
              ),

              // FPS / latency / confidence debug chips — only when enabled
              if (ref.watch(settingsProvider.select((s) => s.showDebugOverlay))) ...[
                // FPS / latency chips (bottom left)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: Row(
                    children: [
                      _buildChip(
                        state.isScanning ? '${state.fps} FPS' : '— FPS',
                      ),
                      const SizedBox(width: 6),
                      _buildChip(
                        state.isScanning ? 'หน่วง ${state.latencySeconds} วิ' : '—',
                      ),
                    ],
                  ),
                ),

                // Confidence chip (bottom right)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: context.isDarkMode
                          ? AppTheme.darkNavy.withAlpha(200)
                          : Colors.white.withAlpha(220),
                      border: Border.all(color: context.borderColor, width: 1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isDetected ? 'ความเชื่อมั่น $confPercent%' : 'ความเชื่อมั่น —',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isDetected ? okColor : context.textMutedColor,
                      ),
                    ),
                  ),
                ),
              ],

              // Flip-camera button (top right, left of pause) — shown when a
              // switchable camera exists: the native CameraX session on Android,
              // or the `camera`-plugin controller elsewhere.
              if (cameraAsync.asData?.value != null ||
                  (!kIsWeb && defaultTargetPlatform == TargetPlatform.android))
                Positioned(
                  top: 10,
                  right: 56,
                  child: GestureDetector(
                    onTap: _flipCamera,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: context.isDarkMode
                            ? AppTheme.darkNavy.withAlpha(184)
                            : Colors.white.withAlpha(220),
                        shape: BoxShape.circle,
                        border: Border.all(color: context.borderColor, width: 1),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.cameraswitch,
                        size: 18,
                        color: context.textColor,
                      ),
                    ),
                  ),
                ),

              // Pause / Play toggle button (top right)
              Positioned(
                top: 10,
                right: 10,
                child: GestureDetector(
                  onTap: widget.onToggleScan,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: context.isDarkMode
                          ? AppTheme.darkNavy.withAlpha(184)
                          : Colors.white.withAlpha(220),
                      shape: BoxShape.circle,
                      border: Border.all(color: context.borderColor, width: 1),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      state.isScanning ? Icons.pause : Icons.play_arrow,
                      size: 18,
                      color: context.textColor,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Toggles the preview between the back and front camera. Back is the
  /// default because MediaPipe handedness (Stage B/C) only matches the trained
  /// model on the non-mirrored back-camera feed.
  void _flipCamera() {
    ref.read(selectedCameraLensProvider.notifier).flip();
    // On Android the native CameraX session owns the camera, so the lens
    // switch goes over the control channel rather than the `camera` plugin.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final lens = ref.read(selectedCameraLensProvider);
      _cameraControlChannel.invokeMethod<void>('setLens', {
        'facing': lens == CameraLensDirection.back ? 'back' : 'front',
      }).catchError((Object _) {});
    }
  }

  /// Renders the live camera feed, cover-fitted into the viewport. Returns an
  /// empty box while the controller is loading/errored/unavailable so the
  /// gradient background shows through.
  Widget _buildCameraLayer(AsyncValue<CameraController?> cameraAsync) {
    // Android renders the native CameraX PlatformView (Stage B), which also
    // hosts the MediaPipe analysis. Other platforms use the `camera` plugin.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // The shell keeps every tab alive in an IndexedStack; only mount the
      // native preview while the scanner tab is visible so it doesn't bleed
      // onto other pages or hold the camera in the background. Full-screen
      // flows outside the shell (exercise practice) opt in via the override.
      if (ref.watch(bottomTabIndexProvider) != 0 &&
          !ref.watch(cameraMountOverrideProvider)) {
        return const SizedBox.shrink();
      }
      return const _NativeCameraPreview();
    }
    final controller = cameraAsync.asData?.value;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    final previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return CameraPreview(controller);
    }
    // previewSize is reported in the sensor's landscape orientation; swap the
    // axes so the portrait viewport is filled without distortion.
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: previewSize.height,
        height: previewSize.width,
        child: CameraPreview(controller),
      ),
    );
  }

  Widget _buildChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: context.isDarkMode
            ? AppTheme.darkNavy.withAlpha(200)
            : Colors.white.withAlpha(220),
        border: Border.all(color: context.borderColor, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          color: context.textMutedColor,
        ),
      ),
    );
  }


}

/// Hybrid-composition host for the native CameraX preview PlatformView. Hybrid
/// composition (vs the default virtual-display `AndroidView`) composites the
/// native TextureView correctly inside Flutter's layer tree — clipped and
/// z-ordered under the scanner overlay instead of drawing in its own window.
class _NativeCameraPreview extends StatelessWidget {
  const _NativeCameraPreview();

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: nativeCameraViewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: nativeCameraViewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }
}

/// Watches the high-rate (~12/s) landmark frames in isolation so only this
/// subtree rebuilds per frame, and the RepaintBoundary confines the raster
/// damage to the overlay layer. Without both, every frame re-rastered the
/// whole screen on the merged main thread (camera platform view) and starved
/// MediaPipe's GPU inference on low-end devices.
class _LandmarkOverlay extends ConsumerWidget {
  const _LandmarkOverlay({
    required this.isDetected,
    required this.accentColor,
    required this.mirror,
  });

  final bool isDetected;
  final Color accentColor;
  final bool mirror;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showSkeleton = ref.watch(
      settingsProvider.select((s) => s.showHandSkeleton),
    );
    if (!showSkeleton) {
      return const RepaintBoundary(child: SizedBox.shrink());
    }
    final frame = ref.watch(currentFrameProvider);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _LandmarkOverlayPainter(
          frame: frame,
          isDetected: isDetected,
          accentColor: accentColor,
          mirror: mirror,
        ),
      ),
    );
  }
}

class _LandmarkOverlayPainter extends CustomPainter {
  final RawLandmarkFrame? frame;
  final bool isDetected;
  final Color accentColor;
  final bool mirror;

  _LandmarkOverlayPainter({
    required this.frame,
    required this.isDetected,
    required this.accentColor,
    this.mirror = false,
  });

  // Skeleton edges over the 21 MediaPipe hand landmarks.
  static const _handConnections = [
    [0, 1], [1, 2], [2, 3], [3, 4],
    [0, 5], [5, 6], [6, 7], [7, 8],
    [5, 9], [9, 10], [10, 11], [11, 12],
    [9, 13], [13, 14], [14, 15], [15, 16],
    [13, 17], [17, 18], [18, 19], [19, 20],
    [0, 17],
  ];

  // Upper-body edges over the 7 pose points, in the emitted order
  // [nose, Lshoulder, Rshoulder, Lelbow, Relbow, Lwrist, Rwrist].
  static const _poseConnections = [
    [1, 2], // shoulders
    [1, 3], [3, 5], // left arm
    [2, 4], [4, 6], // right arm
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null) return;

    final linePaint = Paint()
      ..color = (isDetected ? accentColor : const Color(0xFF6EA8EE)).withAlpha(216)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final circleFill = Paint()..color = Colors.white;
    final circleStroke = Paint()
      ..color = isDetected ? accentColor : AppTheme.primaryAccent
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    // Landmarks are normalized 0..1 in the analysis image. PreviewView
    // cover-fits (FILL_CENTER) that image into the viewport — it scales to
    // fill and center-crops the overflow — so the overlay must apply the same
    // transform or points away from the center drift (the pose skeleton spans
    // the whole body and visibly misaligned; hands sit near the center where
    // the error is small). Falls back to a plain stretch when the source
    // doesn't report image dimensions (simulated feed). On the mirrored
    // (front) preview, flip x so the skeleton lines up with the body.
    final iw = f.imageWidth;
    final ih = f.imageHeight;
    double displayW = size.width;
    double displayH = size.height;
    double offsetX = 0.0;
    double offsetY = 0.0;
    if (iw != null && ih != null) {
      final scale = math.max(size.width / iw, size.height / ih);
      displayW = iw * scale;
      displayH = ih * scale;
      offsetX = (size.width - displayW) / 2.0;
      offsetY = (size.height - displayH) / 2.0;
    }
    Offset toOffset(LandmarkPoint pt) => Offset(
          (mirror ? 1.0 - pt.x : pt.x) * displayW + offsetX,
          pt.y * displayH + offsetY,
        );

    void drawSkeleton(
      List<LandmarkPoint> pts,
      List<List<int>> connections, {
      double nodeRadius = 3.6,
    }) {
      if (pts.isEmpty) return;
      for (final conn in connections) {
        if (conn[0] < pts.length && conn[1] < pts.length) {
          canvas.drawLine(toOffset(pts[conn[0]]), toOffset(pts[conn[1]]), linePaint);
        }
      }
      for (final pt in pts) {
        final center = toOffset(pt);
        canvas.drawCircle(center, nodeRadius, circleFill);
        canvas.drawCircle(center, nodeRadius, circleStroke);
      }
    }

    // Upper-body pose first, so the hands render on top of it.
    final pose = f.upperPose;
    if (pose.length == 7) {
      // Neck line: nose down to the midpoint of the two shoulders.
      final mid = LandmarkPoint(
        (pose[1].x + pose[2].x) / 2,
        (pose[1].y + pose[2].y) / 2,
      );
      canvas.drawLine(toOffset(pose[0]), toOffset(mid), linePaint);
      drawSkeleton(pose, _poseConnections, nodeRadius: 4.0);
    }

    drawSkeleton(f.leftHand, _handConnections);
    drawSkeleton(f.rightHand, _handConnections);
  }

  @override
  bool shouldRepaint(covariant _LandmarkOverlayPainter oldDelegate) {
    return oldDelegate.frame != frame ||
        oldDelegate.isDetected != isDetected ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.mirror != mirror;
  }
}
