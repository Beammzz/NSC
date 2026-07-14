import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/conversation/domain/models/conversation_models.dart';
import 'package:signmind/features/conversation/presentation/providers/conversation_provider.dart';
import 'package:signmind/features/conversation/presentation/screens/conversation_screen.dart';
import 'package:signmind/features/learn/presentation/widgets/sign_avatar.dart';

/// Seeds the conversation with a fixed state so the screen renders one AI
/// reply without touching STT/TTS platform channels. build() is overridden to
/// skip the real notifier's sttServiceProvider watch.
class _FakeConversationNotifier extends ConversationNotifier {
  _FakeConversationNotifier(this._seed);

  final ConversationState _seed;

  @override
  ConversationState build() => _seed;
}

void main() {
  const replyText = 'สวัสดีค่ะ ยินดีที่ได้พบคุณค่ะ';
  const gloss = 'สวัสดี พบ ยินดี';

  ConversationState seedWithAiReply() {
    final aiMessage = ConversationMessage(
      id: 'ai-1',
      sender: MessageSender.ai,
      text: replyText,
      signGloss: gloss,
      timestamp: DateTime(2026, 7, 13),
    );
    return ConversationState(
      messages: [aiMessage],
      isListening: false,
      isProcessing: false,
      activeTranscript: '',
    );
  }

  Future<void> pumpScreen(WidgetTester tester, ConversationState seed) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationProvider.overrideWith(
            () => _FakeConversationNotifier(seed),
          ),
        ],
        child: const MaterialApp(home: ConversationScreen()),
      ),
    );
    // SignAvatar animates forever (repeat()), so never pumpAndSettle here.
    await tester.pump();
  }

  testWidgets(
    'AI reply shows the sign avatar with the transcript hidden by default',
    (tester) async {
      await pumpScreen(tester, seedWithAiReply());

      // The avatar signing the reply is present…
      expect(find.byType(SignAvatar), findsOneWidget);
      // …but the text transcript and gloss stay hidden until revealed.
      expect(find.text(replyText), findsNothing);
      expect(find.textContaining('คำศัพท์ภาษามือ'), findsNothing);
      // The reveal affordance is offered.
      expect(find.text('แสดงข้อความ'), findsOneWidget);
    },
  );

  testWidgets('tapping the reveal toggle shows the transcript and gloss',
      (tester) async {
    await pumpScreen(tester, seedWithAiReply());

    await tester.tap(find.text('แสดงข้อความ'));
    await tester.pump();

    expect(find.text(replyText), findsOneWidget);
    expect(find.textContaining('คำศัพท์ภาษามือ'), findsOneWidget);
    // Toggle now offers to hide it again.
    expect(find.text('ซ่อนข้อความ'), findsOneWidget);
    expect(find.text('แสดงข้อความ'), findsNothing);
  });
}
