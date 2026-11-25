import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/protocol/protocol_exceptions.dart';
import '../data/ble/ble_repository.dart';
import '../data/models/device_config.dart';
import 'ble_providers.dart';

/// Immutable state for Phase 1 device configuration (`cmd 100~101`).
class ConfigState {
  const ConfigState({
    this.config = const DeviceConfig.defaults(),
    this.isConnected = false,
    this.isLoading = false,
    this.isSaving = false,
    this.errorMessage,
  });

  final DeviceConfig config;
  final bool isConnected;
  final bool isLoading;
  final bool isSaving;
  final String? errorMessage;

  bool get isLocked => !isConnected || isLoading || isSaving;

  ConfigState copyWith({
    DeviceConfig? config,
    bool? isConnected,
    bool? isLoading,
    bool? isSaving,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ConfigState(
      config: config ?? this.config,
      isConnected: isConnected ?? this.isConnected,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Manages Phase 1 device configuration read/write (`CMD_CFG_GET` / `CMD_CFG_SET`).
class ConfigController extends Notifier<ConfigState> {
  StreamSubscription<BleConnectionSnapshot>? _connectionSub;
  bool _disposed = false;
  @override
  ConfigState build() {
    _disposed = false;
    final repo = ref.watch(bleRepositoryProvider);
    final initialConnected = repo.currentConnection.state.isConnected;

    _connectionSub?.cancel();
    _connectionSub = repo.connectionStream.listen(_onConnectionChanged);

    ref.onDispose(() {
      _disposed = true;
      _connectionSub?.cancel();
    });

    return ConfigState(isConnected: initialConnected);
  }

  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  Future<bool> loadConfig() async {
    if (_disposed) return false;
    final repo = ref.read(bleRepositoryProvider);
    if (!repo.currentConnection.state.isConnected) return false;

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final fetched = await repo.getConfig();
      if (_disposed) return false;
      state = state.copyWith(config: fetched, isLoading: false);
      return true;
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return false;
      state = state.copyWith(isLoading: false, errorMessage: e.message);
      return false;
    }
  }

  Future<bool> saveConfig(DeviceConfig nextConfig) async {
    if (state.isLocked) return false;
    try {
      nextConfig.validate();
    } on PacketValidationException catch (e) {
      state = state.copyWith(errorMessage: e.message);
      return false;
    }

    final repo = ref.read(bleRepositoryProvider);
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await repo.setConfig(nextConfig);
      if (_disposed) return false;
      state = state.copyWith(config: nextConfig, isSaving: false);
      return true;
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return false;
      state = state.copyWith(isSaving: false, errorMessage: e.message);
      return false;
    }
  }

  void _onConnectionChanged(BleConnectionSnapshot snapshot) {
    if (_disposed) return;
    final isNowConnected = snapshot.state.isConnected;
    if (state.isConnected != isNowConnected) {
      state = state.copyWith(isConnected: isNowConnected);
    }
  }
}

final configControllerProvider =
    NotifierProvider<ConfigController, ConfigState>(
  ConfigController.new,
);
