import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/scanner/presentation/providers/scanner_provider.dart';
import 'package:signmind/features/scanner/presentation/widgets/camera_viewport.dart';
import 'package:signmind/features/scanner/presentation/widgets/translation_sheet.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  // The live dot blinks via a coarse periodic toggle, NOT an
  // AnimationController: with the hybrid-composition camera PlatformView on
  // screen, Flutter rasters on the merged main thread, so a repeating vsync
  // animation re-rasters the whole scene at 60Hz and starves MediaPipe's GPU
  // inference (measured: the dot alone dragged the landmark pipeline from
  // ~12fps to ~7fps on a Redmi Note 12 5G).
  Timer? _blinkTimer;
  bool _blinkOn = true;

  @override
  void dispose() {
    _blinkTimer?.cancel();
    super.dispose();
  }

  /// Keeps the blink ticking only while scanning. Called from build, so it
  /// only starts/cancels the timer; repaints happen on later ticks.
  void _syncBlinkTimer(bool scanning) {
    if (scanning && _blinkTimer == null) {
      _blinkTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
        setState(() => _blinkOn = !_blinkOn);
      });
    } else if (!scanning && _blinkTimer != null) {
      _blinkTimer!.cancel();
      _blinkTimer = null;
      _blinkOn = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scannerProvider);
    final notifier = ref.read(scannerProvider.notifier);
    _syncBlinkTimer(state.isScanning);

    final isDetecting = state.isScanning && state.demoPhase == 0;
    final liveLabel = state.isScanning
        ? (isDetecting ? 'กำลังตรวจจับ…' : 'ตรวจพบท่าทาง')
        : 'หยุดชั่วคราว';
    final dotColor = state.isScanning
        ? AppTheme.liveDotGreen
        : context.textMutedColor;

    return Scaffold(
      backgroundColor: context.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Top Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryAccent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Image.asset(
                              'assets/icons/app_icon.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SignMind AI',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                              color: context.textColor,
                            ),
                          ),
                          Text(
                            'สแกนและแปลภาษามือไทย',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.textMutedColor.withAlpha(220),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  // Top Right Actions
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: const Key('openLandingButton'),
                        tooltip: 'ศูนย์แนะนำฟีเจอร์ระบบ',
                        onPressed: () => context.go('/landing'),
                        icon: Icon(
                          Icons.info_outline,
                          color: context.textMutedColor,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Live status chip
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryAccent.withAlpha(46),
                          border: Border.all(
                            color: context.textMutedColor.withAlpha(89),
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                // Dim phase matches the old animation's 0.3
                                // opacity floor; solid when paused.
                                color: dotColor.withAlpha(_blinkOn ? 255 : 77),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              liveLabel,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: context.isDarkMode
                                    ? const Color(0xFFCFE1F8)
                                    : context.textColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Camera Viewport
            Flexible(
              flex: 5,
              child: CameraViewport(
                state: state,
                onToggleScan: notifier.toggleScan,
              ),
            ),

            // Translation Result Sheet
            Flexible(
              flex: 4,
              child: TranslationSheet(
                state: state,
                onClearSentence: notifier.clearSentence,
                onSpeak: notifier.speakSentence,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
