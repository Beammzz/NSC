import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';
import 'package:signmind/main.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('SignMindApp initializes router and displays bottom navigation tabs', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const SignMindApp(),
    ));
    await tester.pump();

    expect(find.text('SignMind AI'), findsOneWidget);
    expect(find.text('สแกน'), findsOneWidget);
    expect(find.text('ครูฝึก AI'), findsOneWidget);
    expect(find.text('สนทนา'), findsOneWidget);
    expect(find.text('เรียนรู้'), findsOneWidget);
    expect(find.text('ตั้งค่า'), findsOneWidget);
  });
}
