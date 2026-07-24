import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signmind/core/services/tts_service.dart';
import 'package:signmind/core/widgets/main_scaffold.dart';
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
  DateTime _lastCosmeticWrite = DateTime.fromMillisecondsSinceEpoch(0);
  ScannerState? _savedState;

  @override
  ScannerState build() {
    final landmarkService = ref.watch(landmarkExtractionServiceProvider);
    final streamService = ref.watch(tslStreamServiceProvider);
    final ttsService = ref.watch(ttsServiceProvider);
    final isActive = ref.watch(isScannerActiveProvider);

    final initialState = _savedState ?? ScannerState.initial();
    _savedState = initialState;

    _frameSub?.cancel();
    _streamSub?.cancel();
    _statusSub?.cancel();
    _ttsSub?.cancel();

    _frameSub = landmarkService.frameStream.listen((frame) {
      if (state.isScanning) {
        // High-rate (~12/s) frames go to their own provider so only the
        // skeleton overlay rebuilds per frame; routing them through
        // ScannerState rebuilt the whole screen (see currentFrameProvider).
        ref.read(currentFrameProvider.notifier).set(frame);
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

      // The real server replies once per landmark frame (~12/s), and its
      // fps/latency/confidence jitter on every message, so equality checks
      // cannot dedupe them (measured: the UI re-rastered 29x/s). Words and
      // detection-phase changes render immediately (a phase flip always
      // changes `word` to/from '…'); the cosmetic chip fields coalesce to
      // 2 writes/s — every state write rebuilds the whole scanner screen on
      // the merged main thread (camera platform view), competing with
      // MediaPipe's GPU inference on low-end devices.
      final now = DateTime.now();
      final urgent = wordAdded || frame.word != state.currentWord;
      if (!urgent &&
          now.difference(_lastCosmeticWrite) <
              const Duration(milliseconds: 500)) {
        return;
      }
      _lastCosmeticWrite = now;

      final newState = state.copyWith(
        currentWord: frame.word,
        confidence: frame.confidence,
        fps: frame.fps,
        latencySeconds: frame.latencySeconds,
        sentence: newSentence,
        demoPhase: frame.isDetecting ? 0 : 1,
      );
      _savedState = newState;
      state = newState;
    });

    _statusSub = streamService.connectionStatus.listen((status) {
      final newState = state.copyWith(connectionStatus: status);
      _savedState = newState;
      state = newState;
    });

    _ttsSub = ttsService.isSpeakingStream.listen((speaking) {
      final newState = state.copyWith(isSpeaking: speaking);
      _savedState = newState;
      state = newState;
    });

    ref.onDispose(() {
      _frameSub?.cancel();
      _streamSub?.cancel();
      _statusSub?.cancel();
      _ttsSub?.cancel();
      landmarkService.stop();
      streamService.stop();
    });

    if (isActive && initialState.isScanning) {
      landmarkService.start();
      streamService.start();
    } else {
      landmarkService.stop();
      streamService.stop();
    }

    return initialState;
  }

  void toggleScan() {
    final landmarkService = ref.read(landmarkExtractionServiceProvider);
    final streamService = ref.read(tslStreamServiceProvider);
    final isActive = ref.read(isScannerActiveProvider);
    final newScanning = !state.isScanning;
    if (newScanning && isActive) {
      landmarkService.start();
      streamService.start();
    } else {
      landmarkService.stop();
      streamService.stop();
    }
    final newState = state.copyWith(isScanning: newScanning);
    _savedState = newState;
    state = newState;
  }

  void clearSentence() {
    final newState = state.copyWith(sentence: []);
    _savedState = newState;
    state = newState;
  }

  Future<void> speakSentence() async {
    if (state.sentence.isEmpty || state.isSpeaking) return;
    var newState = state.copyWith(isSpeaking: true);
    _savedState = newState;
    state = newState;
    await ref.read(ttsServiceProvider).speak(state.sentence.join(' '));
    newState = state.copyWith(isSpeaking: false);
    _savedState = newState;
    state = newState;
  }
}

final scannerProvider = NotifierProvider<ScannerNotifier, ScannerState>(ScannerNotifier.new);

/// True when the user is actively viewing a screen with camera recognition
/// (either the Scanner tab at index 0 or an exercise practice screen).
final isScannerActiveProvider = Provider<bool>((ref) {
  final tabIndex = ref.watch(bottomTabIndexProvider);
  final mountOverride = ref.watch(cameraMountOverrideProvider);
  return tabIndex == 0 || mountOverride;
});

/// Latest raw landmark frame while scanning (frozen on pause), fed by
/// [ScannerNotifier]'s frame subscription. Deliberately OUTSIDE ScannerState:
/// it updates ~12x/s, and anything watching the whole scanner state would
/// rebuild — and, with the camera platform view merging Flutter's raster
/// thread onto the main thread, re-raster — the entire screen at that rate,
/// starving MediaPipe's GPU inference (measured 7fps vs the 12fps target on
/// a Redmi Note 12 5G). Watch this only from the skeleton overlay.
class CurrentFrameNotifier extends Notifier<RawLandmarkFrame?> {
  @override
  RawLandmarkFrame? build() => null;

  void set(RawLandmarkFrame frame) => state = frame;
}

final currentFrameProvider =
    NotifierProvider<CurrentFrameNotifier, RawLandmarkFrame?>(
        CurrentFrameNotifier.new);

/// Requests the native camera preview to mount even though the scanner tab
/// is not the visible tab. Set by full-screen flows outside the tab shell
/// that reuse the scanner pipeline (e.g. the Learn tab's exercise practice
/// screen) and released when they close.
class CameraMountOverride extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final cameraMountOverrideProvider =
    NotifierProvider<CameraMountOverride, bool>(CameraMountOverride.new);

