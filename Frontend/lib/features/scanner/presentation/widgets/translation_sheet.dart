import 'package:flutter/material.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

class TranslationSheet extends StatelessWidget {
  const TranslationSheet({
    super.key,
    required this.state,
    required this.onClearSentence,
    required this.onSpeak,
    required this.onAiConversation,
  });

  final ScannerState state;
  final VoidCallback onClearSentence;
  final VoidCallback onSpeak;
  final VoidCallback onAiConversation;

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
        color: AppTheme.lightSurface,
        borderRadius: BorderRadius.circular(20),
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
                const Text(
                  'ผลการแปล',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textMutedLight,
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
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w700,
                height: 1.15,
                color: AppTheme.textDark,
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
                      color: AppTheme.borderLight,
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
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppTheme.textMutedLight,
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
                color: Colors.white,
                border: Border.all(color: AppTheme.borderLight, width: 1),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.centerLeft,
              child: state.sentence.isNotEmpty
                  ? Text(
                      state.sentence.join(' '),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF22456E),
                        height: 1.4,
                      ),
                    )
                  : const Text(
                      'คำที่แปลได้จะเรียงเป็นประโยคที่นี่',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF9DB2CD),
                      ),
                    ),
            ),
            const SizedBox(height: 14),

            // Action buttons
            Row(
              children: [
                Expanded(
                  flex: 14,
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
                const SizedBox(width: 10),
                Expanded(
                  flex: 10,
                  child: OutlinedButton(
                    onPressed: onAiConversation,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primaryAccent,
                      side: const BorderSide(
                        color: AppTheme.primaryAccent,
                        width: 1.5,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'โหมดสนทนา AI',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
