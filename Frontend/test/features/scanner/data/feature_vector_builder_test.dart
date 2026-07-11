import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/scanner/data/services/feature_vector_builder.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

List<LandmarkPoint> hand(double x, double y, double z) =>
    List.generate(21, (_) => LandmarkPoint(x, y, z));

void main() {
  group('buildPositionVector', () {
    test('empty frame -> 147 zeros', () {
      final v = buildPositionVector(
        const RawLandmarkFrame(leftHand: [], rightHand: [], upperPose: []),
      );
      expect(v, hasLength(147));
      expect(v.every((e) => e == 0.0), isTrue);
    });

    test('no pose: hands normalized against mid=[0.5,0.5,0], width=1', () {
      final v = buildPositionVector(
        RawLandmarkFrame(
          leftHand: const [],
          rightHand: hand(0.6, 0.7, 0.1),
          upperPose: const [],
        ),
      );
      // Pose block (0..20) and left block (21..83) stay zero.
      expect(v.sublist(0, 21).every((e) => e == 0.0), isTrue);
      expect(v.sublist(21, 84).every((e) => e == 0.0), isTrue);
      // Right block starts at 84: (0.6-0.5, 0.7-0.5, 0.1-0.0).
      expect(v[84], closeTo(0.1, 1e-9));
      expect(v[85], closeTo(0.2, 1e-9));
      expect(v[86], closeTo(0.1, 1e-9));
    });

    test('with pose: normalizes by shoulder mid/width, z included', () {
      // upperPose order = MediaPipe indices [0,11,12,13,14,15,16];
      // positions 1 and 2 are the shoulders.
      const pose = <LandmarkPoint>[
        LandmarkPoint(0.5, 0.3, 0.0), // nose
        LandmarkPoint(0.4, 0.5, 0.0), // left shoulder (11)
        LandmarkPoint(0.6, 0.5, 0.0), // right shoulder (12)
        LandmarkPoint(0.3, 0.6, 0.0),
        LandmarkPoint(0.7, 0.6, 0.0),
        LandmarkPoint(0.2, 0.7, 0.0),
        LandmarkPoint(0.8, 0.7, 0.0),
      ];
      final v = buildPositionVector(
        const RawLandmarkFrame(leftHand: [], rightHand: [], upperPose: pose),
      );
      // mid = (0.5,0.5,0), width = |0.4-0.6| = 0.2.
      // nose: ((0.5-0.5)/0.2, (0.3-0.5)/0.2, 0) = (0, -1, 0).
      expect(v[0], closeTo(0.0, 1e-9));
      expect(v[1], closeTo(-1.0, 1e-9));
      expect(v[2], closeTo(0.0, 1e-9));
      // shoulders: (0.4-0.5)/0.2 = -0.5 ; (0.6-0.5)/0.2 = 0.5.
      expect(v[3], closeTo(-0.5, 1e-9));
      expect(v[6], closeTo(0.5, 1e-9));
    });

    test('left hand fills the left block; right stays zero', () {
      final v = buildPositionVector(
        RawLandmarkFrame(
          leftHand: hand(0.6, 0.5, 0.0),
          rightHand: const [],
          upperPose: const [],
        ),
      );
      expect(v[21], closeTo(0.1, 1e-9)); // 0.6-0.5
      expect(v[22], closeTo(0.0, 1e-9)); // 0.5-0.5
      expect(v.sublist(84, 147).every((e) => e == 0.0), isTrue);
    });
  });

  group('buildFeatureVector', () {
    test('pads to 441 with zero velocity/acceleration', () {
      final f = buildFeatureVector(
        RawLandmarkFrame(
          leftHand: const [],
          rightHand: hand(0.6, 0.7, 0.1),
          upperPose: const [],
        ),
      );
      expect(f.positionFeatures, hasLength(147));
      expect(f.velocityFeatures, hasLength(147));
      expect(f.accelerationFeatures, hasLength(147));
      expect(f.velocityFeatures.every((e) => e == 0.0), isTrue);
      expect(f.accelerationFeatures.every((e) => e == 0.0), isTrue);
      expect(f.fullVector, hasLength(441));
    });
  });
}
