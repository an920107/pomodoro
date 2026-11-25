import 'dart:async';

import '../../core/logging/app_logger.dart';
import '../../core/protocol/protocol_exceptions.dart';
import '../local/app_database.dart';
import '../models/device_status.dart';
import '../models/todo_item.dart';
import 'ble_repository.dart';

/// Orchestrates the 5-step BLE reconnection handshake (`docs/spec.md` §4.2)
/// and idempotent history synchronization (`CMD_HIST_PEEK` -> DB -> `CMD_HIST_ACK`).
class HandshakeCoordinator {
  HandshakeCoordinator({
    required this._repository,
    required this._database,
    this.onStatusSynced,
    this.onLoadConfig,
    this.onLoadTodos,
    this.onHistorySynced,
    int Function()? nowEpochSeconds,
    int Function()? tzOffsetSeconds,
  }) : _nowEpochSeconds =
           nowEpochSeconds ??
           (() => DateTime.now().millisecondsSinceEpoch ~/ 1000),
       _tzOffsetSeconds =
           tzOffsetSeconds ?? (() => DateTime.now().timeZoneOffset.inSeconds);

  final BleRepository _repository;
  final AppDatabase _database;
  final void Function(DeviceStatus status)? onStatusSynced;
  final Future<void> Function()? onLoadConfig;
  final Future<List<TodoItem>> Function()? onLoadTodos;
  final Future<void> Function()? onHistorySynced;
  final int Function() _nowEpochSeconds;
  final int Function() _tzOffsetSeconds;

  StreamSubscription<BleConnectionSnapshot>? _connectionSub;
  StreamSubscription<DeviceStatus>? _statusSub;
  bool _started = false;
  bool _disposed = false;
  bool _wasConnected = false;
  bool _isHandshaking = false;
  bool _isHandshakeSynced = false;
  bool _isSyncingHistory = false;
  Future<void>? _activeHandshake;

  /// Begins listening to connection transitions and status notifications.
  ///
  /// If the repository is already connected on startup, schedules an initial
  /// handshake immediately.
  void start() {
    if (_started || _disposed) return;
    _started = true;

    _wasConnected = _repository.currentConnection.state.isConnected;
    _connectionSub = _repository.connectionStream.listen(_onConnectionChanged);
    _statusSub = _repository.statusStream.listen(_onStatusReceived);

    if (_wasConnected) {
      Future<void>.microtask(runHandshake);
    }
  }

  /// Executes Steps 3-5 of the v1.2 reconnection handshake:
  /// Step 3: `CMD_SYNC_TIME (10)`
  /// Step 4: `READ Status`, `CMD_CFG_GET (100)`, `CMD_TODO_GET_LEN (200)` + `201`
  /// Step 5: If `unsynced > 0`, loop `CMD_HIST_PEEK (300)` -> SQLite -> `CMD_HIST_ACK (301)`
  Future<void> runHandshake() {
    final existing = _activeHandshake;
    if (existing != null) return existing;

    final future = _performHandshake();
    _activeHandshake = future;
    future.whenComplete(() {
      if (identical(_activeHandshake, future)) {
        _activeHandshake = null;
      }
    });
    return future;
  }

  /// Manually or reactively pulls any pending `unsynced` logs via Step 5.
  ///
  /// Protected by [_isSyncingHistory] so 1Hz `EVT_STATUS` packets never start
  /// overlapping `CMD_HIST_PEEK` / `CMD_HIST_ACK` loops.
  Future<int> syncPendingHistory() async {
    if (_disposed || _isSyncingHistory) return 0;
    if (!_repository.currentConnection.state.isConnected) return 0;

    _isSyncingHistory = true;
    var syncedCount = 0;
    var shouldNotifyHistory = false;

    try {
      AppLogger.instance.sync('History sync started (CMD_HIST_PEEK -> ACK)');
      const maxIterations = 500;
      for (var i = 0; i < maxIterations; i++) {
        if (_disposed || !_repository.currentConnection.state.isConnected) {
          break;
        }
        final rawLog = await _repository.peekHistory();
        if (rawLog == null) {
          AppLogger.instance.sync('History queue empty (ERR_HIST_EMPTY)');
          break;
        }

        final nowEpoch = _nowEpochSeconds();
        final inserted = await _database.insertSessionLogIdempotent(
          rawLog,
          nowEpochSeconds: nowEpoch,
        );
        final remaining = await _repository.ackHistory(rawLog.logId);
        syncedCount++;
        shouldNotifyHistory = true;
        AppLogger.instance.sync(
          'Synced log #${rawLog.logId} (inserted=$inserted, estimated=${rawLog.startEpoch == 0}, remaining=$remaining)',
        );
        if (remaining <= 0) {
          break;
        }
      }
      return syncedCount;
    } on PomodoroProtocolException catch (e) {
      AppLogger.instance.sync('History sync paused: ${e.message}');
      return syncedCount;
    } finally {
      _isSyncingHistory = false;
      if (shouldNotifyHistory && !_disposed) {
        await onHistorySynced?.call();
      }
    }
  }

  Future<void> _performHandshake() async {
    if (_disposed || _isHandshaking) return;
    if (!_repository.currentConnection.state.isConnected) return;

    _isHandshaking = true;
    try {
      AppLogger.instance.sync('Handshake Step 1-2: MTU 512 & Notify active');
      final nowEpoch = _nowEpochSeconds();
      final tzOffset = _tzOffsetSeconds();

      AppLogger.instance.sync(
        'Handshake Step 3: CMD_SYNC_TIME (epoch=$nowEpoch, tz=$tzOffset)',
      );
      await _repository.syncTime(
        epochSeconds: nowEpoch,
        tzOffsetSeconds: tzOffset,
      );

      AppLogger.instance.sync(
        'Handshake Step 4: READ Status -> Config (100) -> Todos (200/201)',
      );
      final status = await _repository.readStatus();
      onStatusSynced?.call(status);

      await onLoadConfig?.call();
      final todos = await onLoadTodos?.call();
      if (todos != null && todos.isNotEmpty) {
        await _database.upsertKnownTodos(todos, nowEpochSeconds: nowEpoch);
      }
      _isHandshakeSynced = true;

      if (status.unsyncedCount > 0) {
        AppLogger.instance.sync(
          'Handshake Step 5: unsynced=${status.unsyncedCount}, draining queue',
        );
        await syncPendingHistory();
      } else {
        AppLogger.instance.sync('Handshake Step 5: unsynced=0, queue clean');
      }
    } on PomodoroProtocolException catch (e) {
      AppLogger.instance.sync('Handshake aborted: ${e.message}');
    } finally {
      _isHandshaking = false;
    }
  }

  void _onConnectionChanged(BleConnectionSnapshot snapshot) {
    if (_disposed) return;
    final isNowConnected = snapshot.state.isConnected;
    final transitionedToConnected = !_wasConnected && isNowConnected;
    _wasConnected = isNowConnected;

    if (!isNowConnected) {
      _isHandshakeSynced = false;
      return;
    }

    if (transitionedToConnected) {
      _isHandshakeSynced = false;
      unawaited(runHandshake());
    }
  }

  void _onStatusReceived(DeviceStatus status) {
    if (_disposed) return;
    if (!_repository.currentConnection.state.isConnected) return;
    if (!_isHandshakeSynced || _isHandshaking || _isSyncingHistory) return;
    if (status.unsyncedCount > 0) {
      unawaited(syncPendingHistory());
    }
  }

  void dispose() {
    _disposed = true;
    _connectionSub?.cancel();
    _statusSub?.cancel();
  }
}
