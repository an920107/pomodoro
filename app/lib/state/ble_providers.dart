import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/app_logger.dart';
import '../data/ble/ble_client_adapter.dart';
import '../data/ble/ble_repository.dart';
import '../data/ble/handshake_coordinator.dart';
import '../data/ble/mock_ble_repository.dart';
import '../data/ble/mock_nvs_store.dart';
import '../data/ble/real_ble_repository.dart';
import '../data/local/app_database.dart';
import '../data/local/preferences_store.dart';
import '../data/models/device_status.dart';
import 'config_controller.dart';
import 'history_controller.dart';
import 'pomodoro_controller.dart';
import 'todo_controller.dart';

/// Persistence backend for [MockBleRepository]'s simulated NVS.
/// Overridden in `main.dart` with [SharedPreferencesMockNvsStore].
final mockNvsStoreProvider = Provider<MockNvsStore>(
  (ref) => InMemoryMockNvsStore(),
);

/// App-local preference persistence backend.
/// Overridden in `main.dart` with [SharedPreferencesStore].
final preferencesStoreProvider = Provider<PreferencesStore>(
  (ref) => InMemoryPreferencesStore(),
);

/// Local SQLite database persistence backend.
/// Overridden in `main.dart` with [SqliteAppDatabase].
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = InMemoryAppDatabase();
  ref.onDispose(() {
    unawaited(db.close());
  });
  return db;
});

/// Ring-buffer logger provider consumed by [PacketInspectorScreen].
final appLoggerProvider = Provider<AppLogger>((ref) => AppLogger.instance);

/// Controls whether the app uses [MockBleRepository] (default in Phase 1).
class BleModeNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(preferencesStoreProvider).isMockBleMode;

  void setMockMode(bool isMock) {
    final wasMock = state;
    if (wasMock == isMock) return;
    if (isMock && !wasMock) {
      final realRepo = ref.read(realBleRepositoryProvider);
      unawaited(realRepo.stopScan());
      unawaited(realRepo.disconnect());
    }
    state = isMock;
    unawaited(ref.read(preferencesStoreProvider).setMockBleMode(isMock));
  }
}

final isMockBleModeProvider = NotifierProvider<BleModeNotifier, bool>(
  BleModeNotifier.new,
);

/// Singleton virtual ESP32 repository for Mock mode.
final mockBleRepositoryProvider = Provider<MockBleRepository>((ref) {
  final store = ref.watch(mockNvsStoreProvider);
  final repo = MockBleRepository(nvsStore: store);
  ref.onDispose(repo.dispose);
  return repo;
});

/// Platform BLE adapter abstracted for deterministic testing of [RealBleRepository].
final bleClientAdapterProvider = Provider<BleClientAdapter>((ref) {
  final adapter = FlutterBluePlusClientAdapter();
  ref.onDispose(adapter.dispose);
  return adapter;
});

/// Real BLE repository driven by `flutter_blue_plus` when Mock mode is off.
final realBleRepositoryProvider = Provider<RealBleRepository>((ref) {
  final adapter = ref.watch(bleClientAdapterProvider);
  final prefs = ref.watch(preferencesStoreProvider);
  final repo = RealBleRepository(adapter: adapter, preferences: prefs);
  ref.onDispose(repo.dispose);
  return repo;
});

/// Active [BleRepository] implementation consumed by controllers and UI.
final bleRepositoryProvider = Provider<BleRepository>((ref) {
  final isMock = ref.watch(isMockBleModeProvider);
  if (isMock) {
    return ref.watch(mockBleRepositoryProvider);
  }
  return ref.watch(realBleRepositoryProvider);
});

/// Live BLE scan results emitted by the active [BleRepository].
final bleScanResultsProvider = StreamProvider<List<BleDeviceItem>>((ref) {
  final repo = ref.watch(bleRepositoryProvider);
  if (repo is RealBleRepository) {
    return (() async* {
      yield repo.latestFilteredScanResults;
      yield* repo.scanResultsStream;
    })();
  }
  return repo.scanResultsStream;
});

/// Live BLE connection stream seeded immediately with [BleRepository.currentConnection].
final bleConnectionProvider = StreamProvider<BleConnectionSnapshot>((ref) {
  final repo = ref.watch(bleRepositoryProvider);
  return (() async* {
    yield repo.currentConnection;
    yield* repo.connectionStream;
  })();
});

/// Live device status stream seeded with [BleRepository.latestStatus].
final deviceStatusProvider = StreamProvider<DeviceStatus>((ref) {
  final repo = ref.watch(bleRepositoryProvider);
  return (() async* {
    yield repo.latestStatus ?? const DeviceStatus.initial();
    yield* repo.statusStream;
  })();
});

/// Orchestrates the 5-step BLE reconnection handshake and Step 5 history sync.
final handshakeCoordinatorProvider = Provider<HandshakeCoordinator>((ref) {
  final repo = ref.watch(bleRepositoryProvider);
  final database = ref.watch(appDatabaseProvider);
  final coordinator = HandshakeCoordinator(
    repository: repo,
    database: database,
    onStatusSynced: (status) {
      ref.read(pomodoroControllerProvider.notifier).applyDeviceStatus(status);
    },
    onLoadConfig: () =>
        ref.read(configControllerProvider.notifier).loadConfig(),
    onLoadTodos: () =>
        ref.read(todoControllerProvider.notifier).loadTodos(),
    onHistorySynced: () =>
        ref.read(historyControllerProvider.notifier).refresh(),
  );
  ref.onDispose(coordinator.dispose);
  coordinator.start();
  return coordinator;
});
