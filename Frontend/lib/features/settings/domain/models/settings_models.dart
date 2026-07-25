import 'package:flutter/material.dart';

class AppSettings {
  final ThemeMode themeMode;
  final bool showHandSkeleton;
  final bool autoSpeak;
  final bool hapticFeedback;
  final double confidenceThreshold;
  final String cameraResolution;

  /// When true, debug overlay (FPS, latency, confidence) is shown on the
  /// scanner camera viewport.
  final bool showDebugOverlay;

  /// When true, the dictionary sign avatar is drawn as a cartoon character;
  /// when false it falls back to the raw keypoint skeleton.
  final bool cartoonAvatar;

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
    required this.themeMode,
    required this.showHandSkeleton,
    required this.autoSpeak,
    required this.hapticFeedback,
    required this.confidenceThreshold,
    required this.cameraResolution,
    required this.showDebugOverlay,
    required this.cartoonAvatar,
    required this.serverUrl,
    required this.useSimulatedStream,
    required this.rememberCredentials,
    required this.savedEmail,
    required this.savedPassword,
  });

  bool get isDarkMode => themeMode == ThemeMode.dark;

  factory AppSettings.initial() {
    return const AppSettings(
      themeMode: ThemeMode.system,
      showHandSkeleton: true,
      autoSpeak: true,
      hapticFeedback: true,
      confidenceThreshold: 0.85,
      // 480p, not 720p: CameraX's legacy setTargetResolution matches by aspect
      // ratio first, and on devices whose camera only exposes square output
      // sizes (Galaxy S25 FE front) a 1280x720 target skips 1088x1088 for
      // being too narrow and binds 2992x2992 — 9.7x the pixels, ~80ms/frame
      // just copying and rotating them. A 854x480 target fits 1088x1088.
      cameraResolution: '480p',
      showDebugOverlay: false,
      cartoonAvatar: true,
      // Production server default.
      serverUrl: 'https://signmind.harumi.dev',
      useSimulatedStream: false,
      rememberCredentials: true,
      savedEmail: '',
      savedPassword: '',
    );
  }

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? isDarkMode,
    bool? showHandSkeleton,
    bool? autoSpeak,
    bool? hapticFeedback,
    double? confidenceThreshold,
    String? cameraResolution,
    bool? showDebugOverlay,
    bool? cartoonAvatar,
    String? serverUrl,
    bool? useSimulatedStream,
    bool? rememberCredentials,
    String? savedEmail,
    String? savedPassword,
  }) {
    return AppSettings(
      themeMode: themeMode ??
          (isDarkMode != null
              ? (isDarkMode ? ThemeMode.dark : ThemeMode.light)
              : this.themeMode),
      showHandSkeleton: showHandSkeleton ?? this.showHandSkeleton,
      autoSpeak: autoSpeak ?? this.autoSpeak,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
      cameraResolution: cameraResolution ?? this.cameraResolution,
      showDebugOverlay: showDebugOverlay ?? this.showDebugOverlay,
      cartoonAvatar: cartoonAvatar ?? this.cartoonAvatar,
      serverUrl: serverUrl ?? this.serverUrl,
      useSimulatedStream: useSimulatedStream ?? this.useSimulatedStream,
      rememberCredentials: rememberCredentials ?? this.rememberCredentials,
      savedEmail: savedEmail ?? this.savedEmail,
      savedPassword: savedPassword ?? this.savedPassword,
    );
  }
}


