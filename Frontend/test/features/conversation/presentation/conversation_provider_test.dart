import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/conversation/domain/models/conversation_models.dart';
import 'package:signmind/features/conversation/presentation/providers/conversation_provider.dart';
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

  group('ConversationNotifier Unit Tests', () {
    test('initial state has empty messages and not listening', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      final state = container.read(conversationProvider);
      expect(state.messages.isEmpty, true);
      expect(state.isListening, false);
      expect(state.isProcessing, false);
    });

    test('sendTextMessage adds user message and receives AI reply with gloss', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      await container.read(conversationProvider.notifier).sendTextMessage('โรงพยาบาลอยู่ที่ไหน');

      final state = container.read(conversationProvider);
      expect(state.messages.length, 2);
      expect(state.messages.first.sender, MessageSender.user);
      expect(state.messages.first.text, 'โรงพยาบาลอยู่ที่ไหน');
      expect(state.messages.last.sender, MessageSender.ai);
      expect(state.messages.last.signGloss!.contains('โรงพยาบาล'), true);
      expect(state.isProcessing, false);
    });

    test('clearConversation resets back to initial state', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      await container.read(conversationProvider.notifier).sendTextMessage('สวัสดี');
      expect(container.read(conversationProvider).messages.isNotEmpty, true);

      container.read(conversationProvider.notifier).clearConversation();
      expect(container.read(conversationProvider).messages.isEmpty, true);
    });
  });
}
