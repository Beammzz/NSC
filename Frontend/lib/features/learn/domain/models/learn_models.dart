import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

/// Domain models for the Learn tab: the TSL dictionary and the exercise
/// roadmap (topics -> perform-the-sign exercises). Shapes mirror the
/// backend learn API (`/api/v1/learn/*`, Backend/internal/learn).

/// One perform-the-sign exercise: the learner must produce [word] with
/// model confidence >= [passConfidence] (admin-editable, default 0.80).
class LearnExercise {
  final int id;
  final int topicId;
  final String word;
  final int sortOrder;
  final double passConfidence;

  const LearnExercise({
    required this.id,
    required this.topicId,
    required this.word,
    required this.sortOrder,
    required this.passConfidence,
  });

  factory LearnExercise.fromJson(Map<String, dynamic> json) {
    return LearnExercise(
      id: (json['id'] as num?)?.toInt() ?? 0,
      topicId: (json['topic_id'] as num?)?.toInt() ?? 0,
      word: json['word'] as String? ?? '',
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      passConfidence: (json['pass_confidence'] as num?)?.toDouble() ?? 0.8,
    );
  }
}

/// One roadmap node grouping related exercises (e.g. food, greetings).
class LearnTopic {
  final int id;
  final String slug;
  final String title;
  final String icon;
  final int sortOrder;
  final List<LearnExercise> exercises;

  const LearnTopic({
    required this.id,
    required this.slug,
    required this.title,
    required this.icon,
    required this.sortOrder,
    required this.exercises,
  });

  factory LearnTopic.fromJson(Map<String, dynamic> json) {
    final rawExercises = json['exercises'];
    return LearnTopic(
      id: (json['id'] as num?)?.toInt() ?? 0,
      slug: json['slug'] as String? ?? '',
      title: json['title'] as String? ?? '',
      icon: json['icon'] as String? ?? '',
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      exercises: rawExercises is List
          ? rawExercises
              .whereType<Map<String, dynamic>>()
              .map(LearnExercise.fromJson)
              .toList()
          : const [],
    );
  }
}

/// One dictionary entry. [keypointFrames] (frames of avatar landmark
/// points) is only populated by the detail fetch and may be null — the UI
/// then renders a procedural placeholder animation.
class DictionarySign {
  final String word;
  final String category;
  final bool hasAnimation;
  final List<List<LandmarkPoint>>? keypointFrames;

  const DictionarySign({
    required this.word,
    required this.category,
    required this.hasAnimation,
    this.keypointFrames,
  });

  factory DictionarySign.fromJson(Map<String, dynamic> json) {
    return DictionarySign(
      word: json['word'] as String? ?? '',
      category: json['category'] as String? ?? '',
      hasAnimation: json['has_animation'] == true,
      keypointFrames: parseKeypointFrames(json['keypoint_frames']),
    );
  }
}

/// Parses `[[{x,y,z}, ...], ...]` keypoint animation frames; returns null
/// when absent or malformed.
List<List<LandmarkPoint>>? parseKeypointFrames(dynamic raw) {
  if (raw is! List) return null;
  return raw.map((frame) {
    if (frame is! List) return <LandmarkPoint>[];
    return frame.map((pt) {
      if (pt is Map) {
        return LandmarkPoint(
          (pt['x'] as num?)?.toDouble() ?? 0.0,
          (pt['y'] as num?)?.toDouble() ?? 0.0,
          (pt['z'] as num?)?.toDouble() ?? 0.0,
        );
      }
      return const LandmarkPoint(0.0, 0.0);
    }).toList();
  }).toList();
}

/// The caller's best result on one exercise. `passed` is derived
/// server-side from the exercise's threshold and never regresses.
class LearnProgress {
  final int exerciseId;
  final double bestConfidence;
  final bool passed;

  const LearnProgress({
    required this.exerciseId,
    required this.bestConfidence,
    required this.passed,
  });

  factory LearnProgress.fromJson(Map<String, dynamic> json) {
    return LearnProgress(
      exerciseId: (json['exercise_id'] as num?)?.toInt() ?? 0,
      bestConfidence: (json['best_confidence'] as num?)?.toDouble() ?? 0.0,
      passed: json['passed'] == true,
    );
  }
}
