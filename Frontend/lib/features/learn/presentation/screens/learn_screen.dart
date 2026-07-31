import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/learn/presentation/providers/learn_provider.dart';
import 'package:signmind/features/learn/presentation/screens/sign_example_screen.dart';
import 'package:signmind/features/learn/presentation/widgets/sign_avatar.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

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
      backgroundColor: context.scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'เรียนรู้ภาษามือ',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: context.textColor,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'ดูตัวอย่างท่าแล้วฝึกทำตาม หรือค้นหาคำศัพท์จากคลัง',
                style: TextStyle(
                  fontSize: 14,
                  color: context.textMutedColor.withAlpha(220),
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
                color: selected ? Colors.white : context.textMutedColor,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.borderColor, width: 1),
      ),
      child: Row(
        children: [
          buildSegment('เรียนรู้', 0),
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
        message: 'โหลดบทเรียนไม่สำเร็จ',
        onRetry: () => ref.invalidate(learnTopicsProvider),
      ),
      data: (topics) {
        if (topics.isEmpty) {
          return Center(
            child: Text(
              'ยังไม่มีบทเรียน',
              style: TextStyle(color: context.textMutedColor),
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
            _LessonNode(
              topic: topic,
              unlocked: unlocked,
              passedCount: passedCount,
              // Duolingo-style meander: the path drifts left and right down
              // the screen instead of running in a straight column.
              offsetX: _pathOffsets[i % _pathOffsets.length],
            ),
          );
        }
        return RefreshIndicator(
          color: AppTheme.primaryAccent,
          backgroundColor: context.cardColor,
          onRefresh: () async {
            ref.invalidate(learnTopicsProvider);
            ref.invalidate(learnProgressProvider);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: nodes,
          ),
        );
      },
    );
  }
}

/// Horizontal drift applied to successive lesson nodes, in logical pixels.
const _pathOffsets = <double>[0, 46, 66, 46, 0, -46, -66, -46];

/// One lesson on the roadmap path: an icon with a progress ring around it.
/// The topic name and its words are deliberately NOT drawn here — pressing
/// the icon opens [_LessonSheet], which is where the lesson gets named and
/// started.
class _LessonNode extends StatelessWidget {
  const _LessonNode({
    required this.topic,
    required this.unlocked,
    required this.passedCount,
    required this.offsetX,
  });

  final LearnTopic topic;
  final bool unlocked;
  final int passedCount;
  final double offsetX;

  @override
  Widget build(BuildContext context) {
    final total = topic.exercises.length;
    final completed = total > 0 && passedCount == total;
    final accent = completed
        ? AppTheme.successGreen
        : unlocked
        ? AppTheme.primaryAccent
        : context.borderColor;
    // A topic with no exercises yet is legitimate — do not divide by it.
    final ratio = total == 0 ? 0.0 : passedCount / total;

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Transform.translate(
        offset: Offset(offsetX, 0),
        child: Center(
          child: SizedBox(
            width: 88,
            height: 88,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 86,
                  height: 86,
                  child: CircularProgressIndicator(
                    value: ratio,
                    strokeWidth: 5,
                    backgroundColor: context.borderColor,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
                // The whole disc is the tap target — the emoji alone was not
                // hittable before.
                Material(
                  color: Colors.transparent,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _showLessonSheet(
                      context,
                      topic: topic,
                      unlocked: unlocked,
                      passedCount: passedCount,
                    ),
                    child: Semantics(
                      button: true,
                      label: topic.title,
                      child: Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          color: accent.withAlpha(unlocked ? 60 : 26),
                          shape: BoxShape.circle,
                          border: Border.all(color: accent, width: 2),
                        ),
                        alignment: Alignment.center,
                        child: unlocked
                            ? Text(
                                topic.icon.isEmpty ? '✋' : topic.icon,
                                style: const TextStyle(fontSize: 28),
                              )
                            : Icon(
                                Icons.lock_outline,
                                size: 26,
                                color: context.textMutedColor,
                              ),
                      ),
                    ),
                  ),
                ),
                if (completed)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: context.scaffoldBackgroundColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check_circle,
                        size: 20,
                        color: AppTheme.successGreen,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _showLessonSheet(
  BuildContext context, {
  required LearnTopic topic,
  required bool unlocked,
  required int passedCount,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => _LessonSheet(
      topic: topic,
      unlocked: unlocked,
      passedCount: passedCount,
      onStart: (startIndex) {
        Navigator.of(sheetContext).pop();
        context.push(
          '/learn/example',
          extra: ExampleArgs(topic: topic, index: startIndex),
        );
      },
    ),
  );
}

/// The lesson popup: names the topic, shows progress, and starts it. Starting
/// runs the whole topic — example, practice, then straight on to the next
/// word — so this is the only place a lesson is entered.
class _LessonSheet extends ConsumerStatefulWidget {
  const _LessonSheet({
    required this.topic,
    required this.unlocked,
    required this.passedCount,
    required this.onStart,
  });

  final LearnTopic topic;
  final bool unlocked;
  final int passedCount;
  final ValueChanged<int> onStart;

  @override
  ConsumerState<_LessonSheet> createState() => _LessonSheetState();
}

class _LessonSheetState extends ConsumerState<_LessonSheet> {
  bool _resetting = false;
  String? _error;

  /// "ฝึกทำใหม่": wipes this topic's progress, then restarts it from the first
  /// word. Without the wipe the practice screen would open every word already
  /// passed and skip straight to the summary.
  Future<void> _restartFromScratch() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.cardColor,
        title: Text(
          'ฝึกทำใหม่?',
          style: TextStyle(color: context.textColor),
        ),
        content: Text(
          'ความคืบหน้าของหัวข้อ "${widget.topic.title}" '
          'จะถูกล้างทั้งหมด แล้วเริ่มใหม่ตั้งแต่คำแรก',
          style: TextStyle(color: context.textMutedColor),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ยกเลิก'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'ล้างและเริ่มใหม่',
              style: TextStyle(color: AppTheme.warningOrange),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _resetting = true;
      _error = null;
    });
    try {
      await ref.read(learnProgressProvider.notifier).resetTopic(widget.topic);
      if (!mounted) return;
      widget.onStart(0);
    } catch (_) {
      // Offline/server error: do NOT start the lesson — the words would still
      // read as passed and the learner would be skipped through again.
      if (!mounted) return;
      setState(() {
        _resetting = false;
        _error = 'ล้างความคืบหน้าไม่สำเร็จ — ตรวจสอบการเชื่อมต่อแล้วลองใหม่';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final topic = widget.topic;
    final unlocked = widget.unlocked;
    final passedCount = widget.passedCount;
    final progress =
        ref.watch(learnProgressProvider).value ?? const <int, LearnProgress>{};
    final total = topic.exercises.length;
    final completed = total > 0 && passedCount == total;
    // Resume at the first word still unpassed; a finished topic starts over
    // from zero after its progress is cleared.
    final firstUnpassed = topic.exercises
        .indexWhere((e) => !(progress[e.id]?.passed ?? false));
    final startIndex = firstUnpassed < 0 ? 0 : firstUnpassed;

    final String buttonLabel;
    if (completed) {
      buttonLabel = 'ฝึกทำใหม่';
    } else if (passedCount > 0) {
      buttonLabel = 'เรียนต่อ';
    } else {
      buttonLabel = 'เริ่มเรียน';
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: (completed
                        ? AppTheme.successGreen
                        : unlocked
                        ? AppTheme.primaryAccent
                        : context.borderColor)
                    .withAlpha(60),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: unlocked
                  ? Text(
                      topic.icon.isEmpty ? '✋' : topic.icon,
                      style: const TextStyle(fontSize: 30),
                    )
                  : Icon(
                      Icons.lock_outline,
                      size: 28,
                      color: context.textMutedColor,
                    ),
            ),
            const SizedBox(height: 12),
            Text(
              topic.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: context.textColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              total == 0
                  ? 'ยังไม่มีคำในหัวข้อนี้'
                  : 'ผ่านแล้ว $passedCount จาก $total คำ',
              style: TextStyle(fontSize: 14, color: context.textMutedColor),
            ),
            const SizedBox(height: 20),
            if (!unlocked)
              Text(
                'ผ่านหัวข้อก่อนหน้าเพื่อปลดล็อก',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: context.textMutedColor.withAlpha(200),
                ),
              )
            else ...[
              if (_error != null) ...[
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.warningOrange,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: total == 0 || _resetting
                      ? null
                      : completed
                      ? _restartFromScratch
                      : () => widget.onStart(startIndex),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: completed
                        ? AppTheme.successGreen
                        : AppTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: context.borderColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    _resetting ? 'กำลังล้างความคืบหน้า…' : buttonLabel,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
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
          style: TextStyle(color: context.textColor),
          decoration: InputDecoration(
            hintText: 'ค้นหาคำศัพท์…',
            hintStyle: TextStyle(color: context.textMutedColor),
            prefixIcon: Icon(Icons.search, color: context.textMutedColor),
            filled: true,
            fillColor: context.cardColor,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: context.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: context.borderColor),
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
                return Center(
                  child: Text(
                    'ไม่พบคำศัพท์',
                    style: TextStyle(color: context.textMutedColor),
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
                backgroundColor: context.cardColor,
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
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: context.textMutedColor,
                          ),
                        ),
                      ),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: context.cardColor,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: context.borderColor,
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
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: context.textColor,
                                    ),
                                  ),
                                  trailing: const Icon(
                                    Icons.sign_language_outlined,
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
      backgroundColor: context.cardColor,
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
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: context.textColor,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                sign.category,
                style: TextStyle(
                  fontSize: 13,
                  color: context.textMutedColor,
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
                  color: context.textMutedColor.withAlpha(200),
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
    // Style lives in Settings ("อวาตาร์แบบการ์ตูน"), not here.
    final cartoon =
        ref.watch(settingsProvider.select((s) => s.cartoonAvatar));
    return SignAvatar(
      word: word,
      frames: detail.value?.keypointFrames,
      style: cartoon ? SignAvatarStyle.cartoon : SignAvatarStyle.skeleton,
    );
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
          Text(message, style: TextStyle(color: context.textMutedColor)),
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
