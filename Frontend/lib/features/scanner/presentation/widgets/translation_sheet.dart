import 'package:flutter/material.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

class TranslationSheet extends StatelessWidget {
  const TranslationSheet({
    super.key,
    required this.state,
    required this.onClearSentence,
    required this.onSpeak,
  });

  final ScannerState state;
  final VoidCallback onClearSentence;
  final VoidCallback onSpeak;

  @override
  Widget build(BuildContext context) {
    final isDetected = state.isScanning && state.demoPhase != 0;
    final confPercent = (state.confidence * 100).round();
    final okColor = state.confidence >= 0.85
        ? AppTheme.successGreen
        : AppTheme.warningOrange;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: context.isDarkMode ? AppTheme.cardDark : AppTheme.lightSurface,
        borderRadius: BorderRadius.circular(20),
        border: context.isDarkMode
            ? Border.all(color: context.borderColor, width: 1)
            : null,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'ผลการแปล',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: context.textMutedColor,
                    letterSpacing: 0.2,
                  ),
                ),
                GestureDetector(
                  onTap: onClearSentence,
                  child: const Text(
                    'ล้างข้อความ',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),

            // Current detected word
            Text(
              isDetected ? state.currentWord : (state.isScanning ? '…' : ''),
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                height: 1.15,
                color: context.textColor,
              ),
            ),
            const SizedBox(height: 4),

            // Confidence progress bar
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: context.borderColor,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    alignment: Alignment.centerLeft,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOut,
                      width: isDetected
                          ? (MediaQuery.of(context).size.width - 100) *
                              state.confidence
                          : 0,
                      decoration: BoxDecoration(
                        color: okColor,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 44,
                  child: Text(
                    isDetected ? '$confPercent%' : '—',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: context.textMutedColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Assembled sentence box
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color:
                    context.isDarkMode ? AppTheme.cardDarkAlt : Colors.white,
                border: Border.all(color: context.borderColor, width: 1),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.centerLeft,
              child: state.sentence.isNotEmpty
                  ? Text(
                      state.sentence.join(' '),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: context.isDarkMode
                            ? AppTheme.textLight
                            : const Color(0xFF22456E),
                        height: 1.4,
                      ),
                    )
                  : Text(
                      'คำที่แปลได้จะเรียงเป็นประโยคที่นี่',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w400,
                        color: context.textMutedColor.withAlpha(200),
                      ),
                    ),
            ),
            const SizedBox(height: 14),

            // Action buttons
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onSpeak,
                style: ElevatedButton.styleFrom(
                  backgroundColor: state.isSpeaking
                      ? AppTheme.primaryAccentHover
                      : AppTheme.primaryAccent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: Icon(
                  state.isSpeaking ? Icons.circle : Icons.volume_up,
                  size: 18,
                ),
                label: Text(
                  state.isSpeaking ? 'กำลังพูด…' : 'อ่านออกเสียง',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
