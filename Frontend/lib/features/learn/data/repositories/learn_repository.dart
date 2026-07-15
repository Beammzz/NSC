import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/learn/domain/models/learn_models.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

/// Data source for the Learn tab (topics, dictionary, progress). The real
/// implementation talks to `/api/v1/learn/*`; the simulated one serves a
/// local subset so demo mode works fully offline (matching the demo-mode
/// contract of the stream feature).
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
        LearnExercise(id: 4, topicId: 1, word: 'แย่', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 5, topicId: 1, word: 'เร็ว', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 2,
      slug: 'people',
      title: 'ผู้คนและครอบครัว',
      icon: '👪',
      sortOrder: 1,
      exercises: [
        LearnExercise(id: 6, topicId: 2, word: 'ฉัน', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 7, topicId: 2, word: 'คุณ', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 8, topicId: 2, word: 'พ่อ', sortOrder: 2, passConfidence: 0.8),
        LearnExercise(id: 9, topicId: 2, word: 'แม่', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 10, topicId: 2, word: 'พี่', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 3,
      slug: 'food',
      title: 'อาหารและเครื่องดื่ม',
      icon: '🍚',
      sortOrder: 2,
      exercises: [
        LearnExercise(id: 11, topicId: 3, word: 'กิน', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 12, topicId: 3, word: 'ดื่ม', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 13, topicId: 3, word: 'ข้าว', sortOrder: 2, passConfidence: 0.8),
        LearnExercise(id: 14, topicId: 3, word: 'น้ำ', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 15, topicId: 3, word: 'ไข่', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 4,
      slug: 'numbers',
      title: 'ตัวเลข',
      icon: '🔢',
      sortOrder: 3,
      exercises: [
        LearnExercise(id: 16, topicId: 4, word: '1', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 17, topicId: 4, word: '2', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 18, topicId: 4, word: '3', sortOrder: 2, passConfidence: 0.8),
        LearnExercise(id: 19, topicId: 4, word: '4', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 20, topicId: 4, word: '5', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 5,
      slug: 'colors',
      title: 'สีสัน',
      icon: '🎨',
      sortOrder: 4,
      exercises: [
        LearnExercise(id: 21, topicId: 5, word: 'สีแดง', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 22, topicId: 5, word: 'สีเขียว', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 23, topicId: 5, word: 'สีฟ้า', sortOrder: 2, passConfidence: 0.8),
        LearnExercise(id: 24, topicId: 5, word: 'สีดำ', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 25, topicId: 5, word: 'สีชมพู', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 6,
      slug: 'feelings',
      title: 'อารมณ์ความรู้สึก',
      icon: '😊',
      sortOrder: 5,
      exercises: [
        LearnExercise(id: 26, topicId: 6, word: 'ดีใจ', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 27, topicId: 6, word: 'หิว', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 28, topicId: 6, word: 'ง่วง', sortOrder: 2, passConfidence: 0.8),
        LearnExercise(id: 29, topicId: 6, word: 'เครียด', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 30, topicId: 6, word: 'รัก', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 7,
      slug: 'daily',
      title: 'กิจวัตรประจำวัน',
      icon: '🏃',
      sortOrder: 6,
      exercises: [
        LearnExercise(id: 31, topicId: 7, word: 'นอน', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 32, topicId: 7, word: 'ทำงาน', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 33, topicId: 7, word: 'เรียน', sortOrder: 2, passConfidence: 0.8),
        LearnExercise(id: 34, topicId: 7, word: 'อ่าน', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 35, topicId: 7, word: 'เขียน', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
    LearnTopic(
      id: 8,
      slug: 'time',
      title: 'วันและเวลา',
      icon: '📅',
      sortOrder: 7,
      exercises: [
        LearnExercise(id: 36, topicId: 8, word: 'วันนี้', sortOrder: 0, passConfidence: 0.8),
        LearnExercise(id: 37, topicId: 8, word: 'พรุ่งนี้', sortOrder: 1, passConfidence: 0.8),
        LearnExercise(id: 38, topicId: 8, word: 'เมื่อวาน', sortOrder: 2, passConfidence: 0.8),
        LearnExercise(id: 39, topicId: 8, word: 'เช้า', sortOrder: 3, passConfidence: 0.8),
        LearnExercise(id: 40, topicId: 8, word: 'เวลา', sortOrder: 4, passConfidence: 0.8),
      ],
    ),
  ];

  static final List<DictionarySign> _signs = _dictionaryCategories.entries
      .expand((entry) => entry.value.map(
            (word) => DictionarySign(
              word: word,
              category: entry.key,
              hasAnimation: false,
            ),
          ))
      .toList();

  static const _dictionaryCategories = <String, List<String>>{
    'ตัวเลข': [
      '1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '20', '30', '100',
    ],
    'คำพื้นฐาน': [
      'ขอโทษ', 'บ๊ายบาย', 'ดี', 'แย่', 'เร็ว', 'เอา',
    ],
    'ผู้คนและครอบครัว': [
      'คุณ', 'ฉัน', 'ผม', 'เรา', 'พี่', 'พ่อ', 'แม่', 'พ่อค้า',
    ],
    'ร่างกาย': [
      'คิ้ว', 'จมูก', 'ตา', 'นิ้ว', 'ปาก', 'มือ', 'หู', 'แก้ม',
    ],
    'อาหารและเครื่องดื่ม': [
      'กล้วย', 'กาแฟ', 'กุ้ง', 'ข้าว', 'ชา', 'นม', 'น้ำ', 'ปลา',
      'มะม่วง', 'ส้ม', 'เค้ก', 'แตงโม', 'แอปเปิ้ล', 'ไก่ทอด', 'ไข่',
    ],
    'สัตว์และธรรมชาติ': [
      'กบ', 'นก', 'ปู', 'ไก่', 'ทราย', 'ทะเล', 'หิน', 'ลม', 'ฝนตก',
    ],
    'สี': [
      'สี', 'สีชมพู', 'สีดำ', 'สีฟ้า', 'สีม่วง', 'สีเขียว', 'สีแดง',
    ],
    'วันและเดือน': [
      'วันจันทร์', 'วันอังคาร', 'วันพุธ', 'วันพฤหัสบดี', 'วันศุกร์',
      'วันเสาร์', 'วันอาทิตย์',
      'มกราคม', 'กุมภาพันธ์', 'มีนาคม', 'เมษายน', 'พฤษภาคม', 'มิถุนายน',
      'กรกฎาคม', 'สิงหาคม', 'กันยายน', 'ตุลาคม', 'พฤศจิกายน', 'ธันวาคม',
    ],
    'เวลา': [
      'วันนี้', 'พรุ่งนี้', 'เมื่อวาน', 'เมื่อวานซืน', 'เช้า', 'ปี', 'เดือน', 'เวลา',
    ],
    'อารมณ์ความรู้สึก': [
      'กังวล', 'ง่วง', 'ดีใจ', 'หิว', 'เกลียด', 'เครียด', 'เบื่อ',
      'ทะเลาะ', 'คิด', 'รัก',
    ],
    'กิจวัตรและการกระทำ': [
      'กด', 'กระโดด', 'กิน', 'ขับรถ', 'ขาย', "ซื้อ", 'ดื่ม', 'ดู',
      'ทำงาน', 'นอน', 'นั่ง', 'พูด', 'ฟัง', 'ยืน', 'วิ่ง', 'สอน',
      'อาบน้ำ', 'อ่าน', 'เขียน', 'เดิน', 'เปิด', 'ปิด', 'เรียน', 'เล่น',
      'โทร', 'ถ่ายรูป', 'ล้าง', 'แปรงฟัน', 'ไป',
    ],
    'สิ่งของและสถานที่': [
      'กระจก', 'กระดาษ', 'กุญแจ', 'ตลาด', 'ตู้เสื้อผ้า', 'ถนน', 'ถุงเท้า',
      'บ้าน', 'ปากกา', 'รองเท้า', 'หนังสือ', 'หมวก', 'ห้องครัว', 'เสื้อ',
      'แว่น', 'โต๊ะ', 'โรงเรียน', 'สะพาน',
    ],
  };

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
      if (accessToken != null && accessToken!.isNotEmpty) {
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
