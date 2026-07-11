import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/core/services/stt_service.dart';

void main() {
  group('SimulatedSttService', () {
    late SimulatedSttService service;

    setUp(() {
      service = SimulatedSttService();
    });

    tearDown(() {
      service.dispose();
    });

    test('initialize returns true', () async {
      final res = await service.initialize();
      expect(res, true);
    });

    test('startListening emits true and delivers simulated speech', () async {
      String? recognized;
      double? conf;

      await service.startListening(
        onResult: (text, confidence) {
          recognized = text;
          conf = confidence;
        },
      );

      expect(service.isListening, true);

      service.simulateSpeech('สวัสดีครับ', 0.94);
      expect(recognized, 'สวัสดีครับ');
      expect(conf, 0.94);
    });

    test('stopListening sets isListening false', () async {
      await service.startListening(onResult: (t, c) {});
      expect(service.isListening, true);

      await service.stopListening();
      expect(service.isListening, false);
    });
  });
}
