/// Domain models for the real-time TSL scanner feature.
///
/// Feature vector dimensions and landmark layouts conform strictly to the
/// root Feature Vector Spec defined in root AGENTS.md.
class LandmarkPoint {
  final double x;
  final double y;
  final double z;

  const LandmarkPoint(this.x, this.y, [this.z = 0.0]);

  LandmarkPoint copyWith({double? x, double? y, double? z}) {
    return LandmarkPoint(
      x ?? this.x,
      y ?? this.y,
      z ?? this.z,
    );
  }
}

/// Represents a raw frame of extracted landmarks before vector normalization.
/// Conformant to the root Feature Vector Spec layout.
class RawLandmarkFrame {
  final List<LandmarkPoint> leftHand;
  final List<LandmarkPoint> rightHand;
  final List<LandmarkPoint> upperPose;

  /// Pixel dimensions of the upright analysis image the normalized landmark
  /// coordinates refer to. Null when the source doesn't report them (the
  /// simulated feed); the overlay then maps points across the full viewport
  /// instead of replicating the preview's cover-crop.
  final int? imageWidth;
  final int? imageHeight;

  const RawLandmarkFrame({
    required this.leftHand,
    required this.rightHand,
    required this.upperPose,
    this.imageWidth,
    this.imageHeight,
  });
}

/// A normalized vector representation ready for WebSocket streaming to `/api/v1/stream`.
/// Conforms to the root Feature Vector Spec (position + velocity + acceleration = 441 dims).
class FeatureVectorFrame {
  final List<double> positionFeatures;
  final List<double> velocityFeatures;
  final List<double> accelerationFeatures;
  final List<double> fullVector;

  FeatureVectorFrame({
    required this.positionFeatures,
    required this.velocityFeatures,
    required this.accelerationFeatures,
    List<double>? fullVector,
  }) : fullVector = fullVector ??
            [
              ...positionFeatures,
              ...velocityFeatures,
              ...accelerationFeatures,
            ];
}

/// Live state of the connection to the TSL stream backend (real or simulated).
enum ConnectionStatus { disconnected, connecting, connected }

/// Translation result frame received from the server stream or simulated demo loop.
class TranslationFrame {
  final String word;
  final double confidence;
  final int fps;
  final double latencySeconds;
  final bool isDetecting;

  const TranslationFrame({
    required this.word,
    required this.confidence,
    required this.fps,
    required this.latencySeconds,
    required this.isDetecting,
  });
}

/// Immutable state for the Scanner feature screen managed via Riverpod.
class ScannerState {
  final bool isScanning;
  final String currentWord;
  final double confidence;
  final List<String> sentence;
  final int fps;
  final double latencySeconds;
  final bool isSpeaking;
  // NOTE: the live landmark frame is deliberately NOT part of this state —
  // it updates ~12x/s and lives in `currentFrameProvider` so only the
  // skeleton overlay rebuilds per frame (see scanner_provider.dart).
  final int demoPhase; // 0=detecting, 1=detected, 2=hold
  final ConnectionStatus connectionStatus;

  const ScannerState({
    required this.isScanning,
    required this.currentWord,
    required this.confidence,
    required this.sentence,
    required this.fps,
    required this.latencySeconds,
    required this.isSpeaking,
    required this.demoPhase,
    required this.connectionStatus,
  });

  factory ScannerState.initial() {
    return const ScannerState(
      isScanning: true,
      currentWord: '…',
      confidence: 0.0,
      sentence: [],
      fps: 24,
      latencySeconds: 1.1,
      isSpeaking: false,
      demoPhase: 0,
      // Default settings start in simulated-stream mode, which is connected
      // as soon as it starts (no real handshake to wait for).
      connectionStatus: ConnectionStatus.connected,
    );
  }

  ScannerState copyWith({
    bool? isScanning,
    String? currentWord,
    double? confidence,
    List<String>? sentence,
    int? fps,
    double? latencySeconds,
    bool? isSpeaking,
    int? demoPhase,
    ConnectionStatus? connectionStatus,
  }) {
    return ScannerState(
      isScanning: isScanning ?? this.isScanning,
      currentWord: currentWord ?? this.currentWord,
      confidence: confidence ?? this.confidence,
      sentence: sentence ?? this.sentence,
      fps: fps ?? this.fps,
      latencySeconds: latencySeconds ?? this.latencySeconds,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      demoPhase: demoPhase ?? this.demoPhase,
      connectionStatus: connectionStatus ?? this.connectionStatus,
    );
  }
}
