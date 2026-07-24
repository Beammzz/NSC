import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

/// How [SignAvatar] draws a keypoint frame.
enum SignAvatarStyle {
  /// Cartoon character: filled torso, face, and five-finger hands built from
  /// the recorded hand landmarks.
  cartoon,

  /// The original stick figure: bones, joint nodes and raw keypoint dots.
  skeleton,
}

/// Avatar that loops through keypoint animation frames (the `keypoint_frames`
/// of a dictionary entry). When [frames] is null, empty, or too sparse to draw
/// a figure — a renderable frame needs the 7 pose points — it plays a
/// procedural signing-figure placeholder derived from [word] so every entry
/// still demonstrates "hands moving in front of an upper body".
///
/// Recorded frames carry the 7 pose points followed by 21 MediaPipe landmarks
/// per detected hand; [SignAvatarStyle.cartoon] draws those as real fingers,
/// [SignAvatarStyle.skeleton] draws them as dots.
class SignAvatar extends StatefulWidget {
  const SignAvatar({
    super.key,
    required this.word,
    this.frames,
    this.size = 220,
    this.style = SignAvatarStyle.cartoon,
  });

  final String word;
  final List<List<LandmarkPoint>>? frames;
  final double size;
  final SignAvatarStyle style;

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
              style: widget.style,
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
    required this.style,
  });

  /// Loop position 0..1.
  final double t;
  final List<List<LandmarkPoint>>? frames;
  final int seed;
  final SignAvatarStyle style;

  // Upper-body edges over 7 pose points in the emitted order
  // [nose, Lshoulder, Rshoulder, Lelbow, Relbow, Lwrist, Rwrist] —
  // same layout the scanner overlay paints.
  static const _poseConnections = [
    [1, 2],
    [1, 3], [3, 5],
    [2, 4], [4, 6],
  ];

  /// Landmarks per MediaPipe hand, and the finger bone chains over them.
  static const _handPointCount = 21;
  // Fingers start at their knuckle, not the wrist: chains through the palm
  // would pile on top of each other and read as one blob. The palm polygon
  // below covers the bases.
  static const _fingerChains = [
    [1, 2, 3, 4],
    [5, 6, 7, 8],
    [9, 10, 11, 12],
    [13, 14, 15, 16],
    [17, 18, 19, 20],
  ];
  static const _palmOutline = [0, 1, 5, 9, 13, 17];

  // Cartoon palette. Fixed rather than theme-derived: the figure carries its
  // own dark outline, so it reads on both the light and dark card colors.
  static const _skin = Color(0xFFF3C9A2);
  static const _skinShade = Color(0xFFE0AE83);
  static const _outlineColor = Color(0xFF2A2E3A);
  static const _hair = Color(0xFF3B2A24);
  static const _blush = Color(0x55E8746B);
  static const _eyeWhite = Color(0xFFFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final source = frames;
    final points = source != null ? _dataFrame(source) : _proceduralFrame();
    if (points.isEmpty) return;

    final fit = _viewFit(size, source);
    // Unknown layouts (e.g. the 2-point server stub) have no figure to draw in
    // either style, so they always fall through to the dot renderer.
    if (style == SignAvatarStyle.skeleton || points.length < 7) {
      _paintSkeleton(canvas, size, points, fit);
      return;
    }
    _paintCartoon(canvas, points, _handsForFrame(source, points), fit);
  }

  // --- framing ----------------------------------------------------------

  /// Uniform scale + offset placing the whole clip inside the widget box.
  /// Recorded coordinates span the camera frame, so the raw figure runs off
  /// the edges. The box is measured over EVERY frame (not the current one) so
  /// the figure holds still while the animation plays, and the scale is
  /// uniform so the recorded proportions survive.
  _ViewFit _viewFit(Size size, List<List<LandmarkPoint>>? source) {
    var minX = 0.25, maxX = 0.75, minY = 0.20, maxY = 0.72;
    var shoulderW = 0.28;
    // The synthesized torso hangs below the recorded points; nothing in the
    // data marks where it ends, so reserve room for it.
    var torsoBottom = 0.38 + shoulderW * 1.5;

    if (source != null && source.isNotEmpty) {
      minX = minY = double.infinity;
      maxX = maxY = -double.infinity;
      shoulderW = 0;
      torsoBottom = -double.infinity;
      for (final frame in source) {
        for (final p in frame) {
          minX = math.min(minX, p.x);
          maxX = math.max(maxX, p.x);
          minY = math.min(minY, p.y);
          maxY = math.max(maxY, p.y);
        }
        if (frame.length < 7) continue;
        final w = _dist(frame[1], frame[2]);
        shoulderW = math.max(shoulderW, w);
        torsoBottom = math.max(
            torsoBottom, (frame[1].y + frame[2].y) / 2 + w * 1.5);
      }
      if (!minX.isFinite || maxX <= minX) return const _ViewFit(1, Offset.zero);
      if (shoulderW <= 0) shoulderW = maxX - minX;
      if (!torsoBottom.isFinite) torsoBottom = maxY;
    }

    // Only the cartoon draws a body past the landmarks; the skeleton would
    // just gain dead space at the bottom.
    if (style == SignAvatarStyle.skeleton) {
      torsoBottom = double.negativeInfinity;
    }
    // Head, torso sides and limb thickness all live outside the landmarks.
    final pad = shoulderW * 0.62;
    minX -= pad;
    maxX += pad;
    minY -= pad;
    maxY = math.max(maxY + pad * 0.4, torsoBottom);

    final boxW = math.max(maxX - minX, 1e-6);
    final boxH = math.max(maxY - minY, 1e-6);
    final scale = math.min(size.width / boxW, size.height / boxH);
    return _ViewFit(
      scale,
      Offset(
        (size.width - boxW * scale) / 2 - minX * scale,
        (size.height - boxH * scale) / 2 - minY * scale,
      ),
    );
  }

  // --- frame selection -------------------------------------------------

  /// Picks the animation frame for the current loop position.
  List<LandmarkPoint> _dataFrame(List<List<LandmarkPoint>> frames) {
    return frames[_frameIndex(frames.length)];
  }

  int _frameIndex(int length) =>
      (t * length).floor().clamp(0, length - 1);

  // --- hand landmark handling ------------------------------------------

  /// Splits a frame's trailing landmarks into 21-point hand blocks. Frames
  /// whose tail is not a whole number of hands (the procedural placeholder's
  /// fingertip dots) yield none.
  List<List<LandmarkPoint>> _handBlocks(List<LandmarkPoint> frame) {
    final extra = frame.length - 7;
    if (extra <= 0 || extra % _handPointCount != 0) return const [];
    return [
      for (var i = 7; i + _handPointCount <= frame.length; i += _handPointCount)
        frame.sublist(i, i + _handPointCount),
    ];
  }

  static double _dist(LandmarkPoint a, LandmarkPoint b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Maps a frame's hand blocks onto its two pose wrists — slot 0 belongs to
  /// pose point 5, slot 1 to pose point 6. MediaPipe emits hands in detection
  /// order, not left/right order, so the pairing is chosen by wrist distance.
  List<List<LandmarkPoint>?> _assignHands(List<LandmarkPoint> frame) {
    final result = <List<LandmarkPoint>?>[null, null];
    final blocks = _handBlocks(frame);
    if (blocks.isEmpty) return result;
    final wrists = [frame[5], frame[6]];
    if (blocks.length == 1) {
      final block = blocks.first;
      final slot =
          _dist(block[0], wrists[0]) <= _dist(block[0], wrists[1]) ? 0 : 1;
      result[slot] = block;
      return result;
    }
    final a = blocks[0];
    final b = blocks[1];
    final straight = _dist(a[0], wrists[0]) + _dist(b[0], wrists[1]);
    final swapped = _dist(a[0], wrists[1]) + _dist(b[0], wrists[0]);
    result[0] = straight <= swapped ? a : b;
    result[1] = straight <= swapped ? b : a;
    return result;
  }

  /// Hands to draw for [current]. Roughly half of the recorded frames carry no
  /// hand landmarks at all (detection drops out), so a wrist without data this
  /// frame reuses the most recently seen hand, re-anchored on the current
  /// wrist point — the hand follows the arm instead of vanishing or freezing.
  /// The search wraps around the loop, so frame 0 inherits from the tail.
  List<List<LandmarkPoint>?> _handsForFrame(
    List<List<LandmarkPoint>>? source,
    List<LandmarkPoint> current,
  ) {
    final hands = _assignHands(current);
    if (source == null || source.isEmpty) return hands;
    final index = _frameIndex(source.length);
    for (var slot = 0; slot < 2; slot++) {
      if (hands[slot] != null) continue;
      for (var back = 1; back <= source.length; back++) {
        final past = source[(index - back) % source.length];
        if (past.length < 7) continue;
        final held = _assignHands(past)[slot];
        if (held == null) continue;
        hands[slot] = _anchor(held, current[5 + slot]);
        break;
      }
    }
    return hands;
  }

  /// Shifts a hand so its wrist landmark sits on [wrist].
  List<LandmarkPoint> _anchor(List<LandmarkPoint> hand, LandmarkPoint wrist) {
    final dx = wrist.x - hand[0].x;
    final dy = wrist.y - hand[0].y;
    return [for (final p in hand) LandmarkPoint(p.x + dx, p.y + dy, p.z)];
  }

  // --- cartoon renderer -------------------------------------------------

  void _paintCartoon(
    Canvas canvas,
    List<LandmarkPoint> points,
    List<List<LandmarkPoint>?> hands,
    _ViewFit fit,
  ) {
    Offset toOffset(LandmarkPoint pt) => fit.apply(pt);

    final nose = toOffset(points[0]);
    final lShoulder = toOffset(points[1]);
    final rShoulder = toOffset(points[2]);
    final lElbow = toOffset(points[3]);
    final rElbow = toOffset(points[4]);
    final lWrist = toOffset(points[5]);
    final rWrist = toOffset(points[6]);

    final shoulderMid = (lShoulder + rShoulder) / 2;
    // Every proportion below is a multiple of shoulder width, so the figure
    // keeps its build whoever was recorded and however close they stood.
    var shoulderW = (lShoulder - rShoulder).distance;
    if (shoulderW < fit.scale * 0.05) shoulderW = fit.scale * 0.30;
    final down = _unit(shoulderMid - nose, const Offset(0, 1));
    final side = _unit(lShoulder - rShoulder, const Offset(1, 0));

    final outlineW = shoulderW * 0.075;
    final headRadius = shoulderW * 0.46;
    final headCenter = nose - down * (headRadius * 0.22);

    final skinFill = Paint()..color = _skin;
    final sleeveFill = Paint()..color = AppTheme.primaryAccent;
    final outline = Paint()
      ..color = _outlineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = outlineW
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    void stroke(Path path, Color color, double width) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    // Neck first: torso and head both overlap it.
    final neckW = shoulderW * 0.30;
    final neck = Path()
      ..moveTo(headCenter.dx, headCenter.dy)
      ..lineTo(shoulderMid.dx, shoulderMid.dy);
    stroke(neck, _outlineColor, neckW + outlineW);
    stroke(neck, _skinShade, neckW);

    // Torso: a rounded shirt from the shoulder line down to synthesized hips
    // (the recording has no hip landmarks).
    final torsoTop = shoulderMid + down * (shoulderW * 0.02);
    final hipMid = shoulderMid + down * (shoulderW * 1.20);
    final halfTop = shoulderW * 0.60;
    final halfHip = shoulderW * 0.48;
    final torso = Path()
      ..moveTo((torsoTop + side * halfTop).dx, (torsoTop + side * halfTop).dy)
      ..quadraticBezierTo(
        (torsoTop + down * (shoulderW * 0.6) + side * (halfTop * 1.05)).dx,
        (torsoTop + down * (shoulderW * 0.6) + side * (halfTop * 1.05)).dy,
        (hipMid + side * halfHip).dx,
        (hipMid + side * halfHip).dy,
      )
      ..quadraticBezierTo(
        (hipMid + down * (shoulderW * 0.22)).dx,
        (hipMid + down * (shoulderW * 0.22)).dy,
        (hipMid - side * halfHip).dx,
        (hipMid - side * halfHip).dy,
      )
      ..quadraticBezierTo(
        (torsoTop + down * (shoulderW * 0.6) - side * (halfTop * 1.05)).dx,
        (torsoTop + down * (shoulderW * 0.6) - side * (halfTop * 1.05)).dy,
        (torsoTop - side * halfTop).dx,
        (torsoTop - side * halfTop).dy,
      )
      ..quadraticBezierTo(
        (torsoTop - down * (shoulderW * 0.12)).dx,
        (torsoTop - down * (shoulderW * 0.12)).dy,
        (torsoTop + side * halfTop).dx,
        (torsoTop + side * halfTop).dy,
      )
      ..close();
    canvas.drawPath(torso, sleeveFill);
    canvas.drawPath(torso, outline);

    // Arms: sleeved upper arm, bare forearm, both driven by the recorded
    // elbow and wrist points. Outlines are laid down first so the fills of
    // one segment never cut into the outline of the next.
    final upperW = shoulderW * 0.30;
    final foreW = shoulderW * 0.24;
    for (final arm in [
      [lShoulder, lElbow, lWrist],
      [rShoulder, rElbow, rWrist],
    ]) {
      final path = Path()
        ..moveTo(arm[0].dx, arm[0].dy)
        ..lineTo(arm[1].dx, arm[1].dy)
        ..lineTo(arm[2].dx, arm[2].dy);
      stroke(path, _outlineColor, upperW + outlineW);
    }
    for (final arm in [
      [lShoulder, lElbow, lWrist],
      [rShoulder, rElbow, rWrist],
    ]) {
      canvas.drawLine(
        arm[0],
        arm[1],
        Paint()
          ..color = AppTheme.primaryAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = upperW
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        arm[1],
        arm[2],
        Paint()
          ..color = _skin
          ..style = PaintingStyle.stroke
          ..strokeWidth = foreW
          ..strokeCap = StrokeCap.round,
      );
    }

    _paintHead(canvas, headCenter, headRadius, down, outlineW);

    // Hands last: signing happens in front of the body.
    _paintHand(canvas, hands[0], lWrist, shoulderW, toOffset, outlineW,
        skinFill, outline, stroke);
    _paintHand(canvas, hands[1], rWrist, shoulderW, toOffset, outlineW,
        skinFill, outline, stroke);
  }

  /// Head, hair and face. Drawn in a local frame rotated so +y follows [down],
  /// which keeps the face upright when the recorded shoulders are tilted.
  void _paintHead(
    Canvas canvas,
    Offset center,
    double radius,
    Offset down,
    double outlineW,
  ) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(math.atan2(down.dy, down.dx) - math.pi / 2);

    final headRect = Rect.fromCircle(center: Offset.zero, radius: radius);
    canvas.drawCircle(Offset.zero, radius, Paint()..color = _skin);

    // Hair cap: the top of the head circle, clipped so it hugs the skull.
    canvas.save();
    canvas.clipPath(Path()..addOval(headRect));
    canvas.drawRect(
      Rect.fromLTRB(-radius, -radius, radius, -radius * 0.30),
      Paint()..color = _hair,
    );
    canvas.restore();

    canvas.drawCircle(
      Offset.zero,
      radius,
      Paint()
        ..color = _outlineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = outlineW,
    );

    // Eyes with a highlight, blush, and a smile. The recording has one face
    // point (the nose), so the expression is fixed rather than data-driven.
    for (final dir in [-1.0, 1.0]) {
      final eye = Offset(dir * radius * 0.36, radius * 0.02);
      canvas.drawCircle(eye, radius * 0.14, Paint()..color = _outlineColor);
      canvas.drawCircle(
        eye.translate(radius * 0.05, -radius * 0.05),
        radius * 0.05,
        Paint()..color = _eyeWhite,
      );
      canvas.drawCircle(
        Offset(dir * radius * 0.58, radius * 0.32),
        radius * 0.13,
        Paint()..color = _blush,
      );
    }
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(0, radius * 0.28),
        width: radius * 0.62,
        height: radius * 0.46,
      ),
      0.15 * math.pi,
      0.70 * math.pi,
      false,
      Paint()
        ..color = _outlineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = outlineW * 0.85
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  /// One hand: palm polygon plus five finger chains over the 21 recorded
  /// landmarks. A wrist that never had hand data in the whole clip gets a
  /// plain mitten so the arm does not end in a stump.
  void _paintHand(
    Canvas canvas,
    List<LandmarkPoint>? hand,
    Offset wrist,
    double shoulderW,
    Offset Function(LandmarkPoint) toOffset,
    double outlineW,
    Paint skinFill,
    Paint outline,
    void Function(Path, Color, double) stroke,
  ) {
    if (hand == null || hand.length < _handPointCount) {
      final mitten = Path()
        ..addOval(Rect.fromCircle(center: wrist, radius: shoulderW * 0.19));
      canvas.drawPath(mitten, skinFill);
      canvas.drawPath(mitten, outline);
      return;
    }

    final p = [for (final lm in hand) toOffset(lm)];
    final fingerW = shoulderW * 0.105;
    // A hand is a lot of parallel strokes in a small area, so it gets a
    // thinner outline than the body — at the body's weight, curled fingers
    // fill in solid black.
    final handOutlineW = outlineW * 0.5;

    // Palm first, so the finger outlines below land on top of it.
    final palm = Path()
      ..moveTo(p[_palmOutline.first].dx, p[_palmOutline.first].dy);
    for (final i in _palmOutline.skip(1)) {
      palm.lineTo(p[i].dx, p[i].dy);
    }
    palm.close();
    stroke(palm, _outlineColor, fingerW + handOutlineW * 2);
    canvas.drawPath(palm, skinFill);
    stroke(palm, _outlineColor, handOutlineW);

    // One finger at a time — outline then fill. Drawing every outline first
    // lets the next finger's fill erase the line between them, which is what
    // turned a spread hand into a mitten. Farthest finger first (landmark z is
    // depth relative to the wrist, negative = toward the camera) so overlaps
    // stack the way the real hand did.
    final chains = [..._fingerChains]
      ..sort((a, b) => _meanZ(hand, b).compareTo(_meanZ(hand, a)));
    for (final chain in chains) {
      final path = Path()..moveTo(p[chain.first].dx, p[chain.first].dy);
      for (final i in chain.skip(1)) {
        path.lineTo(p[i].dx, p[i].dy);
      }
      stroke(path, _outlineColor, fingerW + handOutlineW * 2);
      stroke(path, _skin, fingerW);
    }
  }

  static double _meanZ(List<LandmarkPoint> hand, List<int> chain) {
    var sum = 0.0;
    for (final i in chain) {
      sum += hand[i].z;
    }
    return sum / chain.length;
  }

  static Offset _unit(Offset v, Offset fallback) =>
      v.distance < 1e-6 ? fallback : v / v.distance;

  // --- skeleton renderer (the original stick figure) --------------------

  void _paintSkeleton(
    Canvas canvas,
    Size size,
    List<LandmarkPoint> points,
    _ViewFit fit,
  ) {
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

    Offset toOffset(LandmarkPoint pt) => fit.apply(pt);

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
        final c = toOffset(points[i]);
        canvas.drawCircle(c, 2.6, nodeFill);
        canvas.drawCircle(c, 2.6, nodeStroke);
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

  // --- procedural placeholder -------------------------------------------

  /// Procedural upper-body figure signing in front of the camera: both
  /// wrists trace word-seeded ellipses at chest height. Layout matches the
  /// 7-point pose order so the renderers above draw it.
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

    // Five fingertip dots fanned around each wrist suggest hands. The cartoon
    // renderer ignores them (not a 21-landmark hand) and draws mittens.
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
      oldDelegate.seed != seed ||
      oldDelegate.style != style;
}

/// Normalized-coordinate to canvas mapping: one scale for both axes, so the
/// figure keeps its recorded proportions.
class _ViewFit {
  const _ViewFit(this.scale, this.offset);

  final double scale;
  final Offset offset;

  Offset apply(LandmarkPoint p) =>
      Offset(p.x * scale + offset.dx, p.y * scale + offset.dy);
}
