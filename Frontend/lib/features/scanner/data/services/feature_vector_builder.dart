import 'dart:math' as math;
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

/// Builds the 147-dim body-normalized position vector from a raw landmark
/// frame, byte-matching ai/extract_keypoints.py:120-166:
///   [Pose 7*3 | LeftHand 21*3 | RightHand 21*3]
///
/// Every point is normalized `(kp - shoulder_mid) / shoulder_width` with z
/// included, where `shoulder_mid = (pose[11] + pose[12]) / 2` and
/// `shoulder_width = ||pose[11] - pose[12]||` (3D). With no pose the pose block
/// stays zero, but hands are still normalized against the defaults
/// `mid = [0.5, 0.5, 0]`, `width = 1.0`. A missing hand/pose is all zeros.
List<double> buildPositionVector(RawLandmarkFrame frame) {
  final hasPose = frame.upperPose.length == 7;

  double midX = 0.5, midY = 0.5, midZ = 0.0;
  double width = 1.0;
  if (hasPose) {
    final lShoulder = frame.upperPose[1]; // MediaPipe index 11
    final rShoulder = frame.upperPose[2]; // MediaPipe index 12
    midX = (lShoulder.x + rShoulder.x) / 2.0;
    midY = (lShoulder.y + rShoulder.y) / 2.0;
    midZ = (lShoulder.z + rShoulder.z) / 2.0;
    final dx = lShoulder.x - rShoulder.x;
    final dy = lShoulder.y - rShoulder.y;
    final dz = lShoulder.z - rShoulder.z;
    width = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (width == 0.0) width = 1.0;
  }

  final out = <double>[];

  // Pose block (21). Zeros when no pose was detected.
  if (hasPose) {
    for (final p in frame.upperPose) {
      out
        ..add((p.x - midX) / width)
        ..add((p.y - midY) / width)
        ..add((p.z - midZ) / width);
    }
  } else {
    out.addAll(List<double>.filled(21, 0.0));
  }

  _appendHand(out, frame.leftHand, midX, midY, midZ, width);
  _appendHand(out, frame.rightHand, midX, midY, midZ, width);

  return out;
}

void _appendHand(
  List<double> out,
  List<LandmarkPoint> hand,
  double midX,
  double midY,
  double midZ,
  double width,
) {
  if (hand.length != 21) {
    out.addAll(List<double>.filled(63, 0.0));
    return;
  }
  for (final p in hand) {
    out
      ..add((p.x - midX) / width)
      ..add((p.y - midY) / width)
      ..add((p.z - midZ) / width);
  }
}

/// Wraps the 147 position vector into a [FeatureVectorFrame]. Velocity and
/// acceleration are zero-filled: the server recomputes them from its own frame
/// history and reads only the first 147 features (docs/api/stream-schema.md).
FeatureVectorFrame buildFeatureVector(RawLandmarkFrame frame) {
  return FeatureVectorFrame(
    positionFeatures: buildPositionVector(frame),
    velocityFeatures: List<double>.filled(147, 0.0),
    accelerationFeatures: List<double>.filled(147, 0.0),
  );
}
