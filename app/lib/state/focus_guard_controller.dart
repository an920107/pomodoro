import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/app_logger.dart';
import '../core/protocol/protocol_constants.dart';
import '../data/native/focus_guard_service.dart';
import 'ble_providers.dart';
import 'pomodoro_controller.dart';

/// Platform FocusGuard service provider; overridden in `main.dart` with
/// [MethodChannelFocusGuardService] for Android devices.
final focusGuardServiceProvider = Provider<FocusGuardPlatformService>(
  (ref) => const NoOpFocusGuardService(),
);

/// Immutable state rendered by [FocusGuardScreen] and tracked by
/// [FocusGuardController].
class FocusGuardState {
  const FocusGuardState({
    this.permissions = const FocusGuardPermissions(),
    this.dndEnabled = false,
    this.appLockEnabled = false,
    this.blacklistedPackages = const <String>[],
    this.installedApps = const <InstalledAppInfo>[],
    this.isLoadingApps = false,
    this.isGuardActive = false,
    this.errorMessage,
  });

  final FocusGuardPermissions permissions;
  final bool dndEnabled;
  final bool appLockEnabled;
  final List<String> blacklistedPackages;
  final List<InstalledAppInfo> installedApps;
  final bool isLoadingApps;
  final bool isGuardActive;
  final String? errorMessage;

  bool get hasAnyProtectionConfigured =>
      dndEnabled || (appLockEnabled && blacklistedPackages.isNotEmpty);

  FocusGuardState copyWith({
    FocusGuardPermissions? permissions,
    bool? dndEnabled,
    bool? appLockEnabled,
    List<String>? blacklistedPackages,
    List<InstalledAppInfo>? installedApps,
    bool? isLoadingApps,
    bool? isGuardActive,
    String? errorMessage,
    bool clearError = false,
  }) {
    return FocusGuardState(
      permissions: permissions ?? this.permissions,
      dndEnabled: dndEnabled ?? this.dndEnabled,
      appLockEnabled: appLockEnabled ?? this.appLockEnabled,
      blacklistedPackages: blacklistedPackages ?? this.blacklistedPackages,
      installedApps: installedApps ?? this.installedApps,
      isLoadingApps: isLoadingApps ?? this.isLoadingApps,
      isGuardActive: isGuardActive ?? this.isGuardActive,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Synchronizes [PomodoroController] state machine and safety-valve countdown
/// with the native Android [FocusGuardService] (`docs/spec.md` §4.1.2 & §6.2).
class FocusGuardController extends Notifier<FocusGuardState> {
  bool _disposed = false;
  bool _serviceRunning = false;

  @override
  FocusGuardState build() {
    _disposed = false;
    final prefs = ref.watch(preferencesStoreProvider);
    ref.watch(focusGuardServiceProvider);

    ref.listen<PomodoroViewState>(pomodoroControllerProvider, (prev, next) {
      if (_disposed) return;
      unawaited(_syncWithPomodoro(next));
    });

    ref.onDispose(() {
      _disposed = true;
    });

    Future<void>.microtask(refreshPermissions);

    return FocusGuardState(
      dndEnabled: prefs.dndEnabled,
      appLockEnabled: prefs.appLockEnabled,
      blacklistedPackages: prefs.blacklistedPackages,
    );
  }

  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  Future<void> refreshPermissions() async {
    if (_disposed) return;
    try {
      final permissions = await ref
          .read(focusGuardServiceProvider)
          .checkPermissions();
      if (_disposed) return;
      state = state.copyWith(permissions: permissions);
    } on PlatformException catch (e) {
      if (_disposed) return;
      state = state.copyWith(errorMessage: e.message ?? '無法檢查守護權限狀態');
    }
  }

  Future<void> openPermissionSettings(FocusPermissionKind kind) async {
    try {
      await ref.read(focusGuardServiceProvider).openPermissionSettings(kind);
    } on PlatformException catch (e) {
      if (_disposed) return;
      state = state.copyWith(errorMessage: e.message ?? '無法開啟系統授權設定頁');
    }
  }

  Future<void> loadInstalledApps() async {
    if (_disposed || state.isLoadingApps) return;
    state = state.copyWith(isLoadingApps: true, clearError: true);
    try {
      final apps = await ref.read(focusGuardServiceProvider).getInstalledApps();
      if (_disposed) return;
      state = state.copyWith(
        installedApps: List<InstalledAppInfo>.unmodifiable(apps),
        isLoadingApps: false,
      );
    } on PlatformException catch (e) {
      if (_disposed) return;
      state = state.copyWith(
        isLoadingApps: false,
        errorMessage: e.message ?? '讀取已安裝應用程式清單失敗',
      );
    }
  }

  Future<void> setDndEnabled(bool enabled) async {
    state = state.copyWith(dndEnabled: enabled);
    await ref.read(preferencesStoreProvider).setDndEnabled(enabled);
    if (_disposed) return;
    await _syncWithPomodoro(ref.read(pomodoroControllerProvider));
  }

  Future<void> setAppLockEnabled(bool enabled) async {
    state = state.copyWith(appLockEnabled: enabled);
    await ref.read(preferencesStoreProvider).setAppLockEnabled(enabled);
    if (_disposed) return;
    await _syncWithPomodoro(ref.read(pomodoroControllerProvider));
  }

  Future<void> toggleBlacklistedPackage(String packageName) async {
    final nextList = List<String>.from(state.blacklistedPackages);
    if (nextList.contains(packageName)) {
      nextList.remove(packageName);
    } else {
      nextList.add(packageName);
    }
    final frozen = List<String>.unmodifiable(nextList);
    state = state.copyWith(blacklistedPackages: frozen);
    await ref.read(preferencesStoreProvider).setBlacklistedPackages(frozen);
    if (_disposed) return;
    await _syncWithPomodoro(ref.read(pomodoroControllerProvider));
  }

  bool _shouldEngage(PomodoroViewState view) {
    if (view.isConnected) {
      return view.status.state == PomodoroState.focusRunning &&
          view.status.remainingSeconds > 0;
    }
    return view.isSafetyValveActive && !view.safetyValveTripped;
  }

  Future<void> _syncWithPomodoro(PomodoroViewState view) async {
    if (_disposed) return;
    final service = ref.read(focusGuardServiceProvider);
    final engage = _shouldEngage(view) && state.hasAnyProtectionConfigured;

    if (engage) {
      final isRepoConnected =
          ref.read(bleRepositoryProvider).currentConnection.state.isConnected;
      if (!view.isConnected || !isRepoConnected) {
        // Offline safety valve (or disconnect in flight): leave the native
        // SystemClock deadline untouched so Android releases protections
        // autonomously when expired.
        return;
      }

      final wasRunning = _serviceRunning;
      _serviceRunning = true;
      if (!state.isGuardActive) {
        state = state.copyWith(isGuardActive: true);
      }
      if (!wasRunning) {
        AppLogger.instance.guard(
          'Engaged FocusGuard (rem=${view.status.remainingSeconds}s, dnd=${state.dndEnabled}, appLock=${state.appLockEnabled}, apps=${state.blacklistedPackages.length})',
        );
      }
      try {
        await service.startOrUpdateGuard(
          remainingSeconds: view.status.remainingSeconds,
          dndEnabled: state.dndEnabled,
          appLockEnabled: state.appLockEnabled,
          blacklistedPackages: state.blacklistedPackages,
          taskTitle: view.boundTodoTitle,
        );
      } on PlatformException catch (e) {
        if (!_disposed) {
          state = state.copyWith(errorMessage: e.message ?? '啟動專注守護服務失敗');
        }
      }
      return;
    }

    if (_serviceRunning || state.isGuardActive) {
      _serviceRunning = false;
      state = state.copyWith(isGuardActive: false);
      AppLogger.instance.guard(
        'Released FocusGuard (state=${view.status.state.specName}, connected=${view.isConnected}, tripped=${view.safetyValveTripped})',
      );
      try {
        await service.stopGuard();
      } on PlatformException {
        // Best-effort service stop.
      }
    }
  }
}

final focusGuardControllerProvider =
    NotifierProvider<FocusGuardController, FocusGuardState>(
  FocusGuardController.new,
);
