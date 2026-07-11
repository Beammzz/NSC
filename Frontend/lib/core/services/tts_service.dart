import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

abstract class TtsService {
  Future<void> speak(String text, {String languageCode = 'th-TH'});
  Future<void> stop();
  Stream<bool> get isSpeakingStream;
  bool get isSpeaking;
  void dispose();
}

class SimulatedTtsService implements TtsService {
  final _controller = StreamController<bool>.broadcast();
  bool _speaking = false;
  Timer? _timer;

  @override
  bool get isSpeaking => _speaking;

  @override
  Stream<bool> get isSpeakingStream => _controller.stream;

  @override
  Future<void> speak(String text, {String languageCode = 'th-TH'}) async {
    if (text.trim().isEmpty) return;
    _timer?.cancel();
    _speaking = true;
    if (!_controller.isClosed) {
      _controller.add(true);
    }
    _timer = Timer(const Duration(milliseconds: 600), () {
      _speaking = false;
      if (!_controller.isClosed) {
        _controller.add(false);
      }
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_speaking) {
      _speaking = false;
      if (!_controller.isClosed) {
        _controller.add(false);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}

class FlutterTtsService implements TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  final _controller = StreamController<bool>.broadcast();
  bool _speaking = false;

  FlutterTtsService() {
    _init();
  }

  void _init() {
    _flutterTts.setStartHandler(() {
      _speaking = true;
      if (!_controller.isClosed) _controller.add(true);
    });

    _flutterTts.setCompletionHandler(() {
      _speaking = false;
      if (!_controller.isClosed) _controller.add(false);
    });

    _flutterTts.setErrorHandler((msg) {
      _speaking = false;
      if (!_controller.isClosed) _controller.add(false);
    });
  }

  @override
  bool get isSpeaking => _speaking;

  @override
  Stream<bool> get isSpeakingStream => _controller.stream;

  @override
  Future<void> speak(String text, {String languageCode = 'th-TH'}) async {
    if (text.trim().isEmpty) return;
    try {
      await _flutterTts.setLanguage(languageCode);
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);
      await _flutterTts.speak(text);
    } catch (_) {
      _speaking = false;
      if (!_controller.isClosed) _controller.add(false);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _flutterTts.stop();
    } catch (_) {}
    _speaking = false;
    if (!_controller.isClosed) _controller.add(false);
  }

  @override
  void dispose() {
    stop();
    _controller.close();
  }
}

final ttsServiceProvider = Provider<TtsService>((ref) {
  final isTest = Platform.environment.containsKey('FLUTTER_TEST');
  final TtsService service =
      (!isTest && !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS))
          ? FlutterTtsService()
          : SimulatedTtsService();
  ref.onDispose(service.dispose);
  return service;
});
