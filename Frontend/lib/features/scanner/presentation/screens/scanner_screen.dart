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

class _ScannerScreenState extends ConsumerState<ScannerScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scannerProvider);
    final notifier = ref.read(scannerProvider.notifier);

    final isDetecting = state.isScanning && state.demoPhase == 0;
    final liveLabel = state.isScanning
        ? (isDetecting ? 'กำลังตรวจจับ…' : 'ตรวจพบท่าทาง')
        : 'หยุดชั่วคราว';
    final dotColor = state.isScanning
        ? AppTheme.liveDotGreen
        : AppTheme.textMutedDark;

    return Scaffold(
      backgroundColor: AppTheme.darkNavy,
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
                        child: const Text(
                          'มือ',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'SignMind AI',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                              color: AppTheme.textLight,
                            ),
                          ),
                          Text(
                            'สแกนและแปลภาษามือไทย',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textMutedDark.withAlpha(220),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  // Live status chip
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryAccent.withAlpha(46),
                      border: Border.all(
                        color: AppTheme.textMutedDark.withAlpha(89),
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: _blinkController,
                          builder: (context, _) {
                            final opacity = state.isScanning
                                ? (0.3 + (_blinkController.value * 0.7))
                                : 1.0;
                            return Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: dotColor.withAlpha((opacity.clamp(0.0, 1.0) * 255).round()),
                                shape: BoxShape.circle,
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 6),
                        Text(
                          liveLabel,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFCFE1F8),
                          ),
                        ),
                      ],
                    ),
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
                onAiConversation: () => context.go('/conversation'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
