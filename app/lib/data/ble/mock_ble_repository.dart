import 'dart:async';
import 'dart:typed_data';

import '../../core/logging/app_logger.dart';
import '../../core/protocol/packet_envelope.dart';
import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';
import '../models/device_config.dart';
import '../models/device_status.dart';
import '../models/session_log.dart';
import '../models/todo_item.dart';
import 'ble_repository.dart';
import 'mock_nvs_store.dart';
import 'rpc_command_queue.dart';

/// Pure-Dart virtual ESP32 firmware implementing `docs/spec.md` v1.2.
///
/// Supports full state-machine transitions, 1Hz `EVT_STATUS` emission,
/// simulated NVS persistence, offline background countdown while disconnected,
/// simulated power-cycle restarts, and deterministic error codes.
class MockBleRepository extends BaseBleRepository {
  MockBleRepository({
    MockNvsStore? nvsStore,
    AppLogger? logger,
    this.tickInterval = const Duration(seconds: 1),
    this.maxHistoryQueue = 20,
    bool autoConnectOnInit = true,
  })  : _nvsStore = nvsStore ?? InMemoryMockNvsStore(),
        _logger = logger ?? AppLogger.instance {
    _rpcQueue = RpcCommandQueue(
      logger: _logger,
      writer: _handleIncomingRpcWrite,
    );
    _loadFromNvs();
    _connectionSnapshot = autoConnectOnInit
        ? const BleConnectionSnapshot(
            state: BleConnectionState.connected,
            device: mockDevice,
          )
        : const BleConnectionSnapshot.disconnected();
    _lastStatus = _buildStatus();
  }

  static const BleDeviceItem mockDevice = BleDeviceItem(
    id: 'mock-esp32-0001',
    name: 'SmartPomodoro (Mock)',
    rssi: -42,
    isMock: true,
    matchesPomodoroService: true,
  );

  final MockNvsStore _nvsStore;
  final AppLogger _logger;
  final Duration tickInterval;
  final int maxHistoryQueue;

  late final RpcCommandQueue _rpcQueue;

  final StreamController<BleConnectionSnapshot> _connectionController =
      StreamController<BleConnectionSnapshot>.broadcast();
  final StreamController<DeviceStatus> _statusController =
      StreamController<DeviceStatus>.broadcast();
  final StreamController<List<BleDeviceItem>> _scanController =
      StreamController<List<BleDeviceItem>>.broadcast();

  late BleConnectionSnapshot _connectionSnapshot;
  late DeviceConfig _config;
  late List<TodoItem> _todos;
  late List<SessionLog> _historyQueue;
  late int _nextTodoId;
  late int _nextLogId;

  DeviceStatus? _lastStatus;
  PomodoroState _state = PomodoroState.idle;
  int _remainingSeconds = 0;
  int _totalSeconds = 0;
  bool _isAway = false;
  int _activeTodoId = BleProtocolConstants.unboundTodoId;
  int _activeSessionStartEpoch = 0;

  bool _isClockSynced = false;
  int _syncedBaseEpoch = 0;
  int _ticksSinceSync = 0;

  Timer? _tickTimer;
  Timer? _reconnectTimer;
  Timer? _clockTimer;
  int _pendingSimulatedFailCount = 0;
  bool _isDisposed = false;

  @override
  bool get isMock => true;

  @override
  BleConnectionSnapshot get currentConnection => _connectionSnapshot;

  @override
  Stream<BleConnectionSnapshot> get connectionStream =>
      _connectionController.stream;

  @override
  DeviceStatus? get latestStatus => _lastStatus;

  @override
  Stream<DeviceStatus> get statusStream => _statusController.stream;

  @override
  Stream<List<BleDeviceItem>> get scanResultsStream => _scanController.stream;

  bool get isClockSynced => _isClockSynced;

  List<TodoItem> get debugTodosSnapshot => List<TodoItem>.unmodifiable(_todos);

  int get debugUnsyncedCount => _historyQueue.length;

  @override
  Future<void> startScan({bool includeAllDevices = false}) async {
    _ensureNotDisposed();
    _emitConnection(
      _connectionSnapshot.copyWith(state: BleConnectionState.scanning),
    );
    if (!_scanController.isClosed) {
      _scanController.add(const <BleDeviceItem>[mockDevice]);
    }
  }

  @override
  Future<void> stopScan() async {
    if (_isDisposed) return;
    if (_connectionSnapshot.state == BleConnectionState.scanning) {
      _emitConnection(
        _connectionSnapshot.copyWith(
          state: _connectionSnapshot.device != null
              ? BleConnectionState.connected
              : BleConnectionState.disconnected,
        ),
      );
    }
  }

  @override
  Future<void> connect(String deviceId) async {
    _ensureNotDisposed();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _emitConnection(
      const BleConnectionSnapshot(
        state: BleConnectionState.connecting,
        device: mockDevice,
      ),
    );
    _emitConnection(
      const BleConnectionSnapshot(
        state: BleConnectionState.connected,
        device: mockDevice,
      ),
    );
    _emitStatusIfConnected();
  }

  @override
  Future<void> disconnect() async {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pendingSimulatedFailCount = 0;
    _rpcQueue.failAllPending();
    _emitConnection(
      const BleConnectionSnapshot.disconnected(),
    );
  }

  @override
  Future<DeviceStatus> readStatus() async {
    _ensureConnected();
    final status = _buildStatus();
    _lastStatus = status;
    return status;
  }

  @override
  Future<RpcResponse> sendRpc(RpcRequest request) {
    _ensureNotDisposed();
    if (!_connectionSnapshot.state.isConnected) {
      return Future<RpcResponse>.error(const BleDisconnectedException());
    }
    return _rpcQueue.enqueue(request);
  }

  /// Simulates proximity sensor away / back-in-seat detection (`spec.md` §2).
  void simulateAway(bool away) {
    _ensureNotDisposed();
    _isAway = away;
    if (away && _state == PomodoroState.focusRunning) {
      _state = PomodoroState.focusPausedAway;
      _stopTicking();
      _emitStatusIfConnected();
    } else if (!away && _state == PomodoroState.focusPausedAway) {
      _state = PomodoroState.focusRunning;
      _startTicking();
      _emitStatusIfConnected();
    } else {
      _emitStatusIfConnected();
    }
  }

  /// Fast-forwards the active countdown to [seconds] remaining.
  /// If [seconds] <= 0 while running, completes the session immediately.
  void fastForwardRemaining(int seconds) {
    _ensureNotDisposed();
    if (!_state.isFocus && !_state.isBreak) return;
    final clamped = seconds.clamp(0, _totalSeconds);
    _remainingSeconds = clamped;
    if (clamped == 0 && _state.isRunning) {
      _completeRunningSession();
      return;
    }
    _emitStatusIfConnected();
  }

  /// Fast-forwards the active countdown so [elapsedSeconds] have elapsed
  /// while keeping at least 1 second remaining so the session stays active.
  void fastForwardElapsed(int elapsedSeconds) {
    _ensureNotDisposed();
    if (!_state.isFocus && !_state.isBreak) return;
    if (_totalSeconds <= 0) return;
    final clampedElapsed = elapsedSeconds.clamp(0, _totalSeconds - 1);
    _remainingSeconds = _totalSeconds - clampedElapsed;
    _emitStatusIfConnected();
  }

  /// Drops the BLE link while keeping the virtual ESP32 countdown running
  /// offline in the background (`spec.md` §4.1.1).
  void simulateDisconnect({
    bool autoReconnect = false,
    int failCount = 0,
  }) {
    _ensureNotDisposed();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pendingSimulatedFailCount = failCount < 0 ? 0 : failCount;
    _rpcQueue.failAllPending();

    if (!autoReconnect) {
      _emitConnection(
        const BleConnectionSnapshot(
          state: BleConnectionState.disconnected,
          device: mockDevice,
        ),
      );
      return;
    }

    _scheduleReconnectAttempt(1);
  }

  /// Restores BLE connection to the virtual ESP32 immediately.
  Future<void> simulateReconnect() async {
    await connect(mockDevice.id);
  }

  /// Simulates an ESP32 power cycle: volatile timer/clock resets to `IDLE`
  /// and `isClockSynced = false`, while NVS config/todos/history reload.
  Future<void> simulatePowerCycle() async {
    _ensureNotDisposed();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopTicking();
    _clockTimer?.cancel();
    _clockTimer = null;

    _rpcQueue.failAllPending();
    _state = PomodoroState.idle;
    _remainingSeconds = 0;
    _totalSeconds = 0;
    _isAway = false;
    _activeTodoId = BleProtocolConstants.unboundTodoId;
    _activeSessionStartEpoch = 0;
    _isClockSynced = false;
    _syncedBaseEpoch = 0;
    _ticksSinceSync = 0;

    _loadFromNvs();
    _emitConnection(
      const BleConnectionSnapshot(
        state: BleConnectionState.reconnecting,
        device: mockDevice,
        reconnectAttempt: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    if (_isDisposed) return;
    _emitConnection(
      const BleConnectionSnapshot(
        state: BleConnectionState.connected,
        device: mockDevice,
      ),
    );
    _emitStatusIfConnected();
  }

  /// Injects an unsynced session log directly into the virtual ESP32 NVS queue.
  void injectOfflineSessionLog({
    int startEpoch = 0,
    int durationSeconds = 1500,
    SessionType type = SessionType.focus,
    SessionResult result = SessionResult.completed,
    int todoId = BleProtocolConstants.unboundTodoId,
  }) {
    _ensureNotDisposed();
    _appendHistoryToNvs(
      SessionLog(
        logId: _nextLogId++,
        startEpoch: startEpoch,
        durationSeconds: durationSeconds,
        type: type,
        result: result,
        todoId: todoId,
      ),
    );
    _emitStatusIfConnected();
  }

  Future<void> resetMockNvs() async {
    _ensureNotDisposed();
    _stopTicking();
    _state = PomodoroState.idle;
    _remainingSeconds = 0;
    _totalSeconds = 0;
    _isAway = false;
    _activeTodoId = BleProtocolConstants.unboundTodoId;
    await _nvsStore.clear();
    _loadFromNvs();
    _emitStatusIfConnected();
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _tickTimer?.cancel();
    _tickTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _clockTimer?.cancel();
    _clockTimer = null;
    _rpcQueue.dispose();
    _connectionController.close();
    _statusController.close();
    _scanController.close();
  }

  void _loadFromNvs() {
    final snapshot = _nvsStore.load();
    _config = snapshot.config;
    _todos = List<TodoItem>.from(snapshot.todos);
    _historyQueue = List<SessionLog>.from(snapshot.historyQueue);
    _nextTodoId = snapshot.nextTodoId;
    _nextLogId = snapshot.nextLogId;
  }

  void _persistNvs() {
    final snapshot = MockNvsSnapshot(
      config: _config,
      todos: _todos,
      historyQueue: _historyQueue,
      nextTodoId: _nextTodoId,
      nextLogId: _nextLogId,
    );
    unawaited(_nvsStore.save(snapshot));
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('MockBleRepository has already been disposed');
    }
  }

  void _ensureConnected() {
    _ensureNotDisposed();
    if (!_connectionSnapshot.state.isConnected) {
      throw const BleDisconnectedException();
    }
  }

  int _currentDeviceEpoch() {
    if (!_isClockSynced) return 0;
    return _syncedBaseEpoch + _ticksSinceSync;
  }

  DeviceStatus _buildStatus() {
    return DeviceStatus(
      state: _state,
      remainingSeconds: _remainingSeconds,
      totalSeconds: _totalSeconds,
      isAway: _isAway,
      todoId: _activeTodoId,
      unsyncedCount: _historyQueue.length,
    );
  }

  void _emitConnection(BleConnectionSnapshot snapshot) {
    _connectionSnapshot = snapshot;
    if (!_connectionController.isClosed) {
      _connectionController.add(snapshot);
    }
  }

  void _emitStatusIfConnected() {
    final status = _buildStatus();
    _lastStatus = status;
    if (_connectionSnapshot.state.isConnected && !_statusController.isClosed) {
      _logger.bleRx(
        RpcResponse(
          cmd: CmdId.evtStatus.code,
          code: ErrCode.ok.code,
          data: status.toData(),
        ).toJsonString(),
      );
      _statusController.add(status);
    }
  }

  void _startTicking() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(tickInterval, (_) => _onTimerTick());
  }

  void _stopTicking() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  void _ensureClockTicking() {
    _clockTimer ??= Timer.periodic(tickInterval, (_) {
      if (_isClockSynced) {
        _ticksSinceSync++;
      }
    });
  }

  void _onTimerTick() {
    if (_isDisposed || !_state.isRunning) {
      _stopTicking();
      return;
    }
    if (_remainingSeconds > 1) {
      _remainingSeconds--;
      _emitStatusIfConnected();
      return;
    }
    _remainingSeconds = 0;
    _completeRunningSession();
  }

  void _completeRunningSession() {
    final wasFocus = _state == PomodoroState.focusRunning;
    final completedType =
        wasFocus ? SessionType.focus : SessionType.breakSession;
    final completedDur = _totalSeconds;
    final completedTodoId = wasFocus
        ? _activeTodoId
        : BleProtocolConstants.unboundTodoId;
    final startEpoch = _activeSessionStartEpoch;

    _stopTicking();
    _state = PomodoroState.idle;
    _remainingSeconds = 0;
    _totalSeconds = 0;
    _activeTodoId = BleProtocolConstants.unboundTodoId;
    _activeSessionStartEpoch = 0;

    _appendHistoryToNvs(
      SessionLog(
        logId: _nextLogId++,
        startEpoch: startEpoch,
        durationSeconds: completedDur,
        type: completedType,
        result: SessionResult.completed,
        todoId: completedTodoId,
      ),
    );
    _emitStatusIfConnected();
  }

  void _appendHistoryToNvs(SessionLog log) {
    if (_historyQueue.length >= maxHistoryQueue) {
      _historyQueue.removeAt(0);
    }
    _historyQueue.add(log);
    _persistNvs();
  }

  void _scheduleReconnectAttempt(int attempt) {
    final delay = attempt <= 5
        ? const Duration(seconds: 3)
        : const Duration(seconds: 10);
    _emitConnection(
      BleConnectionSnapshot(
        state: BleConnectionState.reconnecting,
        device: mockDevice,
        reconnectAttempt: attempt,
        nextRetryDelay: delay,
      ),
    );
    _reconnectTimer = Timer(delay, () {
      if (_isDisposed) return;
      if (_pendingSimulatedFailCount > 0) {
        _pendingSimulatedFailCount--;
        _scheduleReconnectAttempt(attempt + 1);
        return;
      }
      _emitConnection(
        const BleConnectionSnapshot(
          state: BleConnectionState.connected,
          device: mockDevice,
        ),
      );
      _emitStatusIfConnected();
    });
  }

  Future<void> _handleIncomingRpcWrite(Uint8List bytes) async {
    if (!_connectionSnapshot.state.isConnected) {
      throw const BleDisconnectedException();
    }

    final RpcRequest req;
    try {
      req = RpcRequest.fromBytes(bytes);
    } on PacketValidationException {
      _respond(
        RpcResponse(cmd: 0, code: ErrCode.invalidJson.code),
      );
      return;
    }

    final response = _dispatchCommand(req);
    _respond(response);
  }

  void _respond(RpcResponse response) {
    final wireBytes = response.toBytes();
    scheduleMicrotask(() {
      if (_isDisposed) return;
      _rpcQueue.handleNotificationBytes(wireBytes);
    });
  }

  RpcResponse _dispatchCommand(RpcRequest req) {
    final cmd = CmdId.tryFromCode(req.cmd);
    if (cmd == null) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.unknownCmd.code);
    }

    return switch (cmd) {
      CmdId.syncTime => _handleSyncTime(req),
      CmdId.startFocus => _handleStartFocus(req),
      CmdId.startBreak => _handleStartBreak(req),
      CmdId.pause => _handlePause(req),
      CmdId.resume => _handleResume(req),
      CmdId.stop => _handleStop(req),
      CmdId.cfgGet => RpcResponse(
          cmd: req.cmd,
          code: ErrCode.ok.code,
          data: _config.toData(),
        ),
      CmdId.cfgSet => _handleCfgSet(req),
      CmdId.todoGetLen => RpcResponse(
          cmd: req.cmd,
          code: ErrCode.ok.code,
          data: <String, dynamic>{
            'len': _todos.length,
            'max': BleProtocolConstants.maxTodos,
          },
        ),
      CmdId.todoGet => _handleTodoGet(req),
      CmdId.todoAppend => _handleTodoAppend(req),
      CmdId.todoUpdate => _handleTodoUpdate(req),
      CmdId.todoDelete => _handleTodoDelete(req),
      CmdId.todoSwap => _handleTodoSwap(req),
      CmdId.histPeek => _handleHistPeek(req),
      CmdId.histAck => _handleHistAck(req),
      CmdId.evtStatus => RpcResponse(
          cmd: req.cmd,
          code: ErrCode.unknownCmd.code,
        ),
    };
  }

  RpcResponse _handleSyncTime(RpcRequest req) {
    final epoch = req.data['epoch'];
    final tz = req.data['tz'];
    if (epoch is! int || tz is! int || epoch < 0) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    _syncedBaseEpoch = epoch;
    _ticksSinceSync = 0;
    _isClockSynced = true;
    _ensureClockTicking();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handleStartFocus(RpcRequest req) {
    if (_state != PomodoroState.idle) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidState.code);
    }
    final todoId = req.data['todo_id'];
    if (todoId is! int || todoId < BleProtocolConstants.unboundTodoId) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }

    _state = PomodoroState.focusRunning;
    _totalSeconds = _config.focusMinutes * 60;
    _remainingSeconds = _totalSeconds;
    _activeTodoId = todoId;
    _activeSessionStartEpoch = _currentDeviceEpoch();
    _startTicking();
    _emitStatusIfConnected();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handleStartBreak(RpcRequest req) {
    if (_state != PomodoroState.idle) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidState.code);
    }

    _state = PomodoroState.breakRunning;
    _totalSeconds = _config.breakMinutes * 60;
    _remainingSeconds = _totalSeconds;
    _activeTodoId = BleProtocolConstants.unboundTodoId;
    _activeSessionStartEpoch = _currentDeviceEpoch();
    _startTicking();
    _emitStatusIfConnected();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handlePause(RpcRequest req) {
    if (_state == PomodoroState.focusRunning) {
      _state = PomodoroState.focusPausedUser;
    } else if (_state == PomodoroState.breakRunning) {
      _state = PomodoroState.breakPausedUser;
    } else {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidState.code);
    }
    _stopTicking();
    _emitStatusIfConnected();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handleResume(RpcRequest req) {
    if (_state == PomodoroState.focusPausedUser) {
      _state = PomodoroState.focusRunning;
    } else if (_state == PomodoroState.breakPausedUser) {
      _state = PomodoroState.breakRunning;
    } else {
      // FOCUS_PAUSED_AWAY and IDLE cannot be resumed via user command.
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidState.code);
    }
    _startTicking();
    _emitStatusIfConnected();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handleStop(RpcRequest req) {
    final wasFocus = _state.isFocus;
    final elapsed = _totalSeconds - _remainingSeconds;
    final abortedTodoId = _activeTodoId;
    final startEpoch = _activeSessionStartEpoch;

    _stopTicking();
    _state = PomodoroState.idle;
    _remainingSeconds = 0;
    _totalSeconds = 0;
    _activeTodoId = BleProtocolConstants.unboundTodoId;
    _activeSessionStartEpoch = 0;

    if (wasFocus && elapsed >= BleProtocolConstants.minAbortLogSeconds) {
      _appendHistoryToNvs(
        SessionLog(
          logId: _nextLogId++,
          startEpoch: startEpoch,
          durationSeconds: elapsed,
          type: SessionType.focus,
          result: SessionResult.aborted,
          todoId: abortedTodoId,
        ),
      );
    }

    _emitStatusIfConnected();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handleCfgSet(RpcRequest req) {
    final DeviceConfig nextCfg;
    try {
      nextCfg = DeviceConfig.fromData(req.data);
      nextCfg.validate();
    } on PacketValidationException {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    _config = nextCfg;
    _persistNvs();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handleTodoGet(RpcRequest req) {
    final index = req.data['i'];
    if (index is! int) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (index < 0 || index >= _todos.length) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.todoOutOfRange.code);
    }
    return RpcResponse(
      cmd: req.cmd,
      code: ErrCode.ok.code,
      data: _todos[index].toData(),
    );
  }

  RpcResponse _handleTodoAppend(RpcRequest req) {
    final title = req.data['t'];
    if (title is! String) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (!AsciiValidator.isValidTodoTitle(title)) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.todoInvalidTitle.code);
    }
    if (_todos.length >= BleProtocolConstants.maxTodos) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.todoFull.code);
    }

    final index = _todos.length;
    final id = _nextTodoId++;
    _todos.add(TodoItem(index: index, id: id, title: title, done: false));
    _persistNvs();

    return RpcResponse(
      cmd: req.cmd,
      code: ErrCode.ok.code,
      data: <String, dynamic>{
        'i': index,
        'id': id,
        'len': _todos.length,
      },
    );
  }

  RpcResponse _handleTodoUpdate(RpcRequest req) {
    final index = req.data['i'];
    final title = req.data['t'];
    final done = req.data['d'];

    if (index is! int) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (index < 0 || index >= _todos.length) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.todoOutOfRange.code);
    }
    if (title != null && title is! String) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (done != null && done is! bool) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (title == null && done == null) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (title is String && !AsciiValidator.isValidTodoTitle(title)) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.todoInvalidTitle.code);
    }

    final existing = _todos[index];
    _todos[index] = existing.copyWith(
      title: title as String?,
      done: done as bool?,
    );
    _persistNvs();
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  RpcResponse _handleTodoDelete(RpcRequest req) {
    final index = req.data['i'];
    if (index is! int) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (index < 0 || index >= _todos.length) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.todoOutOfRange.code);
    }
    _todos.removeAt(index);
    _reindexTodos();
    _persistNvs();
    return RpcResponse(
      cmd: req.cmd,
      code: ErrCode.ok.code,
      data: <String, dynamic>{'len': _todos.length},
    );
  }

  RpcResponse _handleTodoSwap(RpcRequest req) {
    final i = req.data['i'];
    final j = req.data['j'];
    if (i is! int || j is! int) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (i < 0 || i >= _todos.length || j < 0 || j >= _todos.length) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.todoOutOfRange.code);
    }
    if (i != j) {
      final temp = _todos[i];
      _todos[i] = _todos[j];
      _todos[j] = temp;
      _reindexTodos();
      _persistNvs();
    }
    return RpcResponse(cmd: req.cmd, code: ErrCode.ok.code);
  }

  void _reindexTodos() {
    for (var i = 0; i < _todos.length; i++) {
      if (_todos[i].index != i) {
        _todos[i] = _todos[i].copyWith(index: i);
      }
    }
  }

  RpcResponse _handleHistPeek(RpcRequest req) {
    if (_historyQueue.isEmpty) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.histEmpty.code);
    }
    return RpcResponse(
      cmd: req.cmd,
      code: ErrCode.ok.code,
      data: _historyQueue.first.toPeekData(),
    );
  }

  RpcResponse _handleHistAck(RpcRequest req) {
    final logId = req.data['log_id'];
    if (logId is! int) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.invalidParam.code);
    }
    if (_historyQueue.isEmpty) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.histEmpty.code);
    }
    if (_historyQueue.first.logId != logId) {
      return RpcResponse(cmd: req.cmd, code: ErrCode.histIdMismatch.code);
    }
    _historyQueue.removeAt(0);
    _persistNvs();
    _emitStatusIfConnected();
    return RpcResponse(
      cmd: req.cmd,
      code: ErrCode.ok.code,
      data: <String, dynamic>{'unsynced': _historyQueue.length},
    );
  }
}
