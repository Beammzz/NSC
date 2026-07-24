import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:restart_app/restart_app.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

abstract class ShorebirdService {
  bool isShorebirdAvailable();
  Future<int?> readCurrentPatch();
  Future<bool> checkForUpdate();
  Future<void> downloadUpdate({void Function(double progress)? onProgress});
  Future<void> restartApp();
}

class DefaultShorebirdService implements ShorebirdService {
  final ShorebirdUpdater _updater;

  DefaultShorebirdService({ShorebirdUpdater? updater})
      : _updater = updater ?? ShorebirdUpdater();

  @override
  bool isShorebirdAvailable() {
    return _updater.isAvailable;
  }

  @override
  Future<int?> readCurrentPatch() async {
    final patch = await _updater.readCurrentPatch();
    return patch?.number;
  }

  @override
  Future<bool> checkForUpdate() async {
    final status = await _updater.checkForUpdate();
    return status == UpdateStatus.outdated;
  }

  @override
  Future<void> downloadUpdate({void Function(double progress)? onProgress}) async {
    // Simulate progressive status while awaiting Shorebird update download
    Timer? timer;
    double currentProgress = 0.1;
    if (onProgress != null) {
      onProgress(currentProgress);
      timer = Timer.periodic(const Duration(milliseconds: 300), (t) {
        if (currentProgress < 0.9) {
          currentProgress += 0.1;
          onProgress(currentProgress);
        }
      });
    }

    try {
      await _updater.update();
    } finally {
      timer?.cancel();
    }

    if (onProgress != null) {
      onProgress(1.0);
    }
  }

  @override
  Future<void> restartApp() async {
    await Restart.restartApp();
  }
}

enum OtaStatus {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  readyToRestart,
  error,
}

class OtaUpdateState {
  final bool isAvailable;
  final int? currentPatch;
  final OtaStatus status;
  final double downloadProgress;
  final String? errorMessage;

  const OtaUpdateState({
    this.isAvailable = false,
    this.currentPatch,
    this.status = OtaStatus.idle,
    this.downloadProgress = 0.0,
    this.errorMessage,
  });

  OtaUpdateState copyWith({
    bool? isAvailable,
    int? Function()? currentPatch,
    OtaStatus? status,
    double? downloadProgress,
    String? Function()? errorMessage,
  }) {
    return OtaUpdateState(
      isAvailable: isAvailable ?? this.isAvailable,
      currentPatch: currentPatch != null ? currentPatch() : this.currentPatch,
      status: status ?? this.status,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      errorMessage: errorMessage != null ? errorMessage() : this.errorMessage,
    );
  }
}

final shorebirdServiceProvider = Provider<ShorebirdService>((ref) {
  return DefaultShorebirdService();
});

class OtaUpdateNotifier extends Notifier<OtaUpdateState> {
  late ShorebirdService _service;

  @override
  OtaUpdateState build() {
    _service = ref.watch(shorebirdServiceProvider);
    final available = _service.isShorebirdAvailable();
    if (available) {
      Future.microtask(() => checkPatchVersionAndStatus());
    }
    return OtaUpdateState(isAvailable: available);
  }

  Future<void> checkPatchVersionAndStatus() async {
    if (!state.isAvailable) return;
    if (ref.mounted) {
      state = state.copyWith(status: OtaStatus.checking, errorMessage: () => null);
    }
    try {
      final patchNum = await _service.readCurrentPatch();
      final hasUpdate = await _service.checkForUpdate();
      if (!ref.mounted) return;
      state = state.copyWith(
        currentPatch: () => patchNum,
        status: hasUpdate ? OtaStatus.updateAvailable : OtaStatus.upToDate,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        status: OtaStatus.error,
        errorMessage: () => e.toString(),
      );
    }
  }

  Future<void> downloadUpdate() async {
    if (state.status == OtaStatus.downloading) return;
    if (ref.mounted) {
      state = state.copyWith(
        status: OtaStatus.downloading,
        downloadProgress: 0.0,
        errorMessage: () => null,
      );
    }
    try {
      await _service.downloadUpdate(
        onProgress: (progress) {
          if (ref.mounted) {
            state = state.copyWith(downloadProgress: progress);
          }
        },
      );
      if (!ref.mounted) return;
      state = state.copyWith(
        status: OtaStatus.readyToRestart,
        downloadProgress: 1.0,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(
        status: OtaStatus.error,
        errorMessage: () => 'Failed to download update: $e',
      );
    }
  }

  Future<void> restartApp() async {
    await _service.restartApp();
  }
}

final otaUpdateProvider = NotifierProvider<OtaUpdateNotifier, OtaUpdateState>(
  OtaUpdateNotifier.new,
);
