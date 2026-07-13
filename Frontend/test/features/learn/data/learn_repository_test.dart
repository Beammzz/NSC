import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/learn/data/repositories/learn_repository.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';

void main() {
  group('SimulatedLearnRepository', () {
    test('serves topics with exercises and a dictionary', () async {
      final repo = SimulatedLearnRepository();
      final topics = await repo.fetchTopics();
      expect(topics, isNotEmpty);
      expect(topics.first.exercises, isNotEmpty);
      expect(topics.first.exercises.first.passConfidence, 0.8);

      final signs = await repo.fetchDictionary();
      expect(signs, isNotEmpty);
      expect(signs.every((s) => s.category.isNotEmpty), isTrue);
    });

    test('recordAttempt applies the pass threshold and never regresses',
        () async {
      final repo = SimulatedLearnRepository();
      final topics = await repo.fetchTopics();
      final exercise = topics.first.exercises.first;

      var row = await repo.recordAttempt(exercise.id, 0.5);
      expect(row.passed, isFalse);
      expect(row.bestConfidence, 0.5);

      row = await repo.recordAttempt(exercise.id, 0.85);
      expect(row.passed, isTrue);
      expect(row.bestConfidence, 0.85);

      // A weaker later attempt keeps the best result.
      row = await repo.recordAttempt(exercise.id, 0.3);
      expect(row.passed, isTrue);
      expect(row.bestConfidence, 0.85);

      final progress = await repo.fetchProgress();
      expect(progress, hasLength(1));
    });
  });

  group('learn model parsing', () {
    test('LearnTopic.fromJson parses nested exercises', () {
      final topic = LearnTopic.fromJson({
        'id': 3,
        'slug': 'food',
        'title': 'อาหาร',
        'icon': '🍚',
        'sort_order': 2,
        'published': true,
        'exercises': [
          {
            'id': 7,
            'topic_id': 3,
            'word': 'กิน',
            'sort_order': 0,
            'pass_confidence': 0.85,
            'published': true,
          },
        ],
      });
      expect(topic.id, 3);
      expect(topic.exercises, hasLength(1));
      expect(topic.exercises.first.word, 'กิน');
      expect(topic.exercises.first.passConfidence, 0.85);
    });

    test('parseKeypointFrames handles frames and malformed input', () {
      final frames = parseKeypointFrames([
        [
          {'x': 0.5, 'y': 0.4, 'z': 0.0},
          {'x': 0.6, 'y': 0.3},
        ],
        [
          {'x': 0.55, 'y': 0.45, 'z': 0.1},
        ],
      ]);
      expect(frames, isNotNull);
      expect(frames, hasLength(2));
      expect(frames![0], hasLength(2));
      expect(frames[0][0].x, 0.5);
      expect(frames[0][1].z, 0.0);

      expect(parseKeypointFrames(null), isNull);
      expect(parseKeypointFrames('nonsense'), isNull);
      expect(parseKeypointFrames({'not': 'a list'}), isNull);
    });

    test('LearnProgress.fromJson parses the server row', () {
      final row = LearnProgress.fromJson({
        'exercise_id': 7,
        'best_confidence': 0.92,
        'passed': true,
        'updated_ms': 1700000000000,
      });
      expect(row.exerciseId, 7);
      expect(row.bestConfidence, 0.92);
      expect(row.passed, isTrue);
    });
  });
}
