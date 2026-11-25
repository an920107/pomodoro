import '../../core/protocol/packet_envelope.dart';
import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';
import '../models/device_config.dart';
import '../models/device_status.dart';
import '../models/session_log.dart';
import '../models/todo_item.dart';

/// Connection lifecycle states exposed to the UI and handshake coordinator.
enum BleConnectionState {
  disconnected('未連線'),
  scanning('掃描中'),
  connecting('連線中'),
  connected('已連線'),
  reconnecting('重連中');

  const BleConnectionState(this.label);

  final String label;

  bool get isConnected => this == connected;
}

/// Discovered BLE peripheral entry shown during device scanning.
class BleDeviceItem {
  const BleDeviceItem({
    required this.id,
    required this.name,
    required this.rssi,
    this.isMock = false,
    this.matchesPomodoroService = false,
  });

  final String id;
  final String name;
  final int rssi;
  final bool isMock;
  final bool matchesPomodoroService;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BleDeviceItem &&
        other.id == id &&
        other.name == name &&
        other.rssi == rssi &&
        other.isMock == isMock &&
        other.matchesPomodoroService == matchesPomodoroService;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, rssi, isMock, matchesPomodoroService);
}

/// Immutable snapshot of the active BLE transport state.
class BleConnectionSnapshot {
  const BleConnectionSnapshot({
    required this.state,
    this.device,
    this.reconnectAttempt = 0,
    this.nextRetryDelay,
    this.isBluetoothAdapterOn = true,
    this.errorMessage,
  });

  const BleConnectionSnapshot.disconnected({
    bool isBluetoothAdapterOn = true,
    String? errorMessage,
  }) : this(
          state: BleConnectionState.disconnected,
          isBluetoothAdapterOn: isBluetoothAdapterOn,
          errorMessage: errorMessage,
        );

  final BleConnectionState state;
  final BleDeviceItem? device;
  final int reconnectAttempt;
  final Duration? nextRetryDelay;
  final bool isBluetoothAdapterOn;
  final String? errorMessage;

  BleConnectionSnapshot copyWith({
    BleConnectionState? state,
    BleDeviceItem? device,
    bool clearDevice = false,
    int? reconnectAttempt,
    Duration? nextRetryDelay,
    bool clearNextRetryDelay = false,
    bool? isBluetoothAdapterOn,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return BleConnectionSnapshot(
      state: state ?? this.state,
      device: clearDevice ? null : (device ?? this.device),
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      nextRetryDelay:
          clearNextRetryDelay ? null : (nextRetryDelay ?? this.nextRetryDelay),
      isBluetoothAdapterOn: isBluetoothAdapterOn ?? this.isBluetoothAdapterOn,
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Abstract BLE transport contract shared by [MockBleRepository] and the
/// future `RealBleRepository` (`docs/spec.md` §8.1).
abstract class BleRepository {
  bool get isMock;

  BleConnectionSnapshot get currentConnection;

  Stream<BleConnectionSnapshot> get connectionStream;

  DeviceStatus? get latestStatus;

  Stream<DeviceStatus> get statusStream;

  Stream<List<BleDeviceItem>> get scanResultsStream;

  Future<void> startScan({bool includeAllDevices = false});

  Future<void> stopScan();

  Future<void> connect(String deviceId);

  Future<void> disconnect();

  Future<DeviceStatus> readStatus();

  Future<RpcResponse> sendRpc(RpcRequest request);

  Future<void> syncTime({
    required int epochSeconds,
    required int tzOffsetSeconds,
  });

  Future<void> startFocus({int todoId = BleProtocolConstants.unboundTodoId});

  Future<void> startBreak();

  Future<void> pauseTimer();

  Future<void> resumeTimer();

  Future<void> stopTimer();

  Future<DeviceConfig> getConfig();

  Future<void> setConfig(DeviceConfig config);

  Future<TodoListMeta> getTodoLength();

  Future<TodoItem> getTodoItem(int index);

  Future<TodoAppendResult> appendTodo(String title);

  Future<void> updateTodo({
    required int index,
    String? title,
    bool? done,
  });

  Future<int> deleteTodo(int index);

  Future<void> swapTodos(int i, int j);

  Future<SessionLog?> peekHistory();

  Future<int> ackHistory(int logId);

  void dispose();
}

/// Shared typed RPC command wrappers implemented atop [sendRpc].
abstract class BaseBleRepository implements BleRepository {
  Future<RpcResponse> _sendOk(
    CmdId cmd, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) async {
    final response = await sendRpc(RpcRequest.command(cmd, data));
    return response.ensureOk();
  }

  @override
  Future<void> syncTime({
    required int epochSeconds,
    required int tzOffsetSeconds,
  }) async {
    await _sendOk(CmdId.syncTime, <String, dynamic>{
      'epoch': epochSeconds,
      'tz': tzOffsetSeconds,
    });
  }

  @override
  Future<void> startFocus({
    int todoId = BleProtocolConstants.unboundTodoId,
  }) async {
    await _sendOk(CmdId.startFocus, <String, dynamic>{'todo_id': todoId});
  }

  @override
  Future<void> startBreak() async {
    await _sendOk(CmdId.startBreak);
  }

  @override
  Future<void> pauseTimer() async {
    await _sendOk(CmdId.pause);
  }

  @override
  Future<void> resumeTimer() async {
    await _sendOk(CmdId.resume);
  }

  @override
  Future<void> stopTimer() async {
    await _sendOk(CmdId.stop);
  }

  @override
  Future<DeviceConfig> getConfig() async {
    final res = await _sendOk(CmdId.cfgGet);
    return DeviceConfig.fromData(res.data);
  }

  @override
  Future<void> setConfig(DeviceConfig config) async {
    config.validate();
    await _sendOk(CmdId.cfgSet, config.toData());
  }

  @override
  Future<TodoListMeta> getTodoLength() async {
    final res = await _sendOk(CmdId.todoGetLen);
    return TodoListMeta.fromData(res.data);
  }

  @override
  Future<TodoItem> getTodoItem(int index) async {
    final res = await _sendOk(CmdId.todoGet, <String, dynamic>{'i': index});
    return TodoItem.fromData(res.data);
  }

  @override
  Future<TodoAppendResult> appendTodo(String title) async {
    AsciiValidator.validateTodoTitle(title);
    final res = await _sendOk(
      CmdId.todoAppend,
      <String, dynamic>{'t': title},
    );
    return TodoAppendResult.fromData(res.data);
  }

  @override
  Future<void> updateTodo({
    required int index,
    String? title,
    bool? done,
  }) async {
    if (title == null && done == null) {
      throw const PacketValidationException(
        'CMD_TODO_UPDATE requires title or done',
      );
    }
    if (title != null) {
      AsciiValidator.validateTodoTitle(title);
    }
    await _sendOk(CmdId.todoUpdate, <String, dynamic>{
      'i': index,
      't': ?title,
      'd': ?done,
    });
  }

  @override
  Future<int> deleteTodo(int index) async {
    final res = await _sendOk(CmdId.todoDelete, <String, dynamic>{'i': index});
    final len = res.data['len'];
    if (len is! int) {
      throw const PacketValidationException(
        'Invalid CMD_TODO_DELETE payload: missing len',
      );
    }
    return len;
  }

  @override
  Future<void> swapTodos(int i, int j) async {
    await _sendOk(CmdId.todoSwap, <String, dynamic>{'i': i, 'j': j});
  }

  @override
  Future<SessionLog?> peekHistory() async {
    final res = await sendRpc(RpcRequest.command(CmdId.histPeek));
    if (res.code == ErrCode.histEmpty.code) {
      return null;
    }
    res.ensureOk();
    return SessionLog.fromPeekData(res.data);
  }

  @override
  Future<int> ackHistory(int logId) async {
    final res = await _sendOk(
      CmdId.histAck,
      <String, dynamic>{'log_id': logId},
    );
    final unsynced = res.data['unsynced'];
    if (unsynced is! int) {
      throw const PacketValidationException(
        'Invalid CMD_HIST_ACK payload: missing unsynced',
      );
    }
    return unsynced;
  }
}
