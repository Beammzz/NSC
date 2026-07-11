import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';
import 'package:signmind/features/settings/presentation/screens/settings_screen.dart';

Future<ProviderContainer> makeContainer() async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('SettingsScreen renders headers, options, and responds to toggles', (tester) async {
    final container = await makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SettingsScreen(),
        ),
      ),
    );

    // Verify main header and section titles
    expect(find.text('การตั้งค่า'), findsOneWidget);
    expect(find.text('การแสดงผลและธีม (Display & Theme)'), findsOneWidget);
    expect(find.text('การตรวจจับและกล้อง (Camera & Scanner)'), findsOneWidget);
    expect(find.text('เสียงและการสั่นแจ้งเตือน (Audio & Haptics)'), findsOneWidget);
    expect(find.text('เกี่ยวกับแอปพลิเคชัน (About System)'), findsOneWidget);

    // Verify system version and connection status
    expect(find.text('SignMind AI v1.0.0'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);

    // Verify default state in Riverpod provider
    expect(container.read(settingsProvider).isDarkMode, isTrue);
    expect(container.read(settingsProvider).autoSpeak, isTrue);

    // Toggle Auto TTS switch
    final autoSpeakFinder = find.text('อ่านออกเสียงอัตโนมัติ (Auto TTS)');
    expect(autoSpeakFinder, findsOneWidget);
    await tester.tap(autoSpeakFinder);
    await tester.pumpAndSettle();

    // Verify state updated in Riverpod provider
    expect(container.read(settingsProvider).autoSpeak, isFalse);
  });

  testWidgets('Server URL setting is editable when demo mode is off and persists', (tester) async {
    final container = await makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    expect(find.text('เซิร์ฟเวอร์ (Server Connection)'), findsOneWidget);
    expect(container.read(settingsProvider).useSimulatedStream, isTrue);

    // Verify that the connected server info and changeServerLoginButton are displayed.
    final changeServerButton = find.byKey(
      const Key('changeServerLoginButton'),
    );
    await tester.ensureVisible(changeServerButton);
    expect(changeServerButton, findsOneWidget);
    expect(find.text('โหมดสาธิตออฟไลน์ (Simulated Mode)'), findsOneWidget);
  });
}
