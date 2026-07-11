import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/core/services/stt_service.dart';
import 'package:signmind/core/services/tts_service.dart';
import 'package:signmind/features/conversation/data/repositories/conversation_repository.dart';
import 'package:signmind/features/conversation/domain/models/conversation_models.dart';

class ConversationNotifier extends Notifier<ConversationState> {
  StreamSubscription<bool>? _sttStatusSub;

  @override
  ConversationState build() {
    final sttService = ref.watch(sttServiceProvider);

    _sttStatusSub?.cancel();
    _sttStatusSub = sttService.isListeningStream.listen((listening) {
      state = state.copyWith(isListening: listening);
    });

    ref.onDispose(() {
      _sttStatusSub?.cancel();
    });

    return ConversationState.initial();
  }

  Future<void> startListening() async {
    final sttService = ref.read(sttServiceProvider);
    state = state.copyWith(isListening: true, activeTranscript: '', errorMessage: null);
    await sttService.startListening(
      onResult: (text, confidence) {
        state = state.copyWith(activeTranscript: text);
      },
    );
  }

  Future<void> stopListeningAndSend() async {
    final sttService = ref.read(sttServiceProvider);
    state = state.copyWith(isListening: false);
    await sttService.stopListening();

    final text = state.activeTranscript.trim();
    if (text.isNotEmpty) {
      await sendTextMessage(text);
    }
  }

  Future<void> sendTextMessage(String text) async {
    if (text.trim().isEmpty) return;

    final userMsg = ConversationMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      sender: MessageSender.user,
      text: text.trim(),
      timestamp: DateTime.now(),
    );

    state = state.copyWith(
      messages: [...state.messages, userMsg],
      activeTranscript: '',
      isProcessing: true,
      errorMessage: null,
    );

    try {
      final repo = ref.read(conversationRepositoryProvider);
      final aiMsg = await repo.sendMessage(text.trim());

      state = state.copyWith(
        messages: [...state.messages, aiMsg],
        isProcessing: false,
      );

      final ttsService = ref.read(ttsServiceProvider);
      await ttsService.speak(aiMsg.text);
    } catch (e) {
      state = state.copyWith(
        isProcessing: false,
        errorMessage: 'ไม่สามารถเชื่อมต่อเซิร์ฟเวอร์ได้ ลองใหม่อีกครั้ง',
      );
    }
  }

  void clearConversation() {
    state = ConversationState.initial();
  }
}

final conversationProvider =
    NotifierProvider<ConversationNotifier, ConversationState>(ConversationNotifier.new);
