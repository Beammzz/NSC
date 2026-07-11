import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

abstract class SttService {
  Future<bool> initialize();
  Future<void> startListening({
    required Function(String text, double confidence) onResult,
    String localeId = 'th_TH',
  });
  Future<void> stopListening();
  Stream<bool> get isListeningStream;
  bool get isListening;
  void dispose();
}

class SimulatedSttService implements SttService {
  final _controller = StreamController<bool>.broadcast();
  bool _listening = false;
  Function(String text, double confidence)? _onResult;

  @override
  bool get isListening => _listening;

  @override
  Stream<bool> get isListeningStream => _controller.stream;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> startListening({
    required Function(String text, double confidence) onResult,
    String localeId = 'th_TH',
  }) async {
    _onResult = onResult;
    _listening = true;
    if (!_controller.isClosed) _controller.add(true);
  }

  /// Helper method for tests to simulate recognized speech input.
  void simulateSpeech(String text, double confidence) {
    if (_listening && _onResult != null) {
      _onResult!(text, confidence);
    }
  }

  @override
  Future<void> stopListening() async {
    _listening = false;
    if (!_controller.isClosed) _controller.add(false);
  }

  @override
  void dispose() {
    _controller.close();
  }
}

class SpeechToTextService implements SttService {
  final SpeechToText _speech = SpeechToText();
  final _controller = StreamController<bool>.broadcast();
  bool _listening = false;

  @override
  bool get isListening => _listening;

  @override
  Stream<bool> get isListeningStream => _controller.stream;

  @override
  Future<bool> initialize() async {
    try {
      return await _speech.initialize(
        onError: (_) {
          _listening = false;
          if (!_controller.isClosed) _controller.add(false);
        },
        onStatus: (status) {
          final isNowListening = (status == 'listening');
          if (_listening != isNowListening) {
            _listening = isNowListening;
            if (!_controller.isClosed) _controller.add(_listening);
          }
        },
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> startListening({
    required Function(String text, double confidence) onResult,
    String localeId = 'th_TH',
  }) async {
    final available = await initialize();
    if (!available) return;

    _listening = true;
    if (!_controller.isClosed) _controller.add(true);

    try {
      await _speech.listen(
        onResult: (result) {
          onResult(result.recognizedWords, result.confidence);
        },
        // ignore: deprecated_member_use
        localeId: localeId,
      );
    } catch (_) {
      _listening = false;
      if (!_controller.isClosed) _controller.add(false);
    }
  }

  @override
  Future<void> stopListening() async {
    try {
      await _speech.stop();
    } catch (_) {}
    _listening = false;
    if (!_controller.isClosed) _controller.add(false);
  }

  @override
  void dispose() {
    stopListening();
    _controller.close();
  }
}

final sttServiceProvider = Provider<SttService>((ref) {
  final isTest = Platform.environment.containsKey('FLUTTER_TEST');
  final SttService service =
      (!isTest && !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS))
          ? SpeechToTextService()
          : SimulatedSttService();
  ref.onDispose(service.dispose);
  return service;
});
