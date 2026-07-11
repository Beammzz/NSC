class AppSettings {
  final bool isDarkMode;
  final bool showHandSkeleton;
  final bool autoSpeak;
  final bool hapticFeedback;
  final double confidenceThreshold;
  final String cameraResolution;

  /// Base URL of the SignMind backend, e.g. `ws://10.0.2.2:8080`.
  /// The stream service appends `/api/v1/stream`.
  final String serverUrl;

  /// When true, the scanner uses the built-in demo loop instead of
  /// connecting to [serverUrl].
  final bool useSimulatedStream;

  const AppSettings({
    required this.isDarkMode,
    required this.showHandSkeleton,
    required this.autoSpeak,
    required this.hapticFeedback,
    required this.confidenceThreshold,
    required this.cameraResolution,
    required this.serverUrl,
    required this.useSimulatedStream,
  });

  factory AppSettings.initial() {
    return const AppSettings(
      isDarkMode: true,
      showHandSkeleton: true,
      autoSpeak: true,
      hapticFeedback: true,
      confidenceThreshold: 0.85,
      cameraResolution: '720p',
      // Android-emulator loopback to a backend on the host machine.
      serverUrl: 'ws://10.0.2.2:8080',
      useSimulatedStream: true,
    );
  }

  AppSettings copyWith({
    bool? isDarkMode,
    bool? showHandSkeleton,
    bool? autoSpeak,
    bool? hapticFeedback,
    double? confidenceThreshold,
    String? cameraResolution,
    String? serverUrl,
    bool? useSimulatedStream,
  }) {
    return AppSettings(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      showHandSkeleton: showHandSkeleton ?? this.showHandSkeleton,
      autoSpeak: autoSpeak ?? this.autoSpeak,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
      cameraResolution: cameraResolution ?? this.cameraResolution,
      serverUrl: serverUrl ?? this.serverUrl,
      useSimulatedStream: useSimulatedStream ?? this.useSimulatedStream,
    );
  }
}
