import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

abstract class LandmarkExtractionService {
  /// Primary hand (21 points) for the overlay painter.
  Stream<List<LandmarkPoint>> get handLandmarkStream;

  /// Full frame (upper pose + both hands) for feature-vector assembly.
  Stream<RawLandmarkFrame> get frameStream;

  void start();
  void stop();
  void dispose();
}

/// Simulated implementation of MediaPipe on-device landmark extraction.
/// Generates the 21 open-hand points from App_Design with live jitter.
class SimulatedLandmarkExtractionService implements LandmarkExtractionService {
  final _controller = StreamController<List<LandmarkPoint>>.broadcast();
  final _frameController = StreamController<RawLandmarkFrame>.broadcast();
  Timer? _timer;
  final _random = math.Random();
  bool _isActive = false;

  // 21 MediaPipe hand landmarks (approx. open-hand pose from App_Design), in
  // normalized 0..1 image coordinates to match the real MediaPipe feed and the
  // overlay painter, which maps normalized points across the full viewport.
  static const _basePoints = [
    [0.50, 0.93], // 0 wrist
    [0.36, 0.83], [0.26, 0.73], [0.20, 0.64], [0.16, 0.55], // thumb 1-4
    [0.39, 0.60], [0.37, 0.46], [0.36, 0.37], [0.35, 0.29], // index 5-8
    [0.50, 0.58], [0.50, 0.42], [0.50, 0.32], [0.50, 0.23], // middle 9-12
    [0.61, 0.60], [0.63, 0.45], [0.64, 0.35], [0.65, 0.27], // ring 13-16
    [0.71, 0.65], [0.76, 0.55], [0.79, 0.46], [0.81, 0.40], // pinky 17-20
  ];

  @override
  Stream<List<LandmarkPoint>> get handLandmarkStream => _controller.stream;

  @override
  Stream<RawLandmarkFrame> get frameStream => _frameController.stream;

  @override
  void start() {
    if (_isActive) return;
    _isActive = true;
    _timer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!_isActive) return;
      final jittered = _basePoints.map((pt) {
        final jx = (_random.nextDouble() - 0.5) * 0.015;
        final jy = (_random.nextDouble() - 0.5) * 0.015;
        return LandmarkPoint(pt[0] + jx, pt[1] + jy);
      }).toList();
      if (!_controller.isClosed) {
        _controller.add(jittered);
      }
      if (!_frameController.isClosed) {
        // The simulated hand stands in for the right hand; no pose/left hand.
        _frameController.add(RawLandmarkFrame(
          leftHand: const [],
          rightHand: jittered,
          upperPose: const [],
        ));
      }
    });
  }

  @override
  void stop() {
    _isActive = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    _controller.close();
    _frameController.close();
  }
}

/// Name of the [EventChannel] the native Android MediaPipe pipeline (Stage B/B3)
/// streams landmark frames on. Each event is a map:
///   { 'pose': [x,y,z * 33] | [], 'hands': [ {'handedness': 'Left'|'Right',
///     'landmarks': [x,y,z * 21]}, ... up to 2 ],
///     'width': `analysis image px`, 'height': `analysis image px` }
/// with MediaPipe normalized image coordinates (x,y in 0..1, z relative depth).
const landmarkEventChannelName = 'signmind/landmarks';

/// Extracts the first (primary) hand of a native landmark [event] as 21
/// normalized [LandmarkPoint]s for the overlay. Returns an empty list for
/// absent hands or malformed payloads — never throws.
List<LandmarkPoint> parsePrimaryHand(dynamic event) {
  if (event is! Map) return const [];
  final hands = event['hands'];
  if (hands is! List || hands.isEmpty) return const [];
  final first = hands.first;
  if (first is! Map) return const [];
  return _parseTriplets(first['landmarks']);
}

/// Parses a flat `[x,y,z, ...]` list into [LandmarkPoint]s, ignoring any
/// trailing partial triplet. Empty list for non-list / malformed input.
List<LandmarkPoint> _parseTriplets(dynamic coords) {
  if (coords is! List) return const [];
  final points = <LandmarkPoint>[];
  for (int i = 0; i + 2 < coords.length; i += 3) {
    final x = (coords[i] as num?)?.toDouble() ?? 0.0;
    final y = (coords[i + 1] as num?)?.toDouble() ?? 0.0;
    final z = (coords[i + 2] as num?)?.toDouble() ?? 0.0;
    points.add(LandmarkPoint(x, y, z));
  }
  return points;
}

/// Extracts the full landmark frame for feature-vector assembly: the 7 upper
/// pose points (MediaPipe indices [0,11,12,13,14,15,16]) plus both hands keyed
/// by handedness ('Left' -> leftHand, anything else -> rightHand, matching
/// ai/extract_keypoints.py). Missing parts become empty lists; never throws.
RawLandmarkFrame parseFullFrame(dynamic event) {
  const empty = RawLandmarkFrame(leftHand: [], rightHand: [], upperPose: []);
  if (event is! Map) return empty;

  const poseIndices = [0, 11, 12, 13, 14, 15, 16];
  final upperPose = <LandmarkPoint>[];
  final pose = event['pose'];
  if (pose is List && pose.length >= 33 * 3) {
    for (final mpIdx in poseIndices) {
      final base = mpIdx * 3;
      upperPose.add(LandmarkPoint(
        (pose[base] as num?)?.toDouble() ?? 0.0,
        (pose[base + 1] as num?)?.toDouble() ?? 0.0,
        (pose[base + 2] as num?)?.toDouble() ?? 0.0,
      ));
    }
  }

  var left = const <LandmarkPoint>[];
  var right = const <LandmarkPoint>[];
  final hands = event['hands'];
  if (hands is List) {
    for (final hand in hands) {
      if (hand is! Map) continue;
      final points = _parseTriplets(hand['landmarks']);
      if (points.length != 21) continue;
      if (hand['handedness'] == 'Left') {
        left = points;
      } else {
        right = points;
      }
    }
  }

  final width = event['width'];
  final height = event['height'];
  return RawLandmarkFrame(
    leftHand: left,
    rightHand: right,
    upperPose: upperPose,
    imageWidth: width is int && width > 0 ? width : null,
    imageHeight: height is int && height > 0 ? height : null,
  );
}

/// Real on-device landmark extraction backed by the native MediaPipe pipeline
/// (Stage B). Listens to [landmarkEventChannelName]; subscribing on [start]
/// triggers the native camera analysis (via the channel's onListen), and
/// [stop] tears it down (onCancel). Coordinates are MediaPipe-normalized.
class MediaPipeLandmarkExtractionService implements LandmarkExtractionService {
  MediaPipeLandmarkExtractionService({Stream<dynamic>? events})
      : _events = events ??
            const EventChannel(landmarkEventChannelName)
                .receiveBroadcastStream();

  final Stream<dynamic> _events;
  final _controller = StreamController<List<LandmarkPoint>>.broadcast();
  final _frameController = StreamController<RawLandmarkFrame>.broadcast();
  StreamSubscription<dynamic>? _sub;
  bool _isActive = false;

  @override
  Stream<List<LandmarkPoint>> get handLandmarkStream => _controller.stream;

  @override
  Stream<RawLandmarkFrame> get frameStream => _frameController.stream;

  @override
  void start() {
    if (_isActive) return;
    _isActive = true;
    _sub = _events.listen(
      (event) {
        if (!_isActive) return;
        if (!_controller.isClosed && _controller.hasListener) {
          _controller.add(parsePrimaryHand(event));
        }
        if (!_frameController.isClosed) _frameController.add(parseFullFrame(event));
      },
      // Native/platform errors just pause overlay updates; the pipeline is
      // restarted by the next start(), not retried here.
      onError: (Object _) {},
    );
  }

  @override
  void stop() {
    _isActive = false;
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    stop();
    _controller.close();
    _frameController.close();
  }
}

// The real native MediaPipe pipeline drives the overlay on Android (landmarks
// arrive over the EventChannel); the simulated feed is used elsewhere and under
// `flutter test`, where no camera or platform channels exist.
final landmarkExtractionServiceProvider = Provider<LandmarkExtractionService>((ref) {
  final isTest = Platform.environment.containsKey('FLUTTER_TEST');
  final LandmarkExtractionService service =
      (!isTest && !kIsWeb && defaultTargetPlatform == TargetPlatform.android)
          ? MediaPipeLandmarkExtractionService()
          : SimulatedLandmarkExtractionService();
  ref.onDispose(service.dispose);
  return service;
});
