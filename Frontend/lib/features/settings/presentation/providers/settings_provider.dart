import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/settings/domain/models/settings_models.dart';

/// Overridden in main() (and in tests) with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPreferencesProvider must be overridden');
});

class SettingsNotifier extends Notifier<AppSettings> {
  static const _keyThemeMode = 'settings.themeMode';
  static const _keyDarkMode = 'settings.isDarkMode';
  static const _keyHandSkeleton = 'settings.showHandSkeleton';
  static const _keyAutoSpeak = 'settings.autoSpeak';
  static const _keyHaptic = 'settings.hapticFeedback';
  static const _keyConfidence = 'settings.confidenceThreshold';
  static const _keyResolution = 'settings.cameraResolution';
  static const _keyDebugOverlay = 'settings.showDebugOverlay';
  static const _keyServerUrl = 'settings.serverUrl';
  static const _keySimulatedStream = 'settings.useSimulatedStream';
  static const _keyRememberCredentials = 'settings.rememberCredentials';
  static const _keySavedEmail = 'settings.savedEmail';
  static const _keySavedPassword = 'settings.savedPassword';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final initial = AppSettings.initial();

    ThemeMode themeMode = initial.themeMode;
    final storedThemeStr = prefs.getString(_keyThemeMode);
    if (storedThemeStr != null) {
      themeMode = switch (storedThemeStr) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      };
    } else if (prefs.containsKey(_keyDarkMode)) {
      final oldDark = prefs.getBool(_keyDarkMode) ?? true;
      themeMode = oldDark ? ThemeMode.dark : ThemeMode.light;
    }

    return AppSettings(
      themeMode: themeMode,
      showHandSkeleton:
          prefs.getBool(_keyHandSkeleton) ?? initial.showHandSkeleton,
      autoSpeak: prefs.getBool(_keyAutoSpeak) ?? initial.autoSpeak,
      hapticFeedback: prefs.getBool(_keyHaptic) ?? initial.hapticFeedback,
      confidenceThreshold:
          prefs.getDouble(_keyConfidence) ?? initial.confidenceThreshold,
      cameraResolution:
          prefs.getString(_keyResolution) ?? initial.cameraResolution,
      showDebugOverlay:
          prefs.getBool(_keyDebugOverlay) ?? initial.showDebugOverlay,
      serverUrl: prefs.getString(_keyServerUrl) ?? initial.serverUrl,
      useSimulatedStream:
          prefs.getBool(_keySimulatedStream) ?? initial.useSimulatedStream,
      rememberCredentials:
          prefs.getBool(_keyRememberCredentials) ?? initial.rememberCredentials,
      savedEmail: prefs.getString(_keySavedEmail) ?? initial.savedEmail,
      savedPassword: prefs.getString(_keySavedPassword) ?? initial.savedPassword,
    );
  }

  void setThemeMode(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    final modeStr = switch (mode) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    };
    _prefs.setString(_keyThemeMode, modeStr);
    _prefs.setBool(_keyDarkMode, mode == ThemeMode.dark);
  }

  void toggleDarkMode(bool value) {
    setThemeMode(value ? ThemeMode.dark : ThemeMode.light);
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

  void toggleDebugOverlay(bool value) {
    state = state.copyWith(showDebugOverlay: value);
    _prefs.setBool(_keyDebugOverlay, value);
  }

  void setServerUrl(String value) {
    state = state.copyWith(serverUrl: value.trim());
    _prefs.setString(_keyServerUrl, value.trim());
  }

  void toggleSimulatedStream(bool value) {
    state = state.copyWith(useSimulatedStream: value);
    _prefs.setBool(_keySimulatedStream, value);
  }

  void setRememberCredentials(bool value) {
    state = state.copyWith(rememberCredentials: value);
    _prefs.setBool(_keyRememberCredentials, value);
    if (!value) {
      state = state.copyWith(savedEmail: '', savedPassword: '');
      _prefs.remove(_keySavedEmail);
      _prefs.remove(_keySavedPassword);
    }
  }

  void saveLoginCredentials(String email, String password, bool remember) {
    state = state.copyWith(
      rememberCredentials: remember,
      savedEmail: remember ? email.trim() : '',
      savedPassword: remember ? password : '',
    );
    _prefs.setBool(_keyRememberCredentials, remember);
    if (remember) {
      _prefs.setString(_keySavedEmail, email.trim());
      _prefs.setString(_keySavedPassword, password);
    } else {
      _prefs.remove(_keySavedEmail);
      _prefs.remove(_keySavedPassword);
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
