import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ble/ble_repository.dart';
import '../data/ble/handshake_coordinator.dart';
import '../data/ble/mock_ble_repository.dart';
import '../data/ble/mock_nvs_store.dart';
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

/// Controls whether the app uses [MockBleRepository] (default in Phase 1).
class BleModeNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(preferencesStoreProvider).isMockBleMode;

  void setMockMode(bool isMock) {
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

/// Active [BleRepository] implementation consumed by controllers and UI.
final bleRepositoryProvider = Provider<BleRepository>((ref) {
  ref.watch(isMockBleModeProvider);
  return ref.watch(mockBleRepositoryProvider);
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
