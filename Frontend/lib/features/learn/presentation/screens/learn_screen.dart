import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/learn/presentation/providers/learn_provider.dart';
import 'package:signmind/features/learn/presentation/screens/exercise_practice_screen.dart';
import 'package:signmind/features/learn/presentation/widgets/sign_avatar.dart';

/// Learn tab: a Duolingo-style exercise roadmap (topics of
/// perform-the-sign exercises) and the TSL dictionary.
class LearnScreen extends ConsumerStatefulWidget {
  const LearnScreen({super.key});

  @override
  ConsumerState<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends ConsumerState<LearnScreen> {
  int _mode = 0; // 0 = roadmap, 1 = dictionary

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkNavy,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'เรียนรู้ภาษามือ',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textLight,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'ฝึกท่าทางตามแบบฝึกหัด หรือค้นหาคำศัพท์จากคลัง',
                style: TextStyle(
                  fontSize: 14,
                  color: AppTheme.textMutedDark.withAlpha(220),
                ),
              ),
              const SizedBox(height: 16),
              _ModeToggle(
                mode: _mode,
                onChanged: (m) => setState(() => _mode = m),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _mode == 0
                    ? const _RoadmapView()
                    : const _DictionaryView(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});

  final int mode;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget buildSegment(String label, int value) {
      final selected = mode == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? AppTheme.primaryAccent : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? Colors.white : AppTheme.textMutedDark,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderDark, width: 1),
      ),
      child: Row(
        children: [
          buildSegment('แบบฝึกหัด', 0),
          buildSegment('คลังคำศัพท์', 1),
        ],
      ),
    );
  }
}

// ---- roadmap ----

class _RoadmapView extends ConsumerWidget {
  const _RoadmapView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topicsAsync = ref.watch(learnTopicsProvider);
    final progress =
        ref.watch(learnProgressProvider).value ?? const <int, LearnProgress>{};

    return topicsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: AppTheme.primaryAccent),
      ),
      error: (err, _) => _ErrorRetry(
        message: 'โหลดแบบฝึกหัดไม่สำเร็จ',
        onRetry: () => ref.invalidate(learnTopicsProvider),
      ),
      data: (topics) {
        if (topics.isEmpty) {
          return const Center(
            child: Text(
              'ยังไม่มีแบบฝึกหัด',
              style: TextStyle(color: AppTheme.textMutedDark),
            ),
          );
        }
        // Topic N unlocks once every exercise of topic N-1 is passed.
        var previousCompleted = true;
        final nodes = <Widget>[];
        for (var i = 0; i < topics.length; i++) {
          final topic = topics[i];
          final unlocked = i == 0 || previousCompleted;
          final passedCount = topic.exercises
              .where((e) => progress[e.id]?.passed ?? false)
              .length;
          previousCompleted =
              topic.exercises.isNotEmpty &&
              passedCount == topic.exercises.length;
          nodes.add(
            _TopicNode(
              topic: topic,
              unlocked: unlocked,
              passedCount: passedCount,
              progress: progress,
              isLast: i == topics.length - 1,
            ),
          );
        }
        return RefreshIndicator(
          color: AppTheme.primaryAccent,
          backgroundColor: AppTheme.cardDark,
          onRefresh: () async {
            ref.invalidate(learnTopicsProvider);
            ref.invalidate(learnProgressProvider);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 20),
            children: nodes,
          ),
        );
      },
    );
  }
}

class _TopicNode extends ConsumerWidget {
  const _TopicNode({
    required this.topic,
    required this.unlocked,
    required this.passedCount,
    required this.progress,
    required this.isLast,
  });

  final LearnTopic topic;
  final bool unlocked;
  final int passedCount;
  final Map<int, LearnProgress> progress;
  final bool isLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = topic.exercises.length;
    final completed = total > 0 && passedCount == total;
    final accent = completed
        ? AppTheme.successGreen
        : unlocked
        ? AppTheme.primaryAccent
        : AppTheme.borderDark;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Roadmap spine: node circle + connector line to the next topic.
          SizedBox(
            width: 56,
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent.withAlpha(unlocked ? 60 : 30),
                    shape: BoxShape.circle,
                    border: Border.all(color: accent, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: unlocked
                      ? Text(
                          topic.icon.isEmpty ? '✋' : topic.icon,
                          style: const TextStyle(fontSize: 20),
                        )
                      : const Icon(
                          Icons.lock_outline,
                          size: 20,
                          color: AppTheme.textMutedDark,
                        ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: AppTheme.borderDark,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.cardDark,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: unlocked ? accent.withAlpha(120) : AppTheme.borderDark,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          topic.title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: unlocked
                                ? AppTheme.textLight
                                : AppTheme.textMutedDark,
                          ),
                        ),
                      ),
                      Text(
                        '$passedCount/$total',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: completed
                              ? AppTheme.successGreen
                              : AppTheme.textMutedDark,
                        ),
                      ),
                    ],
                  ),
                  if (unlocked && topic.exercises.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final exercise in topic.exercises)
                          _ExerciseChip(
                            exercise: exercise,
                            passed: progress[exercise.id]?.passed ?? false,
                            onTap: () => context.push(
                              '/learn/practice',
                              extra: PracticeArgs(
                                exercise: exercise,
                                topicTitle: topic.title,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (!unlocked) ...[
                    const SizedBox(height: 6),
                    Text(
                      'ผ่านหัวข้อก่อนหน้าเพื่อปลดล็อก',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textMutedDark.withAlpha(180),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExerciseChip extends StatelessWidget {
  const _ExerciseChip({
    required this.exercise,
    required this.passed,
    required this.onTap,
  });

  final LearnExercise exercise;
  final bool passed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = passed ? AppTheme.successGreen : AppTheme.primaryAccent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withAlpha(36),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(140), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              passed ? Icons.check_circle : Icons.sign_language_outlined,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              exercise.word,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppTheme.textLight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- dictionary ----

class _DictionaryView extends ConsumerStatefulWidget {
  const _DictionaryView();

  @override
  ConsumerState<_DictionaryView> createState() => _DictionaryViewState();
}

class _DictionaryViewState extends ConsumerState<_DictionaryView> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final signsAsync = ref.watch(dictionaryProvider);

    return Column(
      children: [
        TextField(
          onChanged: (v) => setState(() => _query = v.trim()),
          style: const TextStyle(color: AppTheme.textLight),
          decoration: InputDecoration(
            hintText: 'ค้นหาคำศัพท์…',
            hintStyle: const TextStyle(color: AppTheme.textMutedDark),
            prefixIcon: const Icon(Icons.search, color: AppTheme.textMutedDark),
            filled: true,
            fillColor: AppTheme.cardDark,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.borderDark),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.borderDark),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: signsAsync.when(
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryAccent),
            ),
            error: (err, _) => _ErrorRetry(
              message: 'โหลดคลังคำศัพท์ไม่สำเร็จ',
              onRetry: () => ref.invalidate(dictionaryProvider),
            ),
            data: (signs) {
              final filtered = _query.isEmpty
                  ? signs
                  : signs
                        .where(
                          (s) =>
                              s.word.contains(_query) ||
                              s.category.contains(_query),
                        )
                        .toList();
              if (filtered.isEmpty) {
                return const Center(
                  child: Text(
                    'ไม่พบคำศัพท์',
                    style: TextStyle(color: AppTheme.textMutedDark),
                  ),
                );
              }
              // Group by category, preserving the server's category order.
              final grouped = <String, List<DictionarySign>>{};
              for (final sign in filtered) {
                grouped.putIfAbsent(sign.category, () => []).add(sign);
              }
              return RefreshIndicator(
                color: AppTheme.primaryAccent,
                backgroundColor: AppTheme.cardDark,
                onRefresh: () async {
                  ref.invalidate(dictionaryProvider);
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 20),
                  children: [
                    for (final entry in grouped.entries) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 6),
                        child: Text(
                          entry.key.isEmpty ? 'อื่นๆ' : entry.key,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textMutedDark,
                          ),
                        ),
                      ),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                        color: AppTheme.cardDark,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppTheme.borderDark,
                          width: 1,
                        ),
                      ),
                      // ListTile paints ink on the nearest Material; without
                      // this transparent one it asserts under the decorated
                      // box above.
                      child: Material(
                        type: MaterialType.transparency,
                        child: Column(
                          children: [
                            for (final sign in entry.value)
                              ListTile(
                                dense: true,
                                title: Text(
                                  sign.word,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: AppTheme.textLight,
                                  ),
                                ),
                                trailing: Icon(
                                  sign.hasAnimation
                                      ? Icons.play_circle_outline
                                      : Icons.sign_language_outlined,
                                  size: 18,
                                  color: AppTheme.primaryAccent,
                                ),
                                onTap: () => _showSignSheet(context, sign),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
            },
          ),
        ),
      ],
    );
  }

  void _showSignSheet(BuildContext context, DictionarySign sign) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.cardDark,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                sign.word,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textLight,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                sign.category,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textMutedDark,
                ),
              ),
              const SizedBox(height: 12),
              _SignDetailAvatar(word: sign.word),
              const SizedBox(height: 8),
              Text(
                sign.hasAnimation
                    ? 'ท่าทางจากข้อมูลจริง'
                    : 'ภาพจำลองท่าทาง (ยังไม่มีข้อมูลท่าจริงสำหรับคำนี้)',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMutedDark.withAlpha(200),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Fetches the entry's keypoint frames and renders the avatar (procedural
/// fallback while loading or when the word has no animation data).
class _SignDetailAvatar extends ConsumerWidget {
  const _SignDetailAvatar({required this.word});

  final String word;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(signDetailProvider(word));
    return SignAvatar(word: word, frames: detail.value?.keypointFrames);
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: const TextStyle(color: AppTheme.textMutedDark)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: onRetry,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryAccent,
            ),
            child: const Text('ลองใหม่'),
          ),
        ],
      ),
    );
  }
}
