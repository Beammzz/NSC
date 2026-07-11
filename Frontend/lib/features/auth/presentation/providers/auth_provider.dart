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

  /// Converts a WebSocket/HTTP Server URL (e.g. ws://10.0.2.2:8080) to HTTP base URL.
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

  Future<bool> login(String email, String password, String serverUrl) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final baseUrl = _toHttpUrl(serverUrl);
      final url = Uri.parse('$baseUrl/api/v1/auth/login');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      final request = await client.postUrl(url);
      request.headers.set('content-type', 'application/json');
      request.write(jsonEncode({'email': email.trim(), 'password': password}));
      final resp = await request.close();
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final user = AuthUser.fromJson(data['user'] as Map<String, dynamic>);
        final token = data['access_token'] as String?;
        ref.read(settingsProvider.notifier).setServerUrl(serverUrl);
        ref.read(settingsProvider.notifier).toggleSimulatedStream(false);
        ref.read(tslStreamServiceProvider).start();
        state = state.copyWith(
          user: user,
          accessToken: token,
          isLoading: false,
          isSimulatedGuest: false,
        );
        return true;
      } else {
        String msg = 'เข้าสู่ระบบไม่สำเร็จ (${resp.statusCode})';
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
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ กรุณาตรวจสอบ Server IP ($e)',
      );
      return false;
    }
  }

  Future<bool> signup(String email, String password, String serverUrl) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final baseUrl = _toHttpUrl(serverUrl);
      final url = Uri.parse('$baseUrl/api/v1/auth/signup');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 6);
      final request = await client.postUrl(url);
      request.headers.set('content-type', 'application/json');
      request.write(jsonEncode({'email': email.trim(), 'password': password}));
      final resp = await request.close();
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final user = AuthUser.fromJson(data['user'] as Map<String, dynamic>);
        final token = data['access_token'] as String?;
        ref.read(settingsProvider.notifier).setServerUrl(serverUrl);
        ref.read(settingsProvider.notifier).toggleSimulatedStream(false);
        ref.read(tslStreamServiceProvider).start();
        state = state.copyWith(
          user: user,
          accessToken: token,
          isLoading: false,
          isSimulatedGuest: false,
        );
        return true;
      } else {
        String msg = 'สมัครสมาชิกไม่สำเร็จ (${resp.statusCode})';
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
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ กรุณาตรวจสอบ Server IP ($e)',
      );
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
