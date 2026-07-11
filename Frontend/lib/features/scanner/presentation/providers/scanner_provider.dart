import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/core/services/tts_service.dart';
import 'package:signmind/features/scanner/data/services/feature_vector_builder.dart';
import 'package:signmind/features/scanner/data/services/landmark_extraction_service.dart';
import 'package:signmind/features/scanner/data/services/tsl_stream_service.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

class ScannerNotifier extends Notifier<ScannerState> {
  StreamSubscription<RawLandmarkFrame>? _frameSub;
  StreamSubscription<TranslationFrame>? _streamSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<bool>? _ttsSub;

  @override
  ScannerState build() {
    final landmarkService = ref.watch(landmarkExtractionServiceProvider);
    final streamService = ref.watch(tslStreamServiceProvider);
    final ttsService = ref.watch(ttsServiceProvider);

    _frameSub?.cancel();
    _streamSub?.cancel();
    _statusSub?.cancel();
    _ttsSub?.cancel();

    _frameSub = landmarkService.frameStream.listen((frame) {
      if (state.isScanning) {
        state = state.copyWith(currentFrame: frame);
        streamService.sendVector(buildFeatureVector(frame));
      }
    });

    _streamSub = streamService.translationStream.listen((frame) {
      if (!state.isScanning) return;

      List<String> newSentence = List.from(state.sentence);
      bool wordAdded = false;
      if (!frame.isDetecting && frame.word.isNotEmpty && frame.word != '…') {
        if (newSentence.isEmpty || newSentence.last != frame.word) {
          newSentence.add(frame.word);
          wordAdded = true;
          if (newSentence.length > 6) {
            newSentence = newSentence.sublist(newSentence.length - 6);
          }
        }
      }

      if (wordAdded && ref.read(settingsProvider).autoSpeak) {
        ref.read(ttsServiceProvider).speak(frame.word);
      }

      state = state.copyWith(
        currentWord: frame.word,
        confidence: frame.confidence,
        fps: frame.fps,
        latencySeconds: frame.latencySeconds,
        sentence: newSentence,
        demoPhase: frame.isDetecting ? 0 : 1,
      );
    });

    _statusSub = streamService.connectionStatus.listen((status) {
      state = state.copyWith(connectionStatus: status);
    });

    _ttsSub = ttsService.isSpeakingStream.listen((speaking) {
      state = state.copyWith(isSpeaking: speaking);
    });

    ref.onDispose(() {
      _frameSub?.cancel();
      _streamSub?.cancel();
      _statusSub?.cancel();
      _ttsSub?.cancel();
    });

    landmarkService.start();
    streamService.start();

    return ScannerState.initial();
  }

  void toggleScan() {
    final landmarkService = ref.read(landmarkExtractionServiceProvider);
    final streamService = ref.read(tslStreamServiceProvider);
    final newScanning = !state.isScanning;
    if (newScanning) {
      landmarkService.start();
      streamService.start();
    } else {
      landmarkService.stop();
      streamService.stop();
    }
    state = state.copyWith(isScanning: newScanning);
  }

  void clearSentence() {
    state = state.copyWith(sentence: []);
  }

  Future<void> speakSentence() async {
    if (state.sentence.isEmpty || state.isSpeaking) return;
    state = state.copyWith(isSpeaking: true);
    await ref.read(ttsServiceProvider).speak(state.sentence.join(' '));
    state = state.copyWith(isSpeaking: false);
  }
}

final scannerProvider = NotifierProvider<ScannerNotifier, ScannerState>(ScannerNotifier.new);
