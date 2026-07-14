import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/conversation/presentation/screens/conversation_screen.dart';
import 'package:signmind/features/learn/presentation/widgets/sign_avatar.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

Future<ProviderContainer> makeContainer() async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('ConversationScreen renders empty prompt and sends text message', (tester) async {
    final container = await makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ConversationScreen(),
        ),
      ),
    );

    expect(find.text('สนทนา AI'), findsOneWidget);
    expect(find.text('เริ่มการสนทนากับ SignMind AI'), findsOneWidget);

    // Type text and submit
    final textField = find.byType(TextField);
    expect(textField, findsOneWidget);

    await tester.enterText(textField, 'สวัสดี');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Verify user bubble appears immediately
    expect(find.text('สวัสดี'), findsOneWidget);

    // Advance fake time past the repository's 600ms delay and the follow-on
    // TTS timer. The AI bubble's SignAvatar animates forever, so we step time
    // with pump(duration) instead of pumpAndSettle (which would never settle).
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    // The AI reply now leads with the signing avatar; the transcript and gloss
    // stay hidden until the user reveals them (Phase 1 conversation UX).
    expect(find.text('SignMind AI'), findsOneWidget);
    expect(find.byType(SignAvatar), findsOneWidget);
    expect(find.textContaining('คำศัพท์ภาษามือ:'), findsNothing);

    // Revealing the transcript surfaces the sign gloss.
    await tester.tap(find.text('แสดงข้อความ'));
    await tester.pump();
    expect(find.textContaining('คำศัพท์ภาษามือ:'), findsOneWidget);
  });
}
