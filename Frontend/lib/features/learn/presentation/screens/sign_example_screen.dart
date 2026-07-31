import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/learn/presentation/providers/learn_provider.dart';
import 'package:signmind/features/learn/presentation/screens/exercise_practice_screen.dart';
import 'package:signmind/features/learn/presentation/widgets/sign_avatar.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

/// Route arguments for `/learn/example`. [index] is the position within
/// `topic.exercises` — a lesson runs the topic from here to the end.
class ExampleArgs {
  const ExampleArgs({required this.topic, required this.index});

  final LearnTopic topic;
  final int index;
}

/// Step 1 of an exercise: show the dictionary example (avatar animation) and
/// the admin-written note for the word, then hand off to the practice screen.
class SignExampleScreen extends ConsumerWidget {
  const SignExampleScreen({
    super.key,
    required this.topic,
    required this.index,
  });

  final LearnTopic topic;
  final int index;

  LearnExercise get exercise => topic.exercises[index];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(signDetailProvider(exercise.word));
    final cartoon = ref.watch(settingsProvider.select((s) => s.cartoonAvatar));
    final sign = detail.value;
    final thresholdPercent = (exercise.passConfidence * 100).round();

    return Scaffold(
      backgroundColor: context.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: context.scaffoldBackgroundColor,
        foregroundColor: context.textColor,
        elevation: 0,
        title: Text(topic.title, style: const TextStyle(fontSize: 16)),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                'คำที่ ${index + 1}/${topic.exercises.length}',
                style: TextStyle(fontSize: 13, color: context.textMutedColor),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                children: [
                  Text(
                    'ตัวอย่างท่าคำว่า',
                    style: TextStyle(
                      fontSize: 13,
                      color: context.textMutedColor.withAlpha(220),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    exercise.word,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: context.textColor,
                    ),
                  ),
                  if (sign != null && sign.category.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      sign.category,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.textMutedColor,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: context.cardColor,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: context.borderColor, width: 1),
                    ),
                    child: Column(
                      children: [
                        SignAvatar(
                          word: exercise.word,
                          frames: sign?.keypointFrames,
                          style: cartoon
                              ? SignAvatarStyle.cartoon
                              : SignAvatarStyle.skeleton,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          detail.isLoading
                              ? 'กำลังโหลดท่าทาง…'
                              : (sign?.hasAnimation ?? false)
                                  ? 'ท่าทางจากข้อมูลจริง'
                                  : 'ภาพจำลองท่าทาง (ยังไม่มีข้อมูลท่าจริงสำหรับคำนี้)',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textMutedColor.withAlpha(200),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _NoteCard(note: sign?.note ?? '', loading: detail.isLoading),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.flag_outlined,
                        size: 16,
                        color: context.textMutedColor,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'ขั้นต่อไปคือทำท่านี้ให้ AI มั่นใจอย่างน้อย $thresholdPercent%',
                          style: TextStyle(
                            fontSize: 13,
                            color: context.textMutedColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  // Replace, not push: after practice the learner should go
                  // back to the roadmap (or the summary), not to this example.
                  onPressed: () => context.pushReplacement(
                    '/learn/practice',
                    extra: PracticeArgs(topic: topic, index: index),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.sign_language_outlined, size: 20),
                  label: const Text(
                    'เริ่มฝึกทำท่า',
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

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.loading});

  final String note;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final hasNote = note.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasNote
              ? AppTheme.primaryAccent.withAlpha(110)
              : context.borderColor,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.sticky_note_2_outlined,
                size: 18,
                color: AppTheme.primaryAccent,
              ),
              const SizedBox(width: 8),
              Text(
                'คำอธิบายท่า',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.textColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            hasNote
                ? note
                : loading
                    ? 'กำลังโหลดคำอธิบาย…'
                    : 'ยังไม่มีคำอธิบายสำหรับคำนี้',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: hasNote
                  ? context.textColor
                  : context.textMutedColor.withAlpha(200),
            ),
          ),
        ],
      ),
    );
  }
}
