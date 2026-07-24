import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signmind/features/settings/presentation/providers/ota_update_provider.dart';

class FakeShorebirdService implements ShorebirdService {
  bool available;
  int? patchNum;
  bool updateAvailable;
  bool downloadCalled = false;
  bool restartCalled = false;

  FakeShorebirdService({
    this.available = true,
    this.patchNum,
    this.updateAvailable = false,
  });

  @override
  bool isShorebirdAvailable() => available;

  @override
  Future<int?> readCurrentPatch() async => patchNum;

  @override
  Future<bool> checkForUpdate() async => updateAvailable;

  @override
  Future<void> downloadUpdate({void Function(double progress)? onProgress}) async {
    downloadCalled = true;
    onProgress?.call(0.5);
    await Future.delayed(const Duration(milliseconds: 10));
    onProgress?.call(1.0);
  }

  @override
  Future<void> restartApp() async {
    restartCalled = true;
  }
}

void main() {
  test('OtaUpdateProvider initializes with isAvailable false when Shorebird is unavailable', () async {
    final fakeService = FakeShorebirdService(available: false);
    final container = ProviderContainer(
      overrides: [
        shorebirdServiceProvider.overrideWithValue(fakeService),
      ],
    );
    addTearDown(container.dispose);

    final state = container.read(otaUpdateProvider);
    expect(state.isAvailable, isFalse);
    expect(state.status, OtaStatus.idle);
  });

  test('OtaUpdateProvider detects update availability and current patch number', () async {
    final fakeService = FakeShorebirdService(
      available: true,
      patchNum: 2,
      updateAvailable: true,
    );
    final container = ProviderContainer(
      overrides: [
        shorebirdServiceProvider.overrideWithValue(fakeService),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(otaUpdateProvider.notifier);
    await notifier.checkPatchVersionAndStatus();

    final state = container.read(otaUpdateProvider);
    expect(state.isAvailable, isTrue);
    expect(state.currentPatch, 2);
    expect(state.status, OtaStatus.updateAvailable);
  });

  test('OtaUpdateProvider downloadUpdate transitions through downloading to readyToRestart', () async {
    final fakeService = FakeShorebirdService(
      available: true,
      patchNum: 1,
      updateAvailable: true,
    );
    final container = ProviderContainer(
      overrides: [
        shorebirdServiceProvider.overrideWithValue(fakeService),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(otaUpdateProvider.notifier);
    await notifier.checkPatchVersionAndStatus();

    final downloadFuture = notifier.downloadUpdate();
    expect(container.read(otaUpdateProvider).status, OtaStatus.downloading);

    await downloadFuture;
    final finalState = container.read(otaUpdateProvider);
    expect(fakeService.downloadCalled, isTrue);
    expect(finalState.status, OtaStatus.readyToRestart);
    expect(finalState.downloadProgress, 1.0);
  });

  test('OtaUpdateProvider restartApp calls service restartApp', () async {
    final fakeService = FakeShorebirdService(available: true);
    final container = ProviderContainer(
      overrides: [
        shorebirdServiceProvider.overrideWithValue(fakeService),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(otaUpdateProvider.notifier);
    await notifier.restartApp();

    expect(fakeService.restartCalled, isTrue);
  });
}
