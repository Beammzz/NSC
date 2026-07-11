import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/core/services/tts_service.dart';
import 'package:signmind/core/theme/app_theme.dart';
import 'package:signmind/features/conversation/domain/models/conversation_models.dart';
import 'package:signmind/features/conversation/presentation/providers/conversation_provider.dart';

class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key});

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _submitText() {
    final text = _textController.text.trim();
    if (text.isNotEmpty) {
      ref.read(conversationProvider.notifier).sendTextMessage(text);
      _textController.clear();
      _scrollToBottom();
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(conversationProvider);
    final tts = ref.watch(ttsServiceProvider);

    ref.listen<ConversationState>(conversationProvider, (prev, next) {
      if (prev?.messages.length != next.messages.length) {
        _scrollToBottom();
      }
    });

    return Scaffold(
      backgroundColor: AppTheme.darkNavy,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'สนทนา AI',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textLight,
                        ),
                      ),
                      Text(
                        'สะพานเชื่อมการสื่อสารสองทาง',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textMutedDark.withAlpha(200),
                        ),
                      ),
                    ],
                  ),
                  if (state.messages.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: AppTheme.textMutedDark),
                      tooltip: 'ล้างบทสนทนา',
                      onPressed: () {
                        ref.read(conversationProvider.notifier).clearConversation();
                      },
                    ),
                ],
              ),
            ),

            // Message List
            Expanded(
              child: state.messages.isEmpty && !state.isListening
                  ? _buildEmptyPrompt()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: state.messages.length + (state.isProcessing ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == state.messages.length) {
                          return _buildProcessingBubble();
                        }
                        return _buildMessageBubble(state.messages[index], tts);
                      },
                    ),
            ),

            // Live STT transcript banner while hold-to-talk is active
            if (state.isListening) _buildListeningBanner(state.activeTranscript),

            if (state.errorMessage != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),

            // Input Bar (Push-to-Talk Mic + Text Input)
            _buildInputBar(state.isListening),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withAlpha(40),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.forum_outlined,
                size: 36,
                color: AppTheme.successGreen,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'เริ่มการสนทนากับ SignMind AI',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppTheme.textLight,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'กดปุ่มไมค์ค้างไว้เพื่อพูด (STT) หรือพิมพ์ข้อความ\nAI จะตอบกลับเป็นข้อความ เสียง และคำศัพท์ภาษามือ',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textMutedDark.withAlpha(180),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, right: 60),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.borderDark),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.successGreen),
            ),
            SizedBox(width: 10),
            Text(
              'กำลังประมวลผลคำตอบและการเคลื่อนไหว...',
              style: TextStyle(fontSize: 13, color: AppTheme.textLight),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ConversationMessage message, TtsService tts) {
    final isUser = message.sender == MessageSender.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          bottom: 12,
          left: isUser ? 48 : 0,
          right: isUser ? 0 : 48,
        ),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isUser ? AppTheme.primaryAccent : AppTheme.cardDark,
          borderRadius: BorderRadius.circular(18),
          border: isUser ? null : Border.all(color: AppTheme.borderDark),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser ? Icons.person : Icons.smart_toy,
                  size: 16,
                  color: isUser ? AppTheme.textLight : AppTheme.successGreen,
                ),
                const SizedBox(width: 6),
                Text(
                  isUser ? 'คุณ' : 'SignMind AI',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isUser ? AppTheme.textLight : AppTheme.successGreen,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              message.text,
              style: const TextStyle(fontSize: 15, color: AppTheme.textLight, height: 1.3),
            ),
            if (message.signGloss != null && message.signGloss!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.darkNavy.withAlpha(160),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sign_language, size: 14, color: AppTheme.liveDotGreen),
                    const SizedBox(width: 6),
                    Text(
                      'คำศัพท์ภาษามือ: ${message.signGloss}',
                      style: const TextStyle(fontSize: 12, color: AppTheme.liveDotGreen),
                    ),
                  ],
                ),
              ),
            ],
            if (!isUser) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  InkWell(
                    onTap: () => tts.speak(message.text),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            tts.isSpeaking ? Icons.volume_up : Icons.volume_up_outlined,
                            size: 16,
                            color: AppTheme.textMutedDark,
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            'ฟังเสียง',
                            style: TextStyle(fontSize: 11, color: AppTheme.textMutedDark),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildListeningBanner(String activeTranscript) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.successGreen.withAlpha(40),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.successGreen),
      ),
      child: Row(
        children: [
          const Icon(Icons.mic, color: AppTheme.successGreen, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              activeTranscript.isEmpty ? 'กำลังฟัง... พูดข้อความที่ต้องการสื่อสาร' : activeTranscript,
              style: const TextStyle(color: AppTheme.textLight, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(bool isListening) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        border: Border(top: BorderSide(color: AppTheme.borderDark)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              style: const TextStyle(color: AppTheme.textLight),
              onSubmitted: (_) => _submitText(),
              decoration: InputDecoration(
                hintText: 'พิมพ์ข้อความที่ต้องการส่ง...',
                hintStyle: const TextStyle(color: AppTheme.textMutedDark),
                filled: true,
                fillColor: AppTheme.darkNavy,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onLongPressStart: (_) => ref.read(conversationProvider.notifier).startListening(),
            onLongPressEnd: (_) => ref.read(conversationProvider.notifier).stopListeningAndSend(),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isListening ? AppTheme.warningOrange : AppTheme.successGreen,
                shape: BoxShape.circle,
              ),
              child: Icon(
                isListening ? Icons.mic : Icons.mic_none,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _submitText,
            icon: const Icon(Icons.send_rounded, color: AppTheme.liveDotGreen),
          ),
        ],
      ),
    );
  }
}
