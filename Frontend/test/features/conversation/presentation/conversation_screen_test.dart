import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/conversation/presentation/screens/conversation_screen.dart';
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

    // Pump past the SimulatedConversationRepository 600ms delay
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Verify AI reply bubble and sign gloss appear
    expect(find.text('SignMind AI'), findsOneWidget);
    expect(find.textContaining('คำศัพท์ภาษามือ:'), findsOneWidget);
  });
}
