import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

/// Skeletal avatar that loops through keypoint animation frames (the
/// `keypoint_frames` of a dictionary entry). When [frames] is null, empty,
/// or too sparse to draw a figure — a renderable frame needs the 7 pose
/// points — it plays a procedural signing-figure placeholder derived from
/// [word] so every entry still demonstrates "hands moving in front of an
/// upper body".
class SignAvatar extends StatefulWidget {
  const SignAvatar({
    super.key,
    required this.word,
    this.frames,
    this.size = 220,
  });

  final String word;
  final List<List<LandmarkPoint>>? frames;
  final double size;

  @override
  State<SignAvatar> createState() => _SignAvatarState();
}

class _SignAvatarState extends State<SignAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = widget.frames;
    // A frame needs the 7 pose points to render as a signing figure; sparser
    // data falls back to procedural.
    final hasData =
        frames != null && frames.isNotEmpty && frames.first.length >= 7;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _SignAvatarPainter(
              t: _controller.value,
              frames: hasData ? frames : null,
              seed: widget.word.hashCode,
            ),
          );
        },
      ),
    );
  }
}

class _SignAvatarPainter extends CustomPainter {
  _SignAvatarPainter({
    required this.t,
    required this.frames,
    required this.seed,
  });

  /// Loop position 0..1.
  final double t;
  final List<List<LandmarkPoint>>? frames;
  final int seed;

  // Upper-body edges over 7 pose points in the emitted order
  // [nose, Lshoulder, Rshoulder, Lelbow, Relbow, Lwrist, Rwrist] —
  // same layout the scanner overlay paints.
  static const _poseConnections = [
    [1, 2],
    [1, 3], [3, 5],
    [2, 4], [4, 6],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final points = frames != null ? _dataFrame(frames!) : _proceduralFrame();
    if (points.isEmpty) return;

    final linePaint = Paint()
      ..color = AppTheme.primaryAccent.withAlpha(216)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final nodeFill = Paint()..color = Colors.white;
    final nodeStroke = Paint()
      ..color = AppTheme.primaryAccent
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    Offset toOffset(LandmarkPoint pt) =>
        Offset(pt.x * size.width, pt.y * size.height);

    if (points.length >= 7) {
      // Head: a circle at the nose point reads better than a bare dot.
      canvas.drawCircle(
          toOffset(points[0]), size.width * 0.075, nodeStroke);
      // Neck: nose down to the shoulder midpoint.
      final mid = LandmarkPoint(
        (points[1].x + points[2].x) / 2,
        (points[1].y + points[2].y) / 2,
      );
      canvas.drawLine(toOffset(points[0]), toOffset(mid), linePaint);
      for (final conn in _poseConnections) {
        canvas.drawLine(
            toOffset(points[conn[0]]), toOffset(points[conn[1]]), linePaint);
      }
      for (var i = 1; i < 7; i++) {
        final c = toOffset(points[i]);
        canvas.drawCircle(c, 4.0, nodeFill);
        canvas.drawCircle(c, 4.0, nodeStroke);
      }
      // Any extra points (hand keypoints) render as smaller dots.
      for (var i = 7; i < points.length; i++) {
        canvas.drawCircle(toOffset(points[i]), 2.6, nodeFill);
      }
    } else {
      // Unknown layout (e.g. sparse server stub frames): plain dots.
      for (final pt in points) {
        final c = toOffset(pt);
        canvas.drawCircle(c, 5.0, nodeFill);
        canvas.drawCircle(c, 5.0, nodeStroke);
      }
    }
  }

  /// Picks the animation frame for the current loop position.
  List<LandmarkPoint> _dataFrame(List<List<LandmarkPoint>> frames) {
    final idx = (t * frames.length).floor().clamp(0, frames.length - 1);
    return frames[idx];
  }

  /// Procedural upper-body figure signing in front of the camera: both
  /// wrists trace word-seeded ellipses at chest height. Layout matches the
  /// 7-point pose order so the pose renderer above draws it.
  List<LandmarkPoint> _proceduralFrame() {
    final phase = t * 2 * math.pi;
    // Word-seeded variation so different entries look distinct.
    final rnd = math.Random(seed);
    final ampX = 0.06 + rnd.nextDouble() * 0.06;
    final ampY = 0.05 + rnd.nextDouble() * 0.05;
    final phaseOffset = rnd.nextDouble() * math.pi;
    final mirror = rnd.nextBool() ? 1.0 : -1.0;

    const nose = LandmarkPoint(0.5, 0.22);
    const lShoulder = LandmarkPoint(0.36, 0.38);
    const rShoulder = LandmarkPoint(0.64, 0.38);

    final lWrist = LandmarkPoint(
      0.36 + ampX * math.sin(phase + phaseOffset),
      0.58 + ampY * math.cos(phase),
    );
    final rWrist = LandmarkPoint(
      0.64 + ampX * math.sin(mirror * phase),
      0.58 + ampY * math.cos(mirror * phase + phaseOffset),
    );
    final lElbow = LandmarkPoint(
      (lShoulder.x + lWrist.x) / 2 - 0.05,
      (lShoulder.y + lWrist.y) / 2 + 0.03,
    );
    final rElbow = LandmarkPoint(
      (rShoulder.x + rWrist.x) / 2 + 0.05,
      (rShoulder.y + rWrist.y) / 2 + 0.03,
    );

    // Five fingertip dots fanned around each wrist suggest hands.
    List<LandmarkPoint> hand(LandmarkPoint wrist, double dir) {
      return List.generate(5, (i) {
        final angle = -math.pi / 2 + (i - 2) * 0.35 + 0.15 * math.sin(phase);
        return LandmarkPoint(
          wrist.x + dir * 0.045 * math.cos(angle),
          wrist.y + 0.045 * math.sin(angle),
        );
      });
    }

    return [
      nose, lShoulder, rShoulder, lElbow, rElbow, lWrist, rWrist,
      ...hand(lWrist, -1),
      ...hand(rWrist, 1),
    ];
  }

  @override
  bool shouldRepaint(covariant _SignAvatarPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.frames != frames ||
      oldDelegate.seed != seed;
}
