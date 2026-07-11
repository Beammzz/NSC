import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/landing/presentation/screens/landing_screen.dart';

void main() {
  testWidgets('LandingScreen renders hero section and all feature cards',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LandingScreen(),
      ),
    );

    // Verify Brand title & Subtitle
    expect(find.text('SignMind AI'), findsOneWidget);
    expect(find.text('ศูนย์แนะนำฟีเจอร์ระบบ'), findsOneWidget);

    // Verify Hero CTA buttons
    expect(find.byKey(const Key('enterMainAppButtonTop')), findsOneWidget);
    expect(find.byKey(const Key('enterMainAppHeroButton')), findsOneWidget);

    // Verify all 5 feature introduction cards exist
    expect(find.text('สแกนแปลภาษามือ'), findsOneWidget);
    expect(find.text('ครูฝึก AI'), findsOneWidget);
    expect(find.text('สนทนาไร้รอยต่อ'), findsOneWidget);
    expect(find.text('คลังคำศัพท์'), findsOneWidget);
    expect(find.text('ตั้งค่าระบบและ AI Tuning'), findsOneWidget);
  });
}
