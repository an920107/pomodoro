import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/core/protocol/mock_ble_self_check.dart';
import 'package:pomodoro/core/protocol/protocol_constants.dart';
import 'package:pomodoro/core/protocol/protocol_exceptions.dart';
import 'package:pomodoro/data/ble/ble_repository.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/data/models/device_config.dart';

void main() {
  group('MockBleRepository', () {
    late AppLogger logger;
    late InMemoryMockNvsStore nvsStore;
    late MockBleRepository repo;

    setUp(() {
      logger = AppLogger(printer: (_) {});
      nvsStore = InMemoryMockNvsStore();
      repo = MockBleRepository(
        nvsStore: nvsStore,
        logger: logger,
        tickInterval: const Duration(milliseconds: 20),
      );
    });

    tearDown(() {
      repo.dispose();
      logger.dispose();
    });

    test('completes focus countdown, records COMPLETED log, and returns to IDLE',
        () async {
      await repo.syncTime(epochSeconds: 1763970900, tzOffsetSeconds: 28800);
      await repo.setConfig(
        const DeviceConfig.defaults().copyWith(focusMinutes: 1),
      );
      await repo.startFocus(todoId: 2);

      expect(repo.latestStatus?.state, PomodoroState.focusRunning);
      expect(repo.latestStatus?.totalSeconds, 60);
      expect(repo.latestStatus?.todoId, 2);

      repo.fastForwardRemaining(0);
      final status = await repo.readStatus();
      expect(status.state, PomodoroState.idle);
      expect(status.unsyncedCount, 1);

      final log = await repo.peekHistory();
      expect(log, isNotNull);
      expect(log!.type, SessionType.focus);
      expect(log.result, SessionResult.completed);
      expect(log.durationSeconds, 60);
      expect(log.todoId, 2);
      expect(log.startEpoch, greaterThanOrEqualTo(1763970900));

      final remaining = await repo.ackHistory(log.logId);
      expect(remaining, 0);
      expect(await repo.peekHistory(), isNull);
    });

    test('records ABORTED log on stop only when elapsed focus >= 60 seconds',
        () async {
      await repo.setConfig(
        const DeviceConfig.defaults().copyWith(focusMinutes: 5),
      );

      // Stop after 30s (< 60s): no ABORTED log created.
      await repo.startFocus();
      repo.fastForwardRemaining(270);
      await repo.stopTimer();
      expect((await repo.readStatus()).unsyncedCount, 0);

      // Stop after 65s (>= 60s): ABORTED log created with dur=65.
      await repo.startFocus(todoId: 1);
      repo.fastForwardRemaining(235);
      await repo.stopTimer();
      expect((await repo.readStatus()).unsyncedCount, 1);

      final log = await repo.peekHistory();
      expect(log, isNotNull);
      expect(log!.result, SessionResult.aborted);
      expect(log.durationSeconds, 65);
      expect(log.todoId, 1);
    });

    test('handles proximity away/back transitions and protects user pause/break',
        () async {
      await repo.startFocus();
      repo.simulateAway(true);
      expect(repo.latestStatus?.state, PomodoroState.focusPausedAway);

      // Manual resume must fail while auto-paused away.
      await expectLater(
        repo.resumeTimer(),
        throwsA(
          isA<RpcErrorException>()
              .having((e) => e.errCode, 'errCode', ErrCode.invalidState),
        ),
      );

      repo.simulateAway(false);
      expect(repo.latestStatus?.state, PomodoroState.focusRunning);

      // User pause should ignore away->back auto-resume.
      await repo.pauseTimer();
      expect(repo.latestStatus?.state, PomodoroState.focusPausedUser);
      repo.simulateAway(true);
      expect(repo.latestStatus?.state, PomodoroState.focusPausedUser);
      repo.simulateAway(false);
      expect(repo.latestStatus?.state, PomodoroState.focusPausedUser);
      await repo.stopTimer();

      // Break state ignores away detection.
      await repo.startBreak();
      expect(repo.latestStatus?.state, PomodoroState.breakRunning);
      repo.simulateAway(true);
      expect(repo.latestStatus?.state, PomodoroState.breakRunning);
    });

    test('enforces To-Do CRUD, monotonic IDs, 10-item cap, and swap order',
        () async {
      final meta = await repo.getTodoLength();
      expect(meta.length, 2);
      expect(meta.max, 10);

      await repo.deleteTodo(0);
      final afterDelete = await repo.getTodoItem(0);
      expect(afterDelete.id, 2);

      // Fill up to 10 items.
      for (var i = 1; i < 10; i++) {
        await repo.appendTodo('Task $i');
      }
      expect((await repo.getTodoLength()).length, 10);

      await expectLater(
        repo.appendTodo('Task 10'),
        throwsA(
          isA<RpcErrorException>()
              .having((e) => e.errCode, 'errCode', ErrCode.todoFull),
        ),
      );

      await expectLater(
        repo.getTodoItem(10),
        throwsA(
          isA<RpcErrorException>()
              .having((e) => e.errCode, 'errCode', ErrCode.todoOutOfRange),
        ),
      );

      await repo.updateTodo(index: 0, title: 'Updated Head', done: true);
      await repo.swapTodos(0, 1);
      final swapped0 = await repo.getTodoItem(0);
      final swapped1 = await repo.getTodoItem(1);
      expect(swapped0.title, 'Task 1');
      expect(swapped1.title, 'Updated Head');
      expect(swapped1.done, isTrue);
      expect(swapped1.id, 2);
    });

    test('continues countdown offline while disconnected and syncs after reconnect',
        () async {
      await repo.setConfig(
        const DeviceConfig.defaults().copyWith(focusMinutes: 1),
      );
      await repo.startFocus(todoId: 1);

      repo.simulateDisconnect();
      expect(repo.currentConnection.state, BleConnectionState.disconnected);

      await expectLater(
        repo.pauseTimer(),
        throwsA(isA<BleDisconnectedException>()),
      );

      // Finish session while disconnected.
      repo.fastForwardRemaining(0);
      await repo.simulateReconnect();

      final status = await repo.readStatus();
      expect(status.state, PomodoroState.idle);
      expect(status.unsyncedCount, 1);

      final log = await repo.peekHistory();
      expect(log, isNotNull);
      expect(log!.startEpoch, 0);
      expect(log.result, SessionResult.completed);
    });

    test('simulatePowerCycle persists NVS config/todos while resetting clock & timer',
        () async {
      await repo.syncTime(epochSeconds: 1763970900, tzOffsetSeconds: 28800);
      await repo.setConfig(
        const DeviceConfig(
          focusMinutes: 40,
          breakMinutes: 10,
          mute: true,
          awayCm: 95,
          awayGraceSeconds: 7,
        ),
      );
      await repo.appendTodo('Persisted Item');
      await repo.swapTodos(0, 2);
      await repo.startFocus();

      await repo.simulatePowerCycle();

      expect(repo.isClockSynced, isFalse);
      final status = await repo.readStatus();
      expect(status.state, PomodoroState.idle);

      final cfg = await repo.getConfig();
      expect(cfg.focusMinutes, 40);
      expect(cfg.mute, isTrue);
      expect(cfg.awayCm, 95);

      final firstTodo = await repo.getTodoItem(0);
      expect(firstTodo.title, 'Persisted Item');
    });

    test('runMockBleSelfCheck passes cleanly', () async {
      final summary = await runMockBleSelfCheck(logger: logger);
      expect(summary, contains('通過'));
    });
  });
}
