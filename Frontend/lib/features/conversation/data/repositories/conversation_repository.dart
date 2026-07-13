import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/conversation/domain/models/conversation_models.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

abstract class ConversationRepository {
  Future<ConversationMessage> sendMessage(String text);
}

class SimulatedConversationRepository implements ConversationRepository {
  @override
  Future<ConversationMessage> sendMessage(String text) async {
    await Future.delayed(const Duration(milliseconds: 600));

    String replyText = 'สวัสดีค่ะ ยินดีที่ได้พบคุณค่ะ';
    String gloss = 'สวัสดี พบ ยินดี';

    if (text.contains('โรงพยาบาล')) {
      replyText = 'โรงพยาบาลอยู่ตรงไปทางขวามือค่ะ';
      gloss = 'โรงพยาบาล ตรง ขวา';
    } else if (text.contains('ขอบคุณ')) {
      replyText = 'ยินดีเสมอค่ะ มีอะไรให้ช่วยเหลือบอกได้เลยนะคะ';
      gloss = 'ยินดี ช่วยเหลือ';
    }

    final sampleFrame = [
      const LandmarkPoint(0.5, 0.5),
      const LandmarkPoint(0.4, 0.4),
    ];

    return ConversationMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      sender: MessageSender.ai,
      text: replyText,
      signGloss: gloss,
      keypointTransitions: [sampleFrame],
      timestamp: DateTime.now(),
    );
  }
}

class HttpConversationRepository implements ConversationRepository {
  final String baseUrl;
  final String? accessToken;

  HttpConversationRepository({required this.baseUrl, this.accessToken});

  @override
  Future<ConversationMessage> sendMessage(String text) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl/api/v1/conversation');
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (accessToken != null) {
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
      }
      request.write(jsonEncode({'message': text, 'locale': 'th-TH'}));

      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('Server error: ${response.statusCode}');
      }

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final replyText = data['reply_text'] as String? ?? '';
      final gloss = data['reply_sign_gloss'] as String?;

      List<List<LandmarkPoint>>? transitions;
      if (data['keypoint_transitions'] is List) {
        final rawList = data['keypoint_transitions'] as List;
        transitions = rawList.map((frame) {
          if (frame is List) {
            return frame.map((pt) {
              if (pt is Map) {
                return LandmarkPoint(
                  (pt['x'] as num?)?.toDouble() ?? 0.0,
                  (pt['y'] as num?)?.toDouble() ?? 0.0,
                  (pt['z'] as num?)?.toDouble() ?? 0.0,
                );
              }
              return const LandmarkPoint(0.0, 0.0);
            }).toList();
          }
          return <LandmarkPoint>[];
        }).toList();
      }

      return ConversationMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        sender: MessageSender.ai,
        text: replyText,
        signGloss: gloss,
        keypointTransitions: transitions,
        timestamp: DateTime.now(),
      );
    } finally {
      client.close();
    }
  }
}

final conversationRepositoryProvider = Provider<ConversationRepository>((ref) {
  final (useSimulated, serverUrl) = ref.watch(
    settingsProvider.select((s) => (s.useSimulatedStream, s.serverUrl)),
  );
  if (useSimulated) {
    return SimulatedConversationRepository();
  }
  final accessToken =
      ref.watch(authProvider.select((s) => s.accessToken));
  return HttpConversationRepository(
    baseUrl: serverUrl.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://'),
    accessToken: accessToken,
  );
});
