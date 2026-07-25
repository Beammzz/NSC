import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/learn/data/repositories/learn_repository.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';

/// Published roadmap topics with their exercises.
final learnTopicsProvider = FutureProvider<List<LearnTopic>>((ref) {
  return ref.watch(learnRepositoryProvider).fetchTopics();
});

/// Full dictionary listing (no animation frames — see [signDetailProvider]).
final dictionaryProvider = FutureProvider<List<DictionarySign>>((ref) {
  return ref.watch(learnRepositoryProvider).fetchDictionary();
});

/// One dictionary entry including its avatar keypoint frames.
final signDetailProvider =
    FutureProvider.family<DictionarySign, String>((ref, word) {
  return ref.watch(learnRepositoryProvider).fetchSignDetail(word);
});

/// The caller's progress keyed by exercise id. [recordAttempt] posts the
/// attempt and folds the server's (never-regressing) row back into state.
class LearnProgressNotifier
    extends AsyncNotifier<Map<int, LearnProgress>> {
  @override
  Future<Map<int, LearnProgress>> build() async {
    final rows = await ref.watch(learnRepositoryProvider).fetchProgress();
    return {for (final row in rows) row.exerciseId: row};
  }

  Future<LearnProgress> recordAttempt(
      int exerciseId, double confidence) async {
    final row = await ref
        .read(learnRepositoryProvider)
        .recordAttempt(exerciseId, confidence);
    final current = Map<int, LearnProgress>.from(state.value ?? {});
    current[row.exerciseId] = row;
    state = AsyncData(current);
    return row;
  }
}

final learnProgressProvider =
    AsyncNotifierProvider<LearnProgressNotifier, Map<int, LearnProgress>>(
        LearnProgressNotifier.new);
