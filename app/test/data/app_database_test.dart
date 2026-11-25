import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/core/protocol/protocol_constants.dart';
import 'package:pomodoro/data/local/app_database.dart';
import 'package:pomodoro/data/local/preferences_store.dart';
import 'package:pomodoro/data/models/session_log.dart';
import 'package:pomodoro/data/models/todo_item.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppDatabase & SessionLogRecord', () {
    test('deduplicates repeated logs idempotently and estimates start == 0',
        () async {
      final db = InMemoryAppDatabase();
      const unclocked = SessionLog(
        logId: 1,
        startEpoch: 0,
        durationSeconds: 1500,
        type: SessionType.focus,
        result: SessionResult.completed,
        todoId: BleProtocolConstants.unboundTodoId,
      );

      final firstInsert = await db.insertSessionLogIdempotent(
        unclocked,
        nowEpochSeconds: 1700001500,
      );
      expect(firstInsert, isTrue);

      // Simulate BLE ACK dropped and device resends same rawLog later.
      final duplicateInsert = await db.insertSessionLogIdempotent(
        unclocked,
        nowEpochSeconds: 1700009999,
      );
      expect(duplicateInsert, isFalse);

      // Distinct logId with start == 0 inserts separately.
      const secondUnclocked = SessionLog(
        logId: 2,
        startEpoch: 0,
        durationSeconds: 1500,
        type: SessionType.focus,
        result: SessionResult.completed,
        todoId: BleProtocolConstants.unboundTodoId,
      );
      expect(
        await db.insertSessionLogIdempotent(
          secondUnclocked,
          nowEpochSeconds: 1700003000,
        ),
        isTrue,
      );

      final rows = await db.fetchAllSessionLogs();
      expect(rows, hasLength(2));
      expect(rows.first.log.logId, 2);
      expect(rows.last.log.logId, 1);
      expect(rows.last.log.startEpoch, 1700000000);
      expect(rows.last.log.isEstimatedTime, isTrue);
      expect(rows.last.displayTodoTitle, '自由專注');
    });

    test('preserves cached To-Do title snapshot even if To-Do is deleted later',
        () async {
      final db = InMemoryAppDatabase();
      await db.upsertKnownTodo(
        const TodoItem(index: 0, id: 7, title: 'WritePaper', done: false),
      );

      const log = SessionLog(
        logId: 3,
        startEpoch: 1700005000,
        durationSeconds: 1200,
        type: SessionType.focus,
        result: SessionResult.completed,
        todoId: 7,
      );
      await db.insertSessionLogIdempotent(log, nowEpochSeconds: 1700006200);

      // Even if todo_id 7 were later overwritten in known_todos, snapshot stays intact.
      await db.upsertKnownTodo(
        const TodoItem(index: 0, id: 7, title: 'ReusedSlotTitle', done: false),
      );

      final rows = await db.fetchAllSessionLogs();
      expect(rows, hasLength(1));
      expect(rows.single.log.isEstimatedTime, isFalse);
      expect(rows.single.displayTodoTitle, 'WritePaper');

      // Unknown todoId falls back gracefully.
      const orphanLog = SessionLog(
        logId: 4,
        startEpoch: 1700007000,
        durationSeconds: 300,
        type: SessionType.breakSession,
        result: SessionResult.aborted,
        todoId: 99,
      );
      await db.insertSessionLogIdempotent(
        orphanLog,
        nowEpochSeconds: 1700007300,
      );
      final updatedRows = await db.fetchAllSessionLogs();
      expect(updatedRows.first.displayTodoTitle, '待辦 #99');
    });
  });

  group('SharedPreferencesStore', () {
    test('persists and clears device and preference keys', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      final store = SharedPreferencesStore(prefs);

      expect(store.isMockBleMode, isTrue);
      expect(store.lastDeviceId, isNull);
      expect(store.dndEnabled, isFalse);
      expect(store.appLockEnabled, isFalse);
      expect(store.blacklistedPackages, isEmpty);

      await store.setLastDeviceId('AA:BB:CC:DD:EE:FF');
      await store.setLastDeviceName('SmartPomodoro-01');
      await store.setMockBleMode(false);
      await store.setDndEnabled(true);
      await store.setAppLockEnabled(true);
      await store.setBlacklistedPackages(<String>['com.instagram.android']);

      expect(store.lastDeviceId, 'AA:BB:CC:DD:EE:FF');
      expect(store.lastDeviceName, 'SmartPomodoro-01');
      expect(store.isMockBleMode, isFalse);
      expect(store.dndEnabled, isTrue);
      expect(store.appLockEnabled, isTrue);
      expect(store.blacklistedPackages, <String>['com.instagram.android']);

      await store.setLastDeviceId(null);
      expect(store.lastDeviceId, isNull);
    });
  });
}
