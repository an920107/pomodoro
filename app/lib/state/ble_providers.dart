import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ble/ble_repository.dart';
import '../data/ble/mock_ble_repository.dart';
import '../data/ble/mock_nvs_store.dart';
import '../data/models/device_status.dart';

/// Persistence backend for [MockBleRepository]'s simulated NVS.
/// Overridden in `main.dart` with [SharedPreferencesMockNvsStore].
final mockNvsStoreProvider = Provider<MockNvsStore>(
  (ref) => InMemoryMockNvsStore(),
);

/// Controls whether the app uses [MockBleRepository] (default in Phase 1).
class BleModeNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setMockMode(bool isMock) {
    state = isMock;
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
