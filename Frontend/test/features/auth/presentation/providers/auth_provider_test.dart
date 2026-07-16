import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/auth/presentation/providers/auth_provider.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

void main() {
  test('login sets error message when server does not respond within 3 seconds', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      await Future.delayed(const Duration(milliseconds: 3200));
      if (request.response.connectionInfo != null) {
        request.response.statusCode = 200;
        await request.response.close();
      }
    });

    final notifier = container.read(authProvider.notifier);
    final success = await notifier.login(
      'test@example.com',
      'secret',
      'http://127.0.0.1:${server.port}',
    );

    expect(success, isFalse);
    final state = container.read(authProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, 'เซิร์ฟเวอร์ไม่ตอบสนองภายใน 3 วินาที กรุณาตรวจสอบ Server IP');
  });

  test('login sets error message when server is unavailable or connection fails', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);

    final notifier = container.read(authProvider.notifier);
    final success = await notifier.login(
      'test@example.com',
      'secret',
      'http://127.0.0.1:$port',
    );

    expect(success, isFalse);
    final state = container.read(authProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, contains('เชื่อมต่อเซิร์ฟเวอร์ไม่ได้'));
  });
}
