import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/core/router/app_router.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  const secureStorage = FlutterSecureStorage();
  final savedPassword = await _migrateSavedPassword(prefs, secureStorage);
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        secureStorageProvider.overrideWithValue(secureStorage),
        savedPasswordProvider.overrideWithValue(savedPassword),
      ],
      child: const SignMindApp(),
    ),
  );
}

/// One-time migration: earlier app versions stored the "remember me"
/// password in plaintext SharedPreferences; move any leftover value into
/// the platform Keychain/Keystore and scrub it from prefs, then return
/// whatever secure storage now holds (possibly still none).
Future<String?> _migrateSavedPassword(
  SharedPreferences prefs,
  FlutterSecureStorage secureStorage,
) async {
  final legacy = prefs.getString(SettingsNotifier.savedPasswordPrefsKeyLegacy);
  if (legacy != null) {
    await secureStorage.write(
      key: SettingsNotifier.savedPasswordSecureKey,
      value: legacy,
    );
    await prefs.remove(SettingsNotifier.savedPasswordPrefsKeyLegacy);
  }
  return secureStorage.read(key: SettingsNotifier.savedPasswordSecureKey);
}

class SignMindApp extends ConsumerWidget {
  const SignMindApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    final settings = ref.watch(settingsProvider);

    return MaterialApp.router(
      title: 'SignMind AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: settings.themeMode,
      routerConfig: router,
    );
  }
}
