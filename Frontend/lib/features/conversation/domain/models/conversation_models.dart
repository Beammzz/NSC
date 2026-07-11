import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

enum MessageSender { user, ai }

class ConversationMessage {
  final String id;
  final MessageSender sender;
  final String text;
  final String? signGloss;
  final List<List<LandmarkPoint>>? keypointTransitions;
  final DateTime timestamp;

  const ConversationMessage({
    required this.id,
    required this.sender,
    required this.text,
    this.signGloss,
    this.keypointTransitions,
    required this.timestamp,
  });
}

class ConversationState {
  final List<ConversationMessage> messages;
  final bool isListening;
  final bool isProcessing;
  final String activeTranscript;
  final String? errorMessage;

  const ConversationState({
    required this.messages,
    required this.isListening,
    required this.isProcessing,
    required this.activeTranscript,
    this.errorMessage,
  });

  factory ConversationState.initial() {
    return const ConversationState(
      messages: [],
      isListening: false,
      isProcessing: false,
      activeTranscript: '',
      errorMessage: null,
    );
  }

  ConversationState copyWith({
    List<ConversationMessage>? messages,
    bool? isListening,
    bool? isProcessing,
    String? activeTranscript,
    String? errorMessage,
  }) {
    return ConversationState(
      messages: messages ?? this.messages,
      isListening: isListening ?? this.isListening,
      isProcessing: isProcessing ?? this.isProcessing,
      activeTranscript: activeTranscript ?? this.activeTranscript,
      errorMessage: errorMessage,
    );
  }
}
