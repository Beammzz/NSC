import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/settings/domain/models/settings_models.dart';

/// Overridden in main() (and in tests) with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('sharedPreferencesProvider must be overridden');
});

/// The Keychain/Keystore-backed store for the "remember me" password —
/// SharedPreferences persists as plaintext XML/plist, unsuitable for a
/// credential (see SettingsNotifier.savedPasswordSecureKey).
final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(),
);

/// The saved password loaded from secure storage at startup (secure reads
/// are async; SettingsNotifier.build() is not) — overridden in main() (and
/// in tests) with the loaded value, defaulting to none.
final savedPasswordProvider = Provider<String?>((ref) => null);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _keyThemeMode = 'settings.themeMode';
  static const _keyDarkMode = 'settings.isDarkMode';
  static const _keyHandSkeleton = 'settings.showHandSkeleton';
  static const _keyAutoSpeak = 'settings.autoSpeak';
  static const _keyHaptic = 'settings.hapticFeedback';
  static const _keyConfidence = 'settings.confidenceThreshold';
  static const _keyResolution = 'settings.cameraResolution';
  static const _keyDebugOverlay = 'settings.showDebugOverlay';
  static const _keyCartoonAvatar = 'settings.cartoonAvatar';
  static const _keyServerUrl = 'settings.serverUrl';
  static const _keySimulatedStream = 'settings.useSimulatedStream';
  static const _keyRememberCredentials = 'settings.rememberCredentials';
  static const _keySavedEmail = 'settings.savedEmail';

  /// Pre-fix key: earlier app versions stored the saved password here, in
  /// plaintext. main()'s startup migration moves any leftover value into
  /// secure storage and deletes it from here.
  static const savedPasswordPrefsKeyLegacy = 'settings.savedPassword';

  /// Secure-storage key for the saved password.
  static const savedPasswordSecureKey = 'settings.savedPassword.secure';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);
  FlutterSecureStorage get _secureStorage => ref.read(secureStorageProvider);

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
      cartoonAvatar:
          prefs.getBool(_keyCartoonAvatar) ?? initial.cartoonAvatar,
      serverUrl: prefs.getString(_keyServerUrl) ?? initial.serverUrl,
      useSimulatedStream:
          prefs.getBool(_keySimulatedStream) ?? initial.useSimulatedStream,
      rememberCredentials:
          prefs.getBool(_keyRememberCredentials) ?? initial.rememberCredentials,
      savedEmail: prefs.getString(_keySavedEmail) ?? initial.savedEmail,
      savedPassword: ref.watch(savedPasswordProvider) ?? initial.savedPassword,
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

  void toggleCartoonAvatar(bool value) {
    state = state.copyWith(cartoonAvatar: value);
    _prefs.setBool(_keyCartoonAvatar, value);
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
      unawaited(_secureStorage.delete(key: savedPasswordSecureKey));
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
      unawaited(
        _secureStorage.write(key: savedPasswordSecureKey, value: password),
      );
    } else {
      _prefs.remove(_keySavedEmail);
      unawaited(_secureStorage.delete(key: savedPasswordSecureKey));
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
