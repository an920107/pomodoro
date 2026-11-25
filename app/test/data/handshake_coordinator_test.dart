import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/core/protocol/protocol_constants.dart';
import 'package:pomodoro/data/ble/handshake_coordinator.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/data/local/app_database.dart';
import 'package:pomodoro/data/models/device_status.dart';
import 'package:pomodoro/data/models/todo_item.dart';

void main() {
  group('HandshakeCoordinator (§4.2 5-step sequence & Step 5 sync)', () {
    late AppLogger logger;
    late MockBleRepository mockRepo;
    late InMemoryAppDatabase database;

    setUp(() {
      logger = AppLogger(printer: (_) {});
      mockRepo = MockBleRepository(
        nvsStore: InMemoryMockNvsStore(),
        logger: logger,
      );
      database = InMemoryAppDatabase();
    });

    tearDown(() async {
      await database.close();
      mockRepo.dispose();
      logger.dispose();
    });

    test('executes Steps 3 -> 4 -> 5 in strict protocol order on reconnect',
        () async {
      final statusSnapshots = <DeviceStatus>[];
      var historyNotifyCount = 0;

      final coordinator = HandshakeCoordinator(
        repository: mockRepo,
        database: database,
        nowEpochSeconds: () => 1700010000,
        tzOffsetSeconds: () => 28800,
        onStatusSynced: statusSnapshots.add,
        onLoadConfig: () => mockRepo.getConfig(),
        onLoadTodos: () async {
          final meta = await mockRepo.getTodoLength();
          final items = <TodoItem>[];
          for (var i = 0; i < meta.length; i++) {
            items.add(await mockRepo.getTodoItem(i));
          }
          return items;
        },
        onHistorySynced: () async {
          historyNotifyCount++;
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();

      // Wait for initial startup handshake to settle cleanly.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      logger.clear();

      // Disconnect, inject an unclocked offline log bound to todo id 1, then reconnect.
      mockRepo.simulateDisconnect();
      mockRepo.injectOfflineSessionLog(
        startEpoch: 0,
        durationSeconds: 1500,
        type: SessionType.focus,
        result: SessionResult.completed,
        todoId: 1,
      );
      expect(mockRepo.debugUnsyncedCount, 1);

      await mockRepo.simulateReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Queue drained on virtual ESP32 and saved idempotently to DB.
      expect(mockRepo.debugUnsyncedCount, 0);
      expect(historyNotifyCount, 1);
      expect(statusSnapshots.last.unsyncedCount, 1);

      final logs = await database.fetchAllSessionLogs();
      expect(logs, hasLength(1));
      expect(logs.single.log.isEstimatedTime, isTrue);
      expect(logs.single.log.startEpoch, 1700010000 - 1500);
      expect(logs.single.displayTodoTitle, 'Read Embedded Spec');

      // Check strict Step 3 -> Step 4 -> Step 5 BLE TX command order.
      final txCommands = logger.entries
          .where((e) => e.category == LogCategory.bleTx)
          .map((e) => e.message)
          .toList();
      expect(
        txCommands,
        <String>[
          '{"cmd":10,"data":{"epoch":1700010000,"tz":28800}}',
          '{"cmd":100,"data":{}}',
          '{"cmd":200,"data":{}}',
          '{"cmd":201,"data":{"i":0}}',
          '{"cmd":201,"data":{"i":1}}',
          '{"cmd":300,"data":{}}',
          '{"cmd":301,"data":{"log_id":1}}',
        ],
      );

      // Re-running Step 5 when queue is empty handles ERR_HIST_EMPTY gracefully.
      final extra = await coordinator.syncPendingHistory();
      expect(extra, 0);
      expect(await database.fetchAllSessionLogs(), hasLength(1));
    });

    test('syncPendingHistory drains multiple offline logs without overlapping loops',
        () async {
      final coordinator = HandshakeCoordinator(
        repository: mockRepo,
        database: database,
        nowEpochSeconds: () => 1700020000,
        tzOffsetSeconds: () => 28800,
        onLoadConfig: () => mockRepo.getConfig(),
        onLoadTodos: () async => const <TodoItem>[],
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      mockRepo.injectOfflineSessionLog(startEpoch: 1700015000, durationSeconds: 900);
      mockRepo.injectOfflineSessionLog(startEpoch: 0, durationSeconds: 1500);
      expect(mockRepo.debugUnsyncedCount, 2);

      // Fire overlapping calls concurrently; mutex must serialize cleanly.
      final results = await Future.wait<int>(<Future<int>>[
        coordinator.syncPendingHistory(),
        coordinator.syncPendingHistory(),
      ]);

      expect(results.reduce((a, b) => a + b), 2);
      expect(mockRepo.debugUnsyncedCount, 0);
      final logs = await database.fetchAllSessionLogs();
      expect(logs, hasLength(2));
    });
  });
}
