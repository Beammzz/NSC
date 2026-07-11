import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/features/scanner/data/services/feature_vector_builder.dart';
import 'package:signmind/features/scanner/data/services/landmark_extraction_service.dart';
import 'package:signmind/features/scanner/data/services/tsl_stream_service.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';

class ScannerNotifier extends Notifier<ScannerState> {
  StreamSubscription<RawLandmarkFrame>? _frameSub;
  StreamSubscription<TranslationFrame>? _streamSub;
  StreamSubscription<ConnectionStatus>? _statusSub;

  @override
  ScannerState build() {
    final landmarkService = ref.watch(landmarkExtractionServiceProvider);
    final streamService = ref.watch(tslStreamServiceProvider);

    _frameSub?.cancel();
    _streamSub?.cancel();
    _statusSub?.cancel();

    // A single per-frame stream drives both the overlay (full body layout:
    // both hands + upper pose) and the 147-dim body-normalized vector sent to
    // the server (WebSocketTslStreamService.sendVector; no-op while simulated).
    _frameSub = landmarkService.frameStream.listen((frame) {
      if (state.isScanning) {
        state = state.copyWith(currentFrame: frame);
        streamService.sendVector(buildFeatureVector(frame));
      }
    });

    _streamSub = streamService.translationStream.listen((frame) {
      if (!state.isScanning) return;

      List<String> newSentence = List.from(state.sentence);
      if (!frame.isDetecting && frame.word.isNotEmpty && frame.word != '…') {
        if (newSentence.isEmpty || newSentence.last != frame.word) {
          newSentence.add(frame.word);
          if (newSentence.length > 6) {
            newSentence = newSentence.sublist(newSentence.length - 6);
          }
        }
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

    ref.onDispose(() {
      _frameSub?.cancel();
      _streamSub?.cancel();
      _statusSub?.cancel();
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
    await Future.delayed(const Duration(milliseconds: 1800));
    state = state.copyWith(isSpeaking: false);
  }
}

final scannerProvider = NotifierProvider<ScannerNotifier, ScannerState>(ScannerNotifier.new);
