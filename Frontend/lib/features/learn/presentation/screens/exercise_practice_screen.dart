import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/learn/presentation/providers/learn_provider.dart';
import 'package:signmind/features/scanner/presentation/providers/scanner_provider.dart';
import 'package:signmind/features/scanner/presentation/widgets/camera_viewport.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

/// Route arguments for `/learn/practice`.
class PracticeArgs {
  const PracticeArgs({required this.exercise, required this.topicTitle});

  final LearnExercise exercise;
  final String topicTitle;
}

/// Full-screen perform-the-sign exercise: reuses the scanner camera +
/// landmark pipeline and passes when the model predicts the target word at
/// or above the exercise's confidence threshold (admin-editable).
class ExercisePracticeScreen extends ConsumerStatefulWidget {
  const ExercisePracticeScreen({
    super.key,
    required this.exercise,
    required this.topicTitle,
  });

  final LearnExercise exercise;
  final String topicTitle;

  @override
  ConsumerState<ExercisePracticeScreen> createState() =>
      _ExercisePracticeScreenState();
}

class _ExercisePracticeScreenState
    extends ConsumerState<ExercisePracticeScreen> {
  bool _passed = false;
  double _bestConfidence = 0.0;
  bool _recording = false;
  int _demoDetectedFrames = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The native camera preview is normally mounted only on the scanner
      // tab; this screen lives outside that tab, so request the mount
      // explicitly (released again in dispose).
      ref.read(cameraMountOverrideProvider.notifier).set(true);
      if (!ref.read(scannerProvider).isScanning) {
        ref.read(scannerProvider.notifier).toggleScan();
      }
    });
  }

  @override
  void dispose() {
    // Releasing the mount after this frame lets the tree tear down first.
    final override = ref.read(cameraMountOverrideProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      override.set(false);
    });
    super.dispose();
  }

  Future<void> _onFrame() async {
    if (_passed || _recording) return;
    final state = ref.read(scannerProvider);
    final exercise = widget.exercise;

    double? attemptConfidence;
    final isDetected = state.demoPhase != 0 && state.currentWord != '…';
    if (isDetected && state.currentWord == exercise.word) {
      attemptConfidence = state.confidence;
    } else if (isDetected &&
        ref.read(settingsProvider).useSimulatedStream) {
      // Demo mode: the simulated stream loops fixed demo words that never
      // match real exercise vocabulary, so accept a few detected frames as
      // a successful attempt to keep the offline demo flow completable.
      _demoDetectedFrames++;
      if (_demoDetectedFrames >= 3) {
        attemptConfidence = exercise.passConfidence + 0.1;
      }
    }
    if (attemptConfidence == null ||
        attemptConfidence <= _bestConfidence) {
      return;
    }

    _recording = true;
    try {
      final row = await ref
          .read(learnProgressProvider.notifier)
          .recordAttempt(exercise.id, attemptConfidence.clamp(0.0, 1.0));
      if (!mounted) return;
      setState(() {
        _bestConfidence = row.bestConfidence;
        _passed = row.passed;
      });
    } catch (_) {
      // Offline/server error: keep practicing; the pass banner simply
      // won't show until an attempt is stored.
    } finally {
      _recording = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(scannerProvider, (_, _) => _onFrame());
    final state = ref.watch(scannerProvider);
    final exercise = widget.exercise;
    final thresholdPercent = (exercise.passConfidence * 100).round();
    final isMatch =
        state.currentWord == exercise.word && state.demoPhase != 0;

    return Scaffold(
      backgroundColor: context.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.scaffoldBackgroundColor,
        foregroundColor: context.textColor,
        elevation: 0,
        title: Text(
          widget.topicTitle,
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Target word banner.
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.borderColor, width: 1),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ทำท่าภาษามือคำว่า',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textMutedColor.withAlpha(220),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          exercise.word,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: context.textColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryAccent.withAlpha(36),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'เกณฑ์ผ่าน ≥ $thresholdPercent%',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Scanner camera + skeleton overlay (shared with the Scan tab).
            CameraViewport(
              state: state,
              onToggleScan: () =>
                  ref.read(scannerProvider.notifier).toggleScan(),
            ),

            const SizedBox(height: 12),

            // Live feedback / result.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _passed
                    ? _PassedCard(
                        word: exercise.word,
                        confidence: _bestConfidence,
                        onDone: () => context.pop(),
                      )
                    : _LiveFeedback(
                        isMatch: isMatch,
                        currentWord: state.currentWord,
                        confidence: state.confidence,
                        threshold: exercise.passConfidence,
                        bestConfidence: _bestConfidence,
                        isScanning: state.isScanning,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveFeedback extends StatelessWidget {
  const _LiveFeedback({
    required this.isMatch,
    required this.currentWord,
    required this.confidence,
    required this.threshold,
    required this.bestConfidence,
    required this.isScanning,
  });

  final bool isMatch;
  final String currentWord;
  final double confidence;
  final double threshold;
  final double bestConfidence;
  final bool isScanning;

  @override
  Widget build(BuildContext context) {
    final statusColor =
        isMatch ? AppTheme.successGreen : context.textMutedColor;
    final statusText = !isScanning
        ? 'กล้องหยุดชั่วคราว — แตะปุ่มบนกล้องเพื่อสแกนต่อ'
        : isMatch
            ? 'ตรวจพบ "$currentWord" (${(confidence * 100).round()}%)'
            : currentWord == '…'
                ? 'กำลังตรวจจับท่าทาง…'
                : 'ตรวจพบ "$currentWord" — ลองทำท่าอีกครั้ง';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            statusText,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: statusColor,
            ),
          ),
          const SizedBox(height: 14),
          // Best confidence vs threshold.
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (bestConfidence / threshold).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: context.borderColor,
              valueColor: AlwaysStoppedAnimation<Color>(
                bestConfidence >= threshold
                    ? AppTheme.successGreen
                    : AppTheme.primaryAccent,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'ดีที่สุด ${(bestConfidence * 100).round()}% / เกณฑ์ ${(threshold * 100).round()}%',
            style: TextStyle(
              fontSize: 12,
              color: context.textMutedColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _PassedCard extends StatelessWidget {
  const _PassedCard({
    required this.word,
    required this.confidence,
    required this.onDone,
  });

  final String word;
  final double confidence;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.successGreen.withAlpha(30),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: AppTheme.successGreen.withAlpha(140), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle,
              size: 44, color: AppTheme.successGreen),
          const SizedBox(height: 10),
          Text(
            'ผ่านแล้ว! "$word" ${(confidence * 100).round()}%',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.textColor,
            ),
          ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: onDone,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.successGreen,
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text('กลับสู่แผนที่บทเรียน'),
            ),
          ),
        ],
      ),
    );
  }
}
