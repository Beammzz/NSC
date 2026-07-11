import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/scanner/presentation/screens/scanner_screen.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('ScannerScreen renders header, viewport, and translation sheet', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          home: ScannerScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('SignMind AI'), findsOneWidget);
    expect(find.text('สแกนและแปลภาษามือไทย'), findsOneWidget);
    expect(find.text('ผลการแปล'), findsOneWidget);
    expect(find.text('ล้างข้อความ'), findsOneWidget);
    expect(find.text('อ่านออกเสียง'), findsOneWidget);
    expect(find.text('โหมดสนทนา AI'), findsOneWidget);
  });
}
