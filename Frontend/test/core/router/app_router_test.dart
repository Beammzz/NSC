import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/core/widgets/main_scaffold.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';
import 'package:signmind/main.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets(
      'SignMindApp initializes at /login, enters demo mode to /landing, and navigates to main tabs on CTA tap',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const SignMindApp(),
    ));
    await tester.pumpAndSettle();

    // Verify initial login page is shown with serverModeDropdown
    expect(find.byKey(const Key('serverModeDropdown')), findsOneWidget);

    // Select demo mode from the dropdown
    await tester.tap(find.byKey(const Key('serverModeDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('โหมดสาธิตออฟไลน์ (Demo Offline)').last);
    await tester.pumpAndSettle();

    // Verify enterDemoModeButton is shown and tap to proceed to /landing
    expect(find.byKey(const Key('enterDemoModeButton')), findsOneWidget);
    await tester.tap(find.byKey(const Key('enterDemoModeButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Verify landing page shows feature introduction registry
    expect(find.text('SignMind AI'), findsWidgets);
    expect(find.text('ศูนย์แนะนำฟีเจอร์ระบบ'), findsOneWidget);

    // Tap CTA to enter main app (/scanner)
    await tester.tap(find.byKey(const Key('enterMainAppButtonTop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Verify main app scaffold is displayed
    expect(find.byType(MainScaffold), findsOneWidget);
    expect(find.text('สแกน'), findsWidgets);
    expect(find.text('เรียนรู้'), findsWidgets);
    expect(find.text('ตั้งค่า'), findsWidgets);
  });
}
