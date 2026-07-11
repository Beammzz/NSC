import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/settings/domain/models/settings_models.dart';

/// Overridden in main() (and in tests) with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPreferencesProvider must be overridden');
});

class SettingsNotifier extends Notifier<AppSettings> {
  static const _keyDarkMode = 'settings.isDarkMode';
  static const _keyHandSkeleton = 'settings.showHandSkeleton';
  static const _keyAutoSpeak = 'settings.autoSpeak';
  static const _keyHaptic = 'settings.hapticFeedback';
  static const _keyConfidence = 'settings.confidenceThreshold';
  static const _keyResolution = 'settings.cameraResolution';
  static const _keyServerUrl = 'settings.serverUrl';
  static const _keySimulatedStream = 'settings.useSimulatedStream';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final initial = AppSettings.initial();
    return AppSettings(
      isDarkMode: prefs.getBool(_keyDarkMode) ?? initial.isDarkMode,
      showHandSkeleton:
          prefs.getBool(_keyHandSkeleton) ?? initial.showHandSkeleton,
      autoSpeak: prefs.getBool(_keyAutoSpeak) ?? initial.autoSpeak,
      hapticFeedback: prefs.getBool(_keyHaptic) ?? initial.hapticFeedback,
      confidenceThreshold:
          prefs.getDouble(_keyConfidence) ?? initial.confidenceThreshold,
      cameraResolution:
          prefs.getString(_keyResolution) ?? initial.cameraResolution,
      serverUrl: prefs.getString(_keyServerUrl) ?? initial.serverUrl,
      useSimulatedStream:
          prefs.getBool(_keySimulatedStream) ?? initial.useSimulatedStream,
    );
  }

  void toggleDarkMode(bool value) {
    state = state.copyWith(isDarkMode: value);
    _prefs.setBool(_keyDarkMode, value);
  }

  void toggleHandSkeleton(bool value) {
    state = state.copyWith(showHandSkeleton: value);
    _prefs.setBool(_keyHandSkeleton, value);
  }

  void toggleAutoSpeak(bool value) {
    state = state.copyWith(autoSpeak: value);
    _prefs.setBool(_keyAutoSpeak, value);
  }

  void toggleHapticFeedback(bool value) {
    state = state.copyWith(hapticFeedback: value);
    _prefs.setBool(_keyHaptic, value);
  }

  void setConfidenceThreshold(double value) {
    state = state.copyWith(confidenceThreshold: value);
    _prefs.setDouble(_keyConfidence, value);
  }

  void setCameraResolution(String value) {
    state = state.copyWith(cameraResolution: value);
    _prefs.setString(_keyResolution, value);
  }

  void setServerUrl(String value) {
    state = state.copyWith(serverUrl: value.trim());
    _prefs.setString(_keyServerUrl, value.trim());
  }

  void toggleSimulatedStream(bool value) {
    state = state.copyWith(useSimulatedStream: value);
    _prefs.setBool(_keySimulatedStream, value);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
