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

    // The server section is below the fold in the test viewport.
    final demoModeTile = find.text('โหมดจำลอง (Demo Mode)');
    await tester.ensureVisible(demoModeTile);
    await tester.pumpAndSettle();

    // Demo mode on -> URL field disabled.
    final urlField = find.byKey(const Key('serverUrlField'));
    expect(urlField, findsOneWidget);
    expect(tester.widget<TextFormField>(urlField).enabled, isFalse);

    // Turn demo mode off, then edit the URL.
    await tester.tap(demoModeTile);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).useSimulatedStream, isFalse);

    await tester.ensureVisible(urlField);
    await tester.enterText(urlField, 'ws://192.168.1.50:9000');
    // Typing alone must not commit or reconnect (that used to fire a
    // connection attempt on every keystroke) - only the Connect button does.
    expect(container.read(settingsProvider).serverUrl, 'ws://10.0.2.2:8080');

    final connectButton = find.byKey(const Key('connectServerButton'));
    await tester.ensureVisible(connectButton);
    await tester.tap(connectButton);
    await tester.pumpAndSettle();
    expect(
      container.read(settingsProvider).serverUrl,
      'ws://192.168.1.50:9000',
    );

    // Persisted: a fresh container over the same prefs sees the values.
    final prefs = await SharedPreferences.getInstance();
    final second = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(second.dispose);
    expect(second.read(settingsProvider).serverUrl, 'ws://192.168.1.50:9000');
    expect(second.read(settingsProvider).useSimulatedStream, isFalse);
  });
}
