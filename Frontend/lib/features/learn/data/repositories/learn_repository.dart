import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

/// Data source for the Learn tab (topics, dictionary, progress). The real
/// implementation talks to `/api/v1/learn/*`; the simulated one serves a
/// local subset so demo mode works fully offline (matching the demo-mode
/// contract of the stream and conversation features).
abstract class LearnRepository {
  Future<List<LearnTopic>> fetchTopics();
  Future<List<DictionarySign>> fetchDictionary();
  Future<DictionarySign> fetchSignDetail(String word);
  Future<List<LearnProgress>> fetchProgress();
  Future<LearnProgress> recordAttempt(int exerciseId, double confidence);
}

/// Offline demo content: mirrors the backend seed's starter topics
/// (Backend/internal/learn/seed.go) closely enough to demo the flow.
class SimulatedLearnRepository implements LearnRepository {
  final Map<int, LearnProgress> _progress = {};

  static const _topics = [
    LearnTopic(
      id: 1,
      slug: 'basics',
      title: 'คำพื้นฐานและทักทาย',
      icon: '👋',
      sortOrder: 0,
      exercises: [
        LearnExercise(id: 1, topicId: 1, word: 'ขอโทษ', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 2, topicId: 1, word: 'บ๊ายบาย', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 3, topicId: 1, word: 'ดี', sortOrder: 2, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 2,
      slug: 'people',
      title: 'ผู้คนและครอบครัว',
      icon: '👪',
      sortOrder: 1,
      exercises: [
        LearnExercise(id: 4, topicId: 2, word: 'ฉัน', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 5, topicId: 2, word: 'พ่อ', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 6, topicId: 2, word: 'แม่', sortOrder: 2, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 3,
      slug: 'food',
      title: 'อาหารและเครื่องดื่ม',
      icon: '🍚',
      sortOrder: 2,
      exercises: [
        LearnExercise(id: 7, topicId: 3, word: 'กิน', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 8, topicId: 3, word: 'ข้าว', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 9, topicId: 3, word: 'น้ำ', sortOrder: 2, passConfidence: 0.8),
      ],
    ),
  ];

  static const _signs = [
    DictionarySign(word: 'ขอโทษ', category: 'คำพื้นฐาน', hasAnimation: false),
    DictionarySign(word: 'บ๊ายบาย', category: 'คำพื้นฐาน', hasAnimation: false),
    DictionarySign(word: 'ดี', category: 'คำพื้นฐาน', hasAnimation: false),
    DictionarySign(word: 'ฉัน', category: 'ผู้คนและครอบครัว', hasAnimation: false),
    DictionarySign(word: 'พ่อ', category: 'ผู้คนและครอบครัว', hasAnimation: false),
    DictionarySign(word: 'แม่', category: 'ผู้คนและครอบครัว', hasAnimation: false),
    DictionarySign(word: 'กิน', category: 'อาหารและเครื่องดื่ม', hasAnimation: false),
    DictionarySign(word: 'ข้าว', category: 'อาหารและเครื่องดื่ม', hasAnimation: false),
    DictionarySign(word: 'น้ำ', category: 'อาหารและเครื่องดื่ม', hasAnimation: false),
    DictionarySign(word: 'กาแฟ', category: 'อาหารและเครื่องดื่ม', hasAnimation: false),
    DictionarySign(word: 'สีแดง', category: 'สี', hasAnimation: false),
    DictionarySign(word: 'สีเขียว', category: 'สี', hasAnimation: false),
  ];

  @override
  Future<List<LearnTopic>> fetchTopics() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return _topics;
  }

  @override
  Future<List<DictionarySign>> fetchDictionary() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return _signs;
  }

  @override
  Future<DictionarySign> fetchSignDetail(String word) async {
    await Future.delayed(const Duration(milliseconds: 150));
    return _signs.firstWhere(
      (s) => s.word == word,
      orElse: () => DictionarySign(word: word, category: '', hasAnimation: false),
    );
  }

  @override
  Future<List<LearnProgress>> fetchProgress() async {
    return _progress.values.toList();
  }

  @override
  Future<LearnProgress> recordAttempt(int exerciseId, double confidence) async {
    final exercise = _topics
        .expand((t) => t.exercises)
        .firstWhere((e) => e.id == exerciseId,
            orElse: () => const LearnExercise(
                id: 0, topicId: 0, word: '', sortOrder: 0, passConfidence: 0.8));
    final previous = _progress[exerciseId];
    final best = previous == null || confidence > previous.bestConfidence
        ? confidence
        : previous.bestConfidence;
    final passed =
        (previous?.passed ?? false) || confidence >= exercise.passConfidence;
    final row = LearnProgress(
        exerciseId: exerciseId, bestConfidence: best, passed: passed);
    _progress[exerciseId] = row;
    return row;
  }
}

/// Real client for `/api/v1/learn/*` with the JWT on every request.
class HttpLearnRepository implements LearnRepository {
  final String baseUrl;
  final String? accessToken;

  HttpLearnRepository({required this.baseUrl, this.accessToken});

  Future<dynamic> _request(String method, String path, {Object? body}) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl$path');
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (accessToken != null) {
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
      }
      if (body != null) {
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw Exception('Server error: ${response.statusCode}');
      }
      return jsonDecode(text);
    } finally {
      client.close();
    }
  }

  @override
  Future<List<LearnTopic>> fetchTopics() async {
    final data = await _request('GET', '/api/v1/learn/topics');
    final raw = data is Map<String, dynamic> ? data['topics'] : null;
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(LearnTopic.fromJson)
        .toList();
  }

  @override
  Future<List<DictionarySign>> fetchDictionary() async {
    final data = await _request('GET', '/api/v1/learn/dictionary');
    final raw = data is Map<String, dynamic> ? data['signs'] : null;
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(DictionarySign.fromJson)
        .toList();
  }

  @override
  Future<DictionarySign> fetchSignDetail(String word) async {
    final data =
        await _request('GET', '/api/v1/learn/dictionary/${Uri.encodeComponent(word)}');
    if (data is! Map<String, dynamic>) {
      return DictionarySign(word: word, category: '', hasAnimation: false);
    }
    return DictionarySign.fromJson(data);
  }

  @override
  Future<List<LearnProgress>> fetchProgress() async {
    final data = await _request('GET', '/api/v1/learn/progress');
    final raw = data is Map<String, dynamic> ? data['progress'] : null;
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(LearnProgress.fromJson)
        .toList();
  }

  @override
  Future<LearnProgress> recordAttempt(int exerciseId, double confidence) async {
    final data = await _request('POST', '/api/v1/learn/progress',
        body: {'exercise_id': exerciseId, 'confidence': confidence});
    if (data is! Map<String, dynamic>) {
      return LearnProgress(
          exerciseId: exerciseId, bestConfidence: confidence, passed: false);
    }
    return LearnProgress.fromJson(data);
  }
}

final learnRepositoryProvider = Provider<LearnRepository>((ref) {
  final (useSimulated, serverUrl) = ref.watch(
    settingsProvider.select((s) => (s.useSimulatedStream, s.serverUrl)),
  );
  if (useSimulated) {
    return SimulatedLearnRepository();
  }
  final accessToken = ref.watch(authProvider.select((s) => s.accessToken));
  return HttpLearnRepository(
    baseUrl: serverUrl
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://'),
    accessToken: accessToken,
  );
});
