import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/learn/presentation/providers/learn_provider.dart';
import 'package:signmind/features/learn/presentation/screens/sign_example_screen.dart';
import 'package:signmind/features/learn/presentation/screens/topic_summary_screen.dart';
import 'package:signmind/features/scanner/presentation/providers/scanner_provider.dart';
import 'package:signmind/features/scanner/presentation/widgets/camera_viewport.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

/// Route arguments for `/learn/practice`. [index] is the position within
/// `topic.exercises`; passing it advances the lesson to the next word.
class PracticeArgs {
  const PracticeArgs({required this.topic, required this.index});

  final LearnTopic topic;
  final int index;
}

/// Step 2 of an exercise: reuses the scanner camera + landmark pipeline.
/// Each try is an explicit, bounded capture window so that "N correct out of
/// M attempts" counts something the learner deliberately did; the try passes
/// when the model predicts the target word at or above the exercise's
/// confidence threshold (admin-editable).
class ExercisePracticeScreen extends ConsumerStatefulWidget {
  const ExercisePracticeScreen({
    super.key,
    required this.topic,
    required this.index,
  });

  final LearnTopic topic;
  final int index;

  LearnExercise get exercise => topic.exercises[index];

  /// True when another word follows this one in the lesson.
  bool get hasNext => index + 1 < topic.exercises.length;

  @override
  ConsumerState<ExercisePracticeScreen> createState() =>
      _ExercisePracticeScreenState();
}

class _ExercisePracticeScreenState
    extends ConsumerState<ExercisePracticeScreen> {
  /// How long one try listens to the model before it is scored.
  static const _captureWindow = Duration(seconds: 3);

  bool _passed = false;
  double _bestConfidence = 0.0;
  bool _recording = false;
  int _demoDetectedFrames = 0;

  bool _capturing = false;
  Timer? _captureTimer;
  double _captureBest = 0.0;
  int _attempts = 0;
  int _correct = 0;
  bool? _lastAttemptPassed;

  @override
  void initState() {
    super.initState();
    // Seed the tally from stored progress so the on-screen count continues
    // where an earlier session left off rather than restarting at 0.
    final stored = ref.read(learnProgressProvider).value?[widget.exercise.id];
    if (stored != null) {
      _attempts = stored.attempts;
      _correct = stored.correctAttempts;
      _bestConfidence = stored.bestConfidence;
      _passed = stored.passed;
    }
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
    _captureTimer?.cancel();
    // Releasing the mount after this frame lets the tree tear down first.
    final override = ref.read(cameraMountOverrideProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      override.set(false);
    });
    super.dispose();
  }

  /// Opens a capture window. Everything the model reports inside it belongs
  /// to this one attempt; nothing outside it is scored.
  void _startAttempt() {
    if (_passed || _capturing || _recording) return;
    _captureTimer?.cancel();
    setState(() {
      _capturing = true;
      _captureBest = 0.0;
      _demoDetectedFrames = 0;
      _lastAttemptPassed = null;
    });
    _captureTimer = Timer(_captureWindow, _finishAttempt);
  }

  /// Keeps the best confidence seen for the target word inside the window.
  void _onFrame() {
    if (!_capturing) return;
    final state = ref.read(scannerProvider);
    final exercise = widget.exercise;

    final isDetected = state.demoPhase != 0 && state.currentWord != '…';
    if (isDetected && state.currentWord == exercise.word) {
      if (state.confidence > _captureBest) {
        _captureBest = state.confidence;
      }
    } else if (isDetected && ref.read(settingsProvider).useSimulatedStream) {
      // Demo mode: the simulated stream loops fixed demo words that never
      // match real exercise vocabulary, so accept a few detected frames as
      // a successful attempt to keep the offline demo flow completable.
      _demoDetectedFrames++;
      if (_demoDetectedFrames >= 3) {
        _captureBest = exercise.passConfidence + 0.1;
      }
    }
  }

  /// Scores the window and posts it. A window where the target word never
  /// appeared is still an attempt — it is posted at confidence 0 so the
  /// "correct out of attempts" tally counts the misses too.
  Future<void> _finishAttempt() async {
    if (!mounted) return;
    final exercise = widget.exercise;
    final confidence = _captureBest.clamp(0.0, 1.0);
    final correct = confidence >= exercise.passConfidence;
    setState(() {
      _capturing = false;
      _recording = true;
    });
    try {
      final row = await ref
          .read(learnProgressProvider.notifier)
          .recordAttempt(exercise.id, confidence);
      if (!mounted) return;
      setState(() {
        _bestConfidence = row.bestConfidence;
        _passed = row.passed;
        _attempts = row.attempts;
        _correct = row.correctAttempts;
        _lastAttemptPassed = correct;
      });
    } catch (_) {
      // Offline/server error: keep practicing. The pass banner still waits
      // for a stored attempt, but the local tally moves so the learner sees
      // the try was counted.
      if (!mounted) return;
      setState(() {
        _attempts += 1;
        if (correct) _correct += 1;
        if (confidence > _bestConfidence) _bestConfidence = confidence;
        _lastAttemptPassed = correct;
      });
    } finally {
      if (mounted) setState(() => _recording = false);
    }
  }

  /// Continues the lesson: the next word's example step, or the end-of-topic
  /// summary once the last word is passed. Replaces rather than pushes, so
  /// backing out of a lesson never walks through every word already done.
  void _advance() {
    if (widget.hasNext) {
      context.pushReplacement(
        '/learn/example',
        extra: ExampleArgs(topic: widget.topic, index: widget.index + 1),
      );
      return;
    }
    context.pushReplacement(
      '/learn/summary',
      extra: TopicSummaryArgs(topic: widget.topic),
    );
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
          widget.topic.title,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                'คำที่ ${widget.index + 1}/${widget.topic.exercises.length}',
                style: TextStyle(fontSize: 13, color: context.textMutedColor),
              ),
            ),
          ),
        ],
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _passed
                    ? _PassedCard(
                        word: exercise.word,
                        confidence: _bestConfidence,
                        attempts: _attempts,
                        correct: _correct,
                        hasNext: widget.hasNext,
                        onDone: _advance,
                      )
                    : Column(
                        children: [
                          _LiveFeedback(
                            isMatch: isMatch,
                            currentWord: state.currentWord,
                            confidence: state.confidence,
                            threshold: exercise.passConfidence,
                            bestConfidence: _bestConfidence,
                            isScanning: state.isScanning,
                            capturing: _capturing,
                            recording: _recording,
                            lastAttemptPassed: _lastAttemptPassed,
                            attempts: _attempts,
                            correct: _correct,
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _capturing || _recording
                                  ? null
                                  : _startAttempt,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryAccent,
                                foregroundColor: Colors.white,
                                disabledBackgroundColor:
                                    AppTheme.primaryAccent.withAlpha(90),
                                disabledForegroundColor:
                                    Colors.white.withAlpha(160),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: Icon(
                                _capturing
                                    ? Icons.fiber_manual_record
                                    : Icons.play_arrow_rounded,
                                size: 20,
                              ),
                              label: Text(
                                _capturing
                                    ? 'กำลังจับท่า…'
                                    : _recording
                                        ? 'กำลังบันทึกผล…'
                                        : _attempts == 0
                                            ? 'เริ่มลองทำท่า'
                                            : 'ลองอีกครั้ง',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
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
    required this.capturing,
    required this.recording,
    required this.lastAttemptPassed,
    required this.attempts,
    required this.correct,
  });

  final bool isMatch;
  final String currentWord;
  final double confidence;
  final double threshold;
  final double bestConfidence;
  final bool isScanning;
  final bool capturing;
  final bool recording;

  /// Result of the try that just finished; null before the first one.
  final bool? lastAttemptPassed;
  final int attempts;
  final int correct;

  @override
  Widget build(BuildContext context) {
    final statusColor = capturing
        ? (isMatch ? AppTheme.successGreen : AppTheme.primaryAccent)
        : lastAttemptPassed == null
            ? context.textMutedColor
            : lastAttemptPassed!
                ? AppTheme.successGreen
                : context.textMutedColor;
    final String statusText;
    if (!isScanning) {
      statusText = 'กล้องหยุดชั่วคราว — แตะปุ่มบนกล้องเพื่อสแกนต่อ';
    } else if (capturing) {
      statusText = isMatch
          ? 'กำลังจับท่า — ตรวจพบ "$currentWord" (${(confidence * 100).round()}%)'
          : 'กำลังจับท่า — ทำท่าค้างไว้จนกว่าจะครบเวลา';
    } else if (recording) {
      statusText = 'กำลังบันทึกผลการลอง…';
    } else if (lastAttemptPassed == null) {
      statusText = 'กดปุ่มด้านล่างเมื่อพร้อม แล้วทำท่าภายใน '
          '${_ExercisePracticeScreenState._captureWindow.inSeconds} วินาที';
    } else if (lastAttemptPassed!) {
      statusText = 'ครั้งล่าสุด: ถูกต้อง 🎉';
    } else {
      statusText = 'ครั้งล่าสุด: ยังไม่ถึงเกณฑ์ — ลองใหม่อีกครั้ง';
    }

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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ดีที่สุด ${(bestConfidence * 100).round()}% / เกณฑ์ ${(threshold * 100).round()}%',
                style: TextStyle(
                  fontSize: 12,
                  color: context.textMutedColor,
                ),
              ),
              Text(
                'ถูก $correct/$attempts ครั้ง',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textMutedColor,
                ),
              ),
            ],
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
    required this.attempts,
    required this.correct,
    required this.hasNext,
    required this.onDone,
  });

  final String word;
  final double confidence;
  final int attempts;
  final int correct;
  final bool hasNext;
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
          const SizedBox(height: 6),
          Text(
            'คำนี้ทำถูก $correct ครั้ง จาก $attempts ครั้งที่ลอง',
            style: TextStyle(fontSize: 13, color: context.textMutedColor),
          ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: onDone,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.successGreen,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text(hasNext ? 'คำต่อไป' : 'ดูสรุปผลของหัวข้อนี้'),
            ),
          ),
        ],
      ),
    );
  }
}
