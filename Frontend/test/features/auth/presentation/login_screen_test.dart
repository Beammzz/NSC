import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/auth/presentation/screens/login_screen.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('LoginScreen renders brand header, Server IP field, and switches modes',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('SignMind AI'), findsWidgets);
    expect(find.text('ตั้งค่าเซิร์ฟเวอร์ (Server IP)'), findsOneWidget);

    // In demo mode by default
    expect(find.byKey(const Key('enterDemoModeButton')), findsOneWidget);

    // Switch off demo mode
    await tester.tap(find.text('โหมดสาธิตออฟไลน์'));
    await tester.pump();

    // Verify Server IP text form field is visible and editable
    final urlField = find.byKey(const Key('loginServerUrlField'));
    expect(urlField, findsOneWidget);
    expect(find.text('https://signmind.harumi.dev'), findsWidgets);
    await tester.enterText(urlField, 'ws://192.168.1.100:8080');
    expect(find.text('ws://192.168.1.100:8080'), findsOneWidget);
  });

  testWidgets('enterSimulatedGuestMode authenticates user and updates state',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    expect(container.read(authProvider).isAuthenticated, isFalse);
    container.read(authProvider.notifier).enterSimulatedGuestMode();
    expect(container.read(authProvider).isAuthenticated, isTrue);
    expect(container.read(authProvider).isSimulatedGuest, isTrue);
  });

  testWidgets('LoginScreen renders remember credentials checkbox and pre-fills saved credentials',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'settings.useSimulatedStream': false,
      'settings.rememberCredentials': true,
      'settings.savedEmail': 'testuser@signmind.local',
      'settings.savedPassword': 'secretpassword',
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();

    // Verify checkbox exists and is checked
    final checkbox = tester.widget<Checkbox>(
      find.byKey(const Key('rememberCredentialsCheckbox')),
    );
    expect(checkbox.value, isTrue);

    // Verify email and password text fields are pre-populated with saved credentials
    expect(find.text('testuser@signmind.local'), findsOneWidget);
    expect(find.text('secretpassword'), findsOneWidget);
  });
}

