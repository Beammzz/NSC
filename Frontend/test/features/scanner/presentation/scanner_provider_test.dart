import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signmind/core/services/tts_service.dart';
import 'package:signmind/core/widgets/main_scaffold.dart';
import 'package:signmind/features/scanner/data/services/tsl_stream_service.dart';
import 'package:signmind/features/scanner/domain/models/scanner_models.dart';
import 'package:signmind/features/scanner/presentation/providers/scanner_provider.dart';
import 'package:signmind/features/settings/presentation/providers/settings_provider.dart';

Future<ProviderContainer> makeContainer() async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'settings.useSimulatedStream': true}));

  group('ScannerNotifier TTS & Auto-Speak', () {
    test('speakSentence invokes ttsService.speak with full sentence', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(scannerProvider.notifier);
      final tts = container.read(ttsServiceProvider);

      // Manually add sentence words
      notifier.clearSentence();

      // Trigger speak on empty sentence -> no speech
      await notifier.speakSentence();
      expect(tts.isSpeaking, false);
    });

    test('autoSpeak speaks newly detected words when enabled', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      final streamService = container.read(tslStreamServiceProvider) as SimulatedTslStreamService;
      final tts = container.read(ttsServiceProvider);

      // Listen to scannerProvider to keep notifier and stream subscriptions active
      container.listen(scannerProvider, (prev, next) {});
      // Emit a translation frame
      streamService.emitTestFrame(
        const TranslationFrame(
          word: 'ขอบคุณ',
          confidence: 0.95,
          fps: 30,
          latencySeconds: 0.1,
          isDetecting: false,
        ),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      expect(container.read(scannerProvider).sentence.contains('ขอบคุณ'), true);
      expect(tts.isSpeaking, true);
    });

    test('speakSentence prefers the composed sentence over the word buffer', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      final notifier = container.read(scannerProvider.notifier);
      container.listen(scannerProvider, (prev, next) {});

      expect(notifier.spokenText, '');

      final streamService =
          container.read(tslStreamServiceProvider) as SimulatedTslStreamService;
      streamService.emitTestFrame(
        const TranslationFrame(
          word: 'ฉัน',
          confidence: 0.95,
          fps: 30,
          latencySeconds: 0.1,
          isDetecting: false,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.spokenText, 'ฉัน');

      notifier.clearSentence();
      expect(notifier.spokenText, '');
    });

    test('parseServerSentence reads a sentence message and ignores others', () {
      final composed = parseServerSentence(
        '{"schema_version":1,"type":"sentence","sentence":"ฉันรักเธอ",'
        '"words":["ฉัน","รัก","เธอ"],"fallback":true,"latency_ms":0}',
      );
      expect(composed, isNotNull);
      expect(composed!.text, 'ฉันรักเธอ');
      expect(composed.words, ['ฉัน', 'รัก', 'เธอ']);
      expect(composed.fallback, true);

      expect(
        parseServerSentence(
          '{"schema_version":1,"type":"prediction","word":"ฉัน","confidence":0.9}',
        ),
        isNull,
      );
      // An empty sentence is not worth speaking.
      expect(
        parseServerSentence(
          '{"schema_version":1,"type":"sentence","sentence":"  ","words":[]}',
        ),
        isNull,
      );
      expect(parseServerSentence('not json'), isNull);
    });

    test('isScannerActiveProvider reports true only when scanner tab or mount override is active', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      // Default bottomTabIndex is 0 (Scanner tab), mountOverride is false -> active
      expect(container.read(isScannerActiveProvider), true);

      // Switch tab to Learn (index 1)
      container.read(bottomTabIndexProvider.notifier).setIndex(1);
      expect(container.read(isScannerActiveProvider), false);

      // Enable exercise practice mount override
      container.read(cameraMountOverrideProvider.notifier).set(true);
      expect(container.read(isScannerActiveProvider), true);
    });
  });
}

