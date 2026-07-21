import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/scanner/presentation/providers/scanner_provider.dart';
import 'package:signmind/features/scanner/presentation/widgets/camera_viewport.dart';
import 'package:signmind/features/scanner/presentation/widgets/translation_sheet.dart';

class ScannerScreen extends ConsumerWidget {
  const ScannerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scannerProvider);
    final notifier = ref.read(scannerProvider.notifier);

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
