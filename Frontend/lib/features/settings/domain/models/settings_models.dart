class AppSettings {
  final bool isDarkMode;
  final bool showHandSkeleton;
  final bool autoSpeak;
  final bool hapticFeedback;
  final double confidenceThreshold;
  final String cameraResolution;

  /// Base URL of the SignMind backend, e.g. `https://signmind.harumi.dev`.
  /// The stream service appends `/api/v1/stream`.
  final String serverUrl;

  /// When true, the scanner uses the built-in demo loop instead of
  /// connecting to [serverUrl].
  final bool useSimulatedStream;

  /// Whether credentials should be remembered on LoginScreen.
  final bool rememberCredentials;

  /// Saved email for LoginScreen pre-fill.
  final String savedEmail;

  /// Saved password for LoginScreen pre-fill.
  final String savedPassword;

  const AppSettings({
    required this.isDarkMode,
    required this.showHandSkeleton,
    required this.autoSpeak,
    required this.hapticFeedback,
    required this.confidenceThreshold,
    required this.cameraResolution,
    required this.serverUrl,
    required this.useSimulatedStream,
    required this.rememberCredentials,
    required this.savedEmail,
    required this.savedPassword,
  });

  factory AppSettings.initial() {
    return const AppSettings(
      isDarkMode: true,
      showHandSkeleton: true,
      autoSpeak: true,
      hapticFeedback: true,
      confidenceThreshold: 0.85,
      cameraResolution: '720p',
      // Production server default.
      serverUrl: 'https://signmind.harumi.dev',
      useSimulatedStream: true,
      rememberCredentials: true,
      savedEmail: '',
      savedPassword: '',
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
    bool? rememberCredentials,
    String? savedEmail,
    String? savedPassword,
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
      rememberCredentials: rememberCredentials ?? this.rememberCredentials,
      savedEmail: savedEmail ?? this.savedEmail,
      savedPassword: savedPassword ?? this.savedPassword,
    );
  }
}

