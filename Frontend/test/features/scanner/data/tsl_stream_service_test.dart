import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/features/scanner/data/services/tsl_stream_service.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class FakeWebSocketSink implements WebSocketSink {
  final added = <dynamic>[];

  @override
  void add(dynamic data) => added.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeWebSocketChannel implements WebSocketChannel {
  final controller = StreamController<dynamic>.broadcast();
  final fakeSink = FakeWebSocketSink();
  final _readyCompleter = Completer<void>();

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  WebSocketSink get sink => fakeSink;

  @override
  Future<void> get ready => _readyCompleter.future;

  void completeReady() => _readyCompleter.complete();

  void failReady(Object error) => _readyCompleter.completeError(error);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FeatureVectorFrame vectorFrame() => FeatureVectorFrame(
      positionFeatures: List.filled(147, 0.1),
      velocityFeatures: List.filled(147, 0.0),
      accelerationFeatures: List.filled(147, 0.0),
    );

void main() {
  group('parseServerMessage', () {
    test('maps a confident prediction', () {
      final frame = parseServerMessage(jsonEncode({
        'schema_version': 1,
        'type': 'prediction',
        'seq': 30,
        'word': 'สวัสดี',
        'confidence': 0.94,
        'is_idle': false,
        'is_uncertain': false,
      }))!;
      expect(frame.word, 'สวัสดี');
      expect(frame.confidence, closeTo(0.94, 1e-9));
      expect(frame.isDetecting, isFalse);
    });

    test('uncertain or idle predictions are detecting placeholders', () {
      for (final flag in ['is_idle', 'is_uncertain']) {
        final frame = parseServerMessage(jsonEncode({
          'schema_version': 1,
          'type': 'prediction',
          'word': 'x',
          'confidence': 0.3,
          flag: true,
        }))!;
        expect(frame.word, '…');
        expect(frame.isDetecting, isTrue);
      }
    });

    test('evaluates client-based confidence threshold', () {
      final msg = jsonEncode({
        'schema_version': 1,
        'type': 'prediction',
        'seq': 30,
        'word': 'สวัสดี',
        'confidence': 0.82,
        'is_idle': false,
        'is_uncertain': false,
      });

      // Under a lower threshold (0.80), 0.82 is accepted.
      final frameAccepted = parseServerMessage(msg, confidenceThreshold: 0.80)!;
      expect(frameAccepted.word, 'สวัสดี');
      expect(frameAccepted.isDetecting, isFalse);

      // Under a higher threshold (0.85), 0.82 is filtered.
      final frameFiltered = parseServerMessage(msg, confidenceThreshold: 0.85)!;
      expect(frameFiltered.word, '…');
      expect(frameFiltered.isDetecting, isTrue);
    });

    test('non-prediction and malformed messages return null', () {
      expect(parseServerMessage('{"schema_version":1,"type":"ready"}'), isNull);
      expect(parseServerMessage('not json'), isNull);
      expect(parseServerMessage('[1,2]'), isNull);
    });
  });

  group('WebSocketTslStreamService', () {
    test('sends schema v1 landmark frames and emits parsed predictions',
        () async {
      final channel = FakeWebSocketChannel();
      Uri? connectedTo;
      final service = WebSocketTslStreamService(
        baseUrl: 'ws://example.test:8080',
        connect: (uri) {
          connectedTo = uri;
          return channel;
        },
      );
      addTearDown(service.dispose);

      service.start();
      expect(connectedTo.toString(), 'ws://example.test:8080/api/v1/stream');

      service.sendVector(vectorFrame());
      expect(channel.fakeSink.added, hasLength(1));
      final sent =
          jsonDecode(channel.fakeSink.added.single as String) as Map<String, dynamic>;
      expect(sent['schema_version'], 1);
      expect(sent['type'], 'landmark_frame');
      expect(sent['seq'], 1);
      expect((sent['features'] as List).length, 441);

      final frames = <TranslationFrame>[];
      final sub = service.translationStream.listen(frames.add);
      addTearDown(sub.cancel);

      channel.controller.add(jsonEncode({
        'schema_version': 1,
        'type': 'prediction',
        'seq': 1,
        'word': 'ขอบคุณ',
        'confidence': 0.91,
        'is_idle': false,
        'is_uncertain': false,
      }));
      await Future<void>.delayed(Duration.zero);

      expect(frames, hasLength(1));
      expect(frames.single.word, 'ขอบคุณ');
      expect(frames.single.latencySeconds, greaterThanOrEqualTo(0));
    });

    test('stop sends a reset message and ends the session', () {
      final channel = FakeWebSocketChannel();
      final service = WebSocketTslStreamService(
        baseUrl: 'ws://example.test:8080/',
        connect: (_) => channel,
      );
      addTearDown(service.dispose);

      service.start();
      service.stop();
      final last =
          jsonDecode(channel.fakeSink.added.last as String) as Map<String, dynamic>;
      expect(last['type'], 'reset');

      // After stop, frames are dropped instead of queued.
      service.sendVector(vectorFrame());
      expect(channel.fakeSink.added, hasLength(1));
    });

    test('connectionStatus reports connecting then connected', () async {
      final channel = FakeWebSocketChannel();
      final service = WebSocketTslStreamService(
        baseUrl: 'ws://example.test:8080',
        connect: (_) => channel,
      );
      addTearDown(service.dispose);

      final statuses = <ConnectionStatus>[];
      final sub = service.connectionStatus.listen(statuses.add);
      addTearDown(sub.cancel);

      service.start();
      await Future<void>.delayed(Duration.zero);
      expect(statuses, [ConnectionStatus.connecting]);

      channel.completeReady();
      await Future<void>.delayed(Duration.zero);
      expect(statuses, [ConnectionStatus.connecting, ConnectionStatus.connected]);
    });

    test(
        'an invalid URL reports disconnected instead of throwing an unhandled error',
        () async {
      final channel = FakeWebSocketChannel();
      final service = WebSocketTslStreamService(
        baseUrl: '',
        connect: (_) => channel,
      );
      addTearDown(service.dispose);

      final statuses = <ConnectionStatus>[];
      final sub = service.connectionStatus.listen(statuses.add);
      addTearDown(sub.cancel);

      service.start();
      channel.failReady(Exception('only ws: and wss: schemes are supported'));
      await Future<void>.delayed(Duration.zero);

      expect(statuses, [ConnectionStatus.connecting, ConnectionStatus.disconnected]);
    });

    test('normalizes https:// to wss:// for WebSocket connection', () {
      Uri? connectedTo;
      final channel = FakeWebSocketChannel();
      final service = WebSocketTslStreamService(
        baseUrl: 'https://my-server.example:8080',
        connect: (uri) {
          connectedTo = uri;
          return channel;
        },
      );
      addTearDown(service.dispose);

      service.start();
      expect(connectedTo.toString(),
          'wss://my-server.example:8080/api/v1/stream');
    });

    test('normalizes http:// to ws:// for WebSocket connection', () {
      Uri? connectedTo;
      final channel = FakeWebSocketChannel();
      final service = WebSocketTslStreamService(
        baseUrl: 'http://192.168.1.5:8080',
        connect: (uri) {
          connectedTo = uri;
          return channel;
        },
      );
      addTearDown(service.dispose);

      service.start();
      expect(connectedTo.toString(),
          'ws://192.168.1.5:8080/api/v1/stream');
    });

    test('adds ws:// when no scheme is provided', () {
      Uri? connectedTo;
      final channel = FakeWebSocketChannel();
      final service = WebSocketTslStreamService(
        baseUrl: '192.168.1.5:8080',
        connect: (uri) {
          connectedTo = uri;
          return channel;
        },
      );
      addTearDown(service.dispose);

      service.start();
      expect(connectedTo.toString(),
          'ws://192.168.1.5:8080/api/v1/stream');
    });
  });

  group('tslStreamServiceProvider', () {
    test('selects simulated or real service from settings', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(tslStreamServiceProvider),
          isA<WebSocketTslStreamService>());

      container
          .read(settingsProvider.notifier)
          .toggleSimulatedStream(true);
      expect(container.read(tslStreamServiceProvider),
          isA<SimulatedTslStreamService>());
    });
  });
}
