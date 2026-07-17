import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/scanner/data/services/landmark_extraction_service.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

void main() {
  group('parsePrimaryHand', () {
    test('extracts the first hand as 21 normalized points', () {
      final event = {
        'pose': <double>[],
        'hands': [
          {
            'handedness': 'Right',
            'landmarks': [for (var i = 0; i < 63; i++) i / 100.0],
          },
        ],
      };

      final points = parsePrimaryHand(event);

      expect(points, hasLength(21));
      expect(points.first.x, closeTo(0.0, 1e-9));
      expect(points.first.y, closeTo(0.01, 1e-9));
      expect(points.last.z, closeTo(0.62, 1e-9)); // index 60,61,62 -> z=0.62
    });

    test('returns empty for absent hands or malformed payloads', () {
      expect(parsePrimaryHand({'hands': <dynamic>[]}), isEmpty);
      expect(
        parsePrimaryHand({
          'hands': [
            {'landmarks': [0.1, 0.2]}, // fewer than one full triplet
          ],
        }),
        isEmpty,
      );
      expect(parsePrimaryHand('not a map'), isEmpty);
      expect(parsePrimaryHand(null), isEmpty);
    });
  });

  group('MediaPipeLandmarkExtractionService', () {
    List<double> flatHand(double v) => [for (var i = 0; i < 63; i++) v];

    test('emits the parsed primary hand from injected events after start',
        () async {
      final events = StreamController<dynamic>.broadcast();
      final service = MediaPipeLandmarkExtractionService(events: events.stream);
      addTearDown(service.dispose);

      final frames = <List<LandmarkPoint>>[];
      final sub = service.handLandmarkStream.listen(frames.add);
      addTearDown(sub.cancel);

      service.start();
      events.add({
        'hands': [
          {'handedness': 'Left', 'landmarks': flatHand(0.5)},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(frames, hasLength(1));
      expect(frames.single, hasLength(21));
      expect(frames.single.first.x, 0.5);
    });

    test('stop halts emission', () async {
      final events = StreamController<dynamic>.broadcast();
      final service = MediaPipeLandmarkExtractionService(events: events.stream);
      addTearDown(service.dispose);

      final frames = <List<LandmarkPoint>>[];
      final sub = service.handLandmarkStream.listen(frames.add);
      addTearDown(sub.cancel);

      service.start();
      service.stop();
      events.add({
        'hands': [
          {'handedness': 'Left', 'landmarks': flatHand(0.5)},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(frames, isEmpty);
    });
  });

  group('parseFullFrame', () {
    test('extracts 7 upper-pose points and hands by handedness', () {
      final event = {
        'pose': [for (var i = 0; i < 99; i++) i / 100.0], // 33*3
        'hands': [
          {'handedness': 'Left', 'landmarks': [for (var i = 0; i < 63; i++) 0.5]},
          {'handedness': 'Right', 'landmarks': [for (var i = 0; i < 63; i++) 0.6]},
        ],
      };

      final frame = parseFullFrame(event);

      expect(frame.upperPose, hasLength(7));
      // index 0 (nose) -> pose[0,1,2] = 0.0, 0.01, 0.02
      expect(frame.upperPose.first.x, closeTo(0.0, 1e-9));
      expect(frame.upperPose.first.y, closeTo(0.01, 1e-9));
      // position 1 = MediaPipe index 11 -> pose[33,34,35] = 0.33, 0.34, 0.35
      expect(frame.upperPose[1].x, closeTo(0.33, 1e-9));
      expect(frame.leftHand, hasLength(21));
      expect(frame.rightHand, hasLength(21));
      expect(frame.leftHand.first.x, closeTo(0.5, 1e-9));
      expect(frame.rightHand.first.x, closeTo(0.6, 1e-9));
    });

    test('no pose / no hands -> empty blocks; malformed never throws', () {
      final frame = parseFullFrame({'pose': <double>[], 'hands': <dynamic>[]});
      expect(frame.upperPose, isEmpty);
      expect(frame.leftHand, isEmpty);
      expect(frame.rightHand, isEmpty);
      expect(parseFullFrame('nope').upperPose, isEmpty);
      expect(parseFullFrame(null).rightHand, isEmpty);
    });

    test('parses analysis image dimensions; invalid or absent become null', () {
      final frame = parseFullFrame({
        'pose': <double>[],
        'hands': <dynamic>[],
        'width': 480,
        'height': 640,
      });
      expect(frame.imageWidth, 480);
      expect(frame.imageHeight, 640);

      final noDims = parseFullFrame({'pose': <double>[], 'hands': <dynamic>[]});
      expect(noDims.imageWidth, isNull);
      expect(noDims.imageHeight, isNull);

      final badDims = parseFullFrame({
        'pose': <double>[],
        'hands': <dynamic>[],
        'width': 0,
        'height': 'x',
      });
      expect(badDims.imageWidth, isNull);
      expect(badDims.imageHeight, isNull);
    });

    test('a hand without 21 points is dropped', () {
      final frame = parseFullFrame({
        'hands': [
          {'handedness': 'Right', 'landmarks': [0.1, 0.2, 0.3]},
        ],
      });
      expect(frame.rightHand, isEmpty);
    });
  });
}
