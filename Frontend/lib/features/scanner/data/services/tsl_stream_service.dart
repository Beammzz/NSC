import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

abstract class TslStreamService {
  Stream<TranslationFrame> get translationStream;
  Stream<ConnectionStatus> get connectionStatus;
  void sendVector(FeatureVectorFrame frame);
  void start();
  void stop();
  void dispose();
}

/// Simulated implementation of WebSocket streaming to `/api/v1/stream`.
/// Loops through the 5 TSL demo words from App_Design.
class SimulatedTslStreamService implements TslStreamService {
  final _controller = StreamController<TranslationFrame>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  Timer? _timer;
  int _wordIdx = 0;
  int _phase = 0; // 0=detecting, 1=detected, 2=hold
  bool _isActive = false;
  final _random = math.Random();

  static const _demoWords = [
    ('สวัสดี', 0.94),
    ('ขอบคุณ', 0.91),
    ('ช่วยเหลือ', 0.87),
    ('โรงพยาบาล', 0.82),
    ('เท่าไหร่', 0.89),
  ];

  @override
  Stream<TranslationFrame> get translationStream => _controller.stream;

  @override
  Stream<ConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  void sendVector(FeatureVectorFrame frame) {
    // In real implementation, transmits 441-dim vector over WebSocket WSS
  }

  @override
  void start() {
    if (_isActive) return;
    _isActive = true;
    if (!_statusController.isClosed) {
      _statusController.add(ConnectionStatus.connected);
    }
    _timer = Timer.periodic(const Duration(milliseconds: 1300), (_) {
      if (!_isActive) return;
      _phase = (_phase + 1) % 3;
      final current = _demoWords[_wordIdx];
      final isDetecting = _phase == 0;
      final fps = 22 + _random.nextInt(6);

      if (_phase == 0) {
        _wordIdx = (_wordIdx + 1) % _demoWords.length;
      }

      if (!_controller.isClosed) {
        _controller.add(TranslationFrame(
          word: isDetecting ? '…' : current.$1,
          confidence: isDetecting ? 0.0 : current.$2,
          fps: fps,
          latencySeconds: 1.1,
          isDetecting: isDetecting,
        ));
      }
    });
  }

  @override
  void stop() {
    _isActive = false;
    _timer?.cancel();
    _timer = null;
    if (!_statusController.isClosed) {
      _statusController.add(ConnectionStatus.disconnected);
    }
  }

  @override
  void dispose() {
    stop();
    _controller.close();
    _statusController.close();
  }
}

/// Parses one server message (docs/api/stream-schema.md, schema_version 1)
/// into a [TranslationFrame]; returns null for non-prediction messages.
TranslationFrame? parseServerMessage(
  String data, {
  double latencySeconds = 0.0,
  int fps = 0,
}) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(data);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['type'] != 'prediction') return null;

  final word = decoded['word'] as String? ?? '';
  final confidence = (decoded['confidence'] as num?)?.toDouble() ?? 0.0;
  final isIdle = decoded['is_idle'] == true;
  final isUncertain = decoded['is_uncertain'] == true;
  final isDetecting = isIdle || isUncertain || word.isEmpty;

  return TranslationFrame(
    word: isDetecting ? '…' : word,
    confidence: isDetecting ? 0.0 : confidence,
    fps: fps,
    latencySeconds: latencySeconds,
    isDetecting: isDetecting,
  );
}

/// Real WebSocket implementation streaming to `<serverUrl>/api/v1/stream`
/// per docs/api/stream-schema.md.
class WebSocketTslStreamService implements TslStreamService {
  WebSocketTslStreamService({
    required this.baseUrl,
    WebSocketChannel Function(Uri uri)? connect,
  }) : _connect = connect ?? WebSocketChannel.connect;

  static const _schemaVersion = 1;
  static const _streamPath = '/api/v1/stream';

  final String baseUrl;
  final WebSocketChannel Function(Uri uri) _connect;
  final _controller = StreamController<TranslationFrame>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  bool _isActive = false;
  int _seq = 0;
  // seq -> send time, for end-to-end latency; pruned as predictions arrive.
  final _sentAt = <int, DateTime>{};
  final _recentSends = <DateTime>[];

  @override
  Stream<TranslationFrame> get translationStream => _controller.stream;

  @override
  Stream<ConnectionStatus> get connectionStatus => _statusController.stream;

  void _setStatus(ConnectionStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  Uri get _streamUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$_streamPath');
  }

  @override
  void start() {
    if (_isActive) return;
    _isActive = true;
    _seq = 0;
    _sentAt.clear();
    _setStatus(ConnectionStatus.connecting);
    final WebSocketChannel channel;
    try {
      channel = _connect(_streamUri);
    } on FormatException {
      _isActive = false;
      _setStatus(ConnectionStatus.disconnected);
      return;
    }
    _channel = channel;
    // The URL's scheme/host are only validated once the connection is
    // actually attempted, which surfaces as an error on `ready` rather than
    // a synchronous throw here. Without this handler that error is never
    // observed and becomes an unhandled async exception that crashes the app.
    channel.ready.then(
      (_) {
        if (identical(_channel, channel)) _setStatus(ConnectionStatus.connected);
      },
      onError: (Object _) {
        if (identical(_channel, channel)) _teardownChannel();
      },
    );
    _channelSub = channel.stream.listen(
      _onData,
      onError: (Object _) => _teardownChannel(),
      onDone: _teardownChannel,
    );
  }

  void _onData(dynamic data) {
    if (data is! String || _controller.isClosed) return;
    final now = DateTime.now();

    double latencySeconds = 0.0;
    final dynamic decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is Map<String, dynamic> && decoded['seq'] is int) {
      final sent = _sentAt.remove(decoded['seq'] as int);
      if (sent != null) {
        latencySeconds = now.difference(sent).inMilliseconds / 1000.0;
        _sentAt.removeWhere((_, t) => t.isBefore(sent));
      }
    }

    _recentSends.removeWhere(
        (t) => now.difference(t) > const Duration(seconds: 1));
    final frame = parseServerMessage(
      data,
      latencySeconds: latencySeconds,
      fps: _recentSends.length,
    );
    if (frame != null) {
      _controller.add(frame);
    }
  }

  @override
  void sendVector(FeatureVectorFrame frame) {
    final channel = _channel;
    if (!_isActive || channel == null) return;
    final now = DateTime.now();
    _seq++;
    _sentAt[_seq] = now;
    if (_sentAt.length > 64) {
      _sentAt.remove(_sentAt.keys.first);
    }
    _recentSends.add(now);
    _recentSends.removeWhere(
        (t) => now.difference(t) > const Duration(seconds: 1));
    channel.sink.add(jsonEncode({
      'schema_version': _schemaVersion,
      'type': 'landmark_frame',
      'seq': _seq,
      'timestamp_ms': now.millisecondsSinceEpoch,
      'features': frame.fullVector,
    }));
  }

  void _teardownChannel() {
    _channelSub?.cancel();
    _channelSub = null;
    _channel?.sink.close();
    _channel = null;
    _isActive = false;
    _setStatus(ConnectionStatus.disconnected);
  }

  @override
  void stop() {
    if (_channel != null && _isActive) {
      _channel!.sink.add(jsonEncode({
        'schema_version': _schemaVersion,
        'type': 'reset',
      }));
    }
    _teardownChannel();
  }

  @override
  void dispose() {
    _teardownChannel();
    _controller.close();
    _statusController.close();
  }
}

final tslStreamServiceProvider = Provider<TslStreamService>((ref) {
  final (useSimulated, serverUrl) = ref.watch(
    settingsProvider.select((s) => (s.useSimulatedStream, s.serverUrl)),
  );
  final TslStreamService service = useSimulated
      ? SimulatedTslStreamService()
      : WebSocketTslStreamService(baseUrl: serverUrl);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Live connection status of [tslStreamServiceProvider], for UI (e.g. the
/// Settings screen) that wants to display it without pulling in the full
/// scanner/landmark pipeline that actually drives `start()`.
final tslConnectionStatusProvider = StreamProvider<ConnectionStatus>((ref) {
  return ref.watch(tslStreamServiceProvider).connectionStatus;
});
