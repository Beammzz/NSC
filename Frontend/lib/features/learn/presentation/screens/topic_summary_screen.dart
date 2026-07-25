import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/learn/presentation/providers/learn_provider.dart';

/// Route arguments for `/learn/summary`.
class TopicSummaryArgs {
  const TopicSummaryArgs({required this.topic});

  final LearnTopic topic;
}

/// Step 3: shown once every exercise in a topic is passed. Reports how many
/// of the learner's tries were correct — the attempt counters come from the
/// server (`learn_attempts`), so they survive app restarts.
class TopicSummaryScreen extends ConsumerWidget {
  const TopicSummaryScreen({super.key, required this.topic});

  final LearnTopic topic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress =
        ref.watch(learnProgressProvider).value ?? const <int, LearnProgress>{};

    var attempts = 0;
    var correct = 0;
    for (final exercise in topic.exercises) {
      final row = progress[exercise.id];
      if (row == null) continue;
      attempts += row.attempts;
      correct += row.correctAttempts;
    }
    // Accuracy is undefined with no logged attempts (e.g. progress restored
    // from an older build); show a dash rather than a misleading 0%.
    final accuracy = attempts == 0 ? null : correct / attempts;

    return Scaffold(
      backgroundColor: context.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
                children: [
                  const Icon(
                    Icons.emoji_events,
                    size: 56,
                    color: AppTheme.successGreen,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'จบหัวข้อ "${topic.title}"',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: context.textColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'ผ่านครบทั้ง ${topic.exercises.length} คำแล้ว',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: context.textMutedColor,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: context.cardColor,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: AppTheme.successGreen.withAlpha(110),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'ทำถูก $correct ครั้ง จากทั้งหมด $attempts ครั้ง',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: context.textColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: accuracy ?? 0.0,
                            minHeight: 8,
                            backgroundColor: context.borderColor,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppTheme.successGreen,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          accuracy == null
                              ? 'ความแม่นยำ —'
                              : 'ความแม่นยำ ${(accuracy * 100).round()}%',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.textMutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'รายคำ',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.textMutedColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: context.cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: context.borderColor, width: 1),
                    ),
                    child: Column(
                      children: [
                        for (final exercise in topic.exercises)
                          _ExerciseRow(
                            word: exercise.word,
                            row: progress[exercise.id],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => context.go('/learn'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.successGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'กลับสู่แผนที่บทเรียน',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({required this.word, required this.row});

  final String word;
  final LearnProgress? row;

  @override
  Widget build(BuildContext context) {
    final attempts = row?.attempts ?? 0;
    final correct = row?.correctAttempts ?? 0;
    return ListTile(
      dense: true,
      leading: const Icon(
        Icons.check_circle,
        size: 18,
        color: AppTheme.successGreen,
      ),
      title: Text(
        word,
        style: TextStyle(fontSize: 15, color: context.textColor),
      ),
      trailing: Text(
        '$correct/$attempts',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.textMutedColor,
        ),
      ),
    );
  }
}
