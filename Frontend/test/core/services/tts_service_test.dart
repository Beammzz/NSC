import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/core/services/tts_service.dart';

void main() {
  group('SimulatedTtsService', () {
    late SimulatedTtsService service;

    setUp(() {
      service = SimulatedTtsService();
    });

    tearDown(() {
      service.dispose();
    });

    test('initial state is not speaking', () {
      expect(service.isSpeaking, false);
    });

    test('speak updates isSpeaking state and emits events', () async {
      expectLater(
        service.isSpeakingStream,
        emitsInOrder([true, false]),
      );

      await service.speak('สวัสดี');
      expect(service.isSpeaking, true);

      await Future.delayed(const Duration(milliseconds: 700));
      expect(service.isSpeaking, false);
    });

    test('stop cancels speech early', () async {
      await service.speak('สวัสดี');
      expect(service.isSpeaking, true);

      await service.stop();
      expect(service.isSpeaking, false);
    });

    test('ignores empty text', () async {
      await service.speak('   ');
      expect(service.isSpeaking, false);
    });
  });
}
