import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/auth/domain/models/auth_state.dart';
import 'package:signmind/features/scanner/data/services/tsl_stream_service.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    return const AuthState();
  }

  /// Converts a WebSocket/HTTP Server URL (e.g. https://signmind.harumi.dev) to HTTP base URL.
  String _toHttpUrl(String wsOrHttpUrl) {
    var trimmed = wsOrHttpUrl.trim();
    if (trimmed.startsWith('wss://')) {
      return 'https://${trimmed.substring(6)}';
    }
    if (trimmed.startsWith('ws://')) {
      return 'http://${trimmed.substring(5)}';
    }
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      return 'http://$trimmed';
    }
    return trimmed;
  }

  Future<({int statusCode, String body})> _postWithTimeout(
    Uri url,
    Map<String, dynamic> payload,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      return await _performPost(client, url, payload).timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException('เซิร์ฟเวอร์ไม่ตอบสนองภายใน 3 วินาที'),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<({int statusCode, String body})> _performPost(
    HttpClient client,
    Uri url,
    Map<String, dynamic> payload,
  ) async {
    final request = await client.postUrl(url);
    request.headers.set('content-type', 'application/json');
    request.write(jsonEncode(payload));
    final resp = await request.close();
    final body = await resp.transform(utf8.decoder).join();
    return (statusCode: resp.statusCode, body: body);
  }

  Future<bool> login(String email, String password, String serverUrl) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final baseUrl = _toHttpUrl(serverUrl);
      final url = Uri.parse('$baseUrl/api/v1/auth/login');
      final result = await _postWithTimeout(
        url,
        {'email': email.trim(), 'password': password},
      );
      final statusCode = result.statusCode;
      final body = result.body;

      if (statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final user = AuthUser.fromJson(data['user'] as Map<String, dynamic>);
        final token = data['access_token'] as String?;
        ref.read(settingsProvider.notifier).setServerUrl(serverUrl);
        ref.read(settingsProvider.notifier).toggleSimulatedStream(false);
        // Publish the token BEFORE starting the stream: the stream service
        // provider watches it and rebuilds, so starting first would connect
        // tokenless and be disposed immediately.
        state = state.copyWith(
          user: user,
          accessToken: token,
          isLoading: false,
          isSimulatedGuest: false,
        );
        ref.read(tslStreamServiceProvider).start();
        return true;
      } else {
        String msg = 'เข้าสู่ระบบไม่สำเร็จ ($statusCode)';
        try {
          final problem = jsonDecode(body) as Map<String, dynamic>;
          if (problem['title'] != null) {
            msg = '${problem['title']}';
            if (problem['detail'] != null && (problem['detail'] as String).isNotEmpty) {
              msg += ': ${problem['detail']}';
            }
          }
        } catch (_) {}
        state = state.copyWith(isLoading: false, error: msg);
        return false;
      }
    } on TimeoutException {
      state = state.copyWith(
        isLoading: false,
        error: 'เซิร์ฟเวอร์ไม่ตอบสนองภายใน 3 วินาที กรุณาตรวจสอบ Server IP',
      );
      return false;
    } catch (e) {
      if (e is TimeoutException ||
          (e is SocketException && e.toString().toLowerCase().contains('time'))) {
        state = state.copyWith(
          isLoading: false,
          error: 'เซิร์ฟเวอร์ไม่ตอบสนองภายใน 3 วินาที กรุณาตรวจสอบ Server IP',
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ กรุณาตรวจสอบ Server IP ($e)',
        );
      }
      return false;
    }
  }

  Future<bool> signup(String email, String password, String serverUrl) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final baseUrl = _toHttpUrl(serverUrl);
      final url = Uri.parse('$baseUrl/api/v1/auth/signup');
      final result = await _postWithTimeout(
        url,
        {'email': email.trim(), 'password': password},
      );
      final statusCode = result.statusCode;
      final body = result.body;

      if (statusCode == 200 || statusCode == 201) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final user = AuthUser.fromJson(data['user'] as Map<String, dynamic>);
        final token = data['access_token'] as String?;
        ref.read(settingsProvider.notifier).setServerUrl(serverUrl);
        ref.read(settingsProvider.notifier).toggleSimulatedStream(false);
        // Token before start() — see login().
        state = state.copyWith(
          user: user,
          accessToken: token,
          isLoading: false,
          isSimulatedGuest: false,
        );
        ref.read(tslStreamServiceProvider).start();
        return true;
      } else {
        String msg = 'สมัครสมาชิกไม่สำเร็จ ($statusCode)';
        try {
          final problem = jsonDecode(body) as Map<String, dynamic>;
          if (problem['title'] != null) {
            msg = '${problem['title']}';
            if (problem['detail'] != null && (problem['detail'] as String).isNotEmpty) {
              msg += ': ${problem['detail']}';
            }
          }
        } catch (_) {}
        state = state.copyWith(isLoading: false, error: msg);
        return false;
      }
    } on TimeoutException {
      state = state.copyWith(
        isLoading: false,
        error: 'เซิร์ฟเวอร์ไม่ตอบสนองภายใน 3 วินาที กรุณาตรวจสอบ Server IP',
      );
      return false;
    } catch (e) {
      if (e is TimeoutException ||
          (e is SocketException && e.toString().toLowerCase().contains('time'))) {
        state = state.copyWith(
          isLoading: false,
          error: 'เซิร์ฟเวอร์ไม่ตอบสนองภายใน 3 วินาที กรุณาตรวจสอบ Server IP',
        );
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ กรุณาตรวจสอบ Server IP ($e)',
        );
      }
      return false;
    }
  }

  void enterSimulatedGuestMode() {
    ref.read(settingsProvider.notifier).toggleSimulatedStream(true);
    state = state.copyWith(
      user: const AuthUser(
        id: 0,
        email: 'demo_guest@signmind.local',
        role: 'guest',
      ),
      isSimulatedGuest: true,
      isLoading: false,
      clearError: true,
    );
  }

  void logout() {
    ref.read(tslStreamServiceProvider).stop();
    state = const AuthState();
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
