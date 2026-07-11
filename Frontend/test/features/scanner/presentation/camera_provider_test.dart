import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/scanner/presentation/providers/camera_provider.dart';

void main() {
  // Camera platform channels are absent under `flutter test`; availableCameras()
  // throws MissingPluginException, which the provider must swallow into null so
  // the scanner UI degrades gracefully instead of crashing widget tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cameraControllerProvider yields null when no camera platform exists',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = await container.read(cameraControllerProvider.future);

    expect(controller, isNull);
  });

  test('selectedCameraLensProvider defaults to back and flips to front', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(selectedCameraLensProvider), CameraLensDirection.back);

    container.read(selectedCameraLensProvider.notifier).flip();

    expect(
      container.read(selectedCameraLensProvider),
      CameraLensDirection.front,
    );
  });
}
