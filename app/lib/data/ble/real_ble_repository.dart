import 'dart:async';

import '../../core/logging/app_logger.dart';
import '../../core/protocol/packet_envelope.dart';
import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';
import '../local/preferences_store.dart';
import '../models/device_status.dart';
import 'ble_client_adapter.dart';
import 'ble_repository.dart';
import 'reconnect_backoff.dart';
import 'rpc_command_queue.dart';

/// Production [BleRepository] driving real BLE hardware via [BleClientAdapter]
/// (`flutter_blue_plus`), serial [RpcCommandQueue], and stepped reconnect
/// backoff (`3s` x 5 -> `10s`).
class RealBleRepository extends BaseBleRepository {
  RealBleRepository({
    required this._adapter,
    required this._preferences,
    this._backoffPolicy = const ReconnectBackoffPolicy(),
    this.scanTimeout = const Duration(seconds: 10),
    this.connectTimeout = const Duration(seconds: 12),
    this.rpcTimeout = BleProtocolConstants.rpcTimeout,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.instance {
    final savedId = _preferences.lastDeviceId;
    final savedName = _preferences.lastDeviceName;
    if (savedId != null && savedId.isNotEmpty) {
      _targetDevice = BleDeviceItem(
        id: savedId,
        name: (savedName != null && savedName.isNotEmpty) ? savedName : savedId,
        rssi: 0,
        isMock: false,
        matchesPomodoroService: true,
      );
    }

    _connectionSnapshot = BleConnectionSnapshot(
      state: BleConnectionState.disconnected,
      device: _targetDevice,
      isBluetoothAdapterOn: _adapter.isAdapterOnNow,
      errorMessage: _adapter.isAdapterOnNow
          ? null
          : '手機藍牙未開啟，請開啟藍牙以連線',
    );

    _adapterSub = _adapter.adapterOnStream.listen(_onAdapterStateChanged);
    _scanningSub = _adapter.isScanningStream.listen(_onScanningChanged);
    _scanEntriesSub = _adapter.scanEntriesStream.listen(_onScanEntries);
  }

  final BleClientAdapter _adapter;
  final PreferencesStore _preferences;
  final ReconnectBackoffPolicy _backoffPolicy;
  final Duration scanTimeout;
  final Duration connectTimeout;
  final Duration rpcTimeout;
  final AppLogger _logger;

  final StreamController<BleConnectionSnapshot> _connectionController =
      StreamController<BleConnectionSnapshot>.broadcast();
  final StreamController<DeviceStatus> _statusController =
      StreamController<DeviceStatus>.broadcast();
  final StreamController<List<BleDeviceItem>> _scanController =
      StreamController<List<BleDeviceItem>>.broadcast();

  StreamSubscription<bool>? _adapterSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<List<BleRawScanEntry>>? _scanEntriesSub;

  BleConnectedGattSession? _activeSession;
  StreamSubscription<List<int>>? _rpcNotifySub;
  StreamSubscription<List<int>>? _statusNotifySub;
  StreamSubscription<void>? _sessionDisconnectSub;
  RpcCommandQueue? _rpcQueue;
  Timer? _reconnectTimer;

  late BleConnectionSnapshot _connectionSnapshot;
  DeviceStatus? _latestStatus;
  BleDeviceItem? _targetDevice;
  List<BleRawScanEntry> _latestRawScanEntries = const <BleRawScanEntry>[];
  bool _includeAllDevices = false;
  bool _manualDisconnect = false;
  bool _isDisposed = false;

  @override
  bool get isMock => false;

  bool get includeAllDevices => _includeAllDevices;

  List<BleDeviceItem> get latestFilteredScanResults =>
      _filterEntries(_latestRawScanEntries);

  @override
  BleConnectionSnapshot get currentConnection => _connectionSnapshot;

  @override
  Stream<BleConnectionSnapshot> get connectionStream =>
      _connectionController.stream;

  @override
  DeviceStatus? get latestStatus => _latestStatus;

  @override
  Stream<DeviceStatus> get statusStream => _statusController.stream;

  @override
  Stream<List<BleDeviceItem>> get scanResultsStream => _scanController.stream;

  /// Updates scan result filtering without restarting an active BLE scan.
  void setIncludeAllDevices(bool includeAll) {
    if (_includeAllDevices == includeAll) return;
    _includeAllDevices = includeAll;
    _emitFilteredScanResults();
  }

  Future<bool> openPermissionSettings() => _adapter.openSystemAppSettings();

  @override
  Future<void> startScan({bool includeAllDevices = false}) async {
    _ensureNotDisposed();
    _includeAllDevices = includeAllDevices;

    final adapterOn = await _adapter.refreshAdapterOn();
    if (!adapterOn) {
      const msg = '手機藍牙未開啟，請開啟藍牙後再掃描';
      _emitConnection(
        _connectionSnapshot.copyWith(
          state: _activeSession != null
              ? BleConnectionState.connected
              : BleConnectionState.disconnected,
          isBluetoothAdapterOn: false,
          errorMessage: msg,
        ),
      );
      throw const BleConnectionException(msg);
    }

    final permission = await _adapter.ensurePermissions();
    if (permission != BlePermissionResult.granted) {
      final msg = _permissionMessage(permission);
      _emitConnection(
        _connectionSnapshot.copyWith(
          isBluetoothAdapterOn: _adapter.isAdapterOnNow,
          errorMessage: msg,
        ),
      );
      throw BleConnectionException(msg);
    }

    _latestRawScanEntries = const <BleRawScanEntry>[];
    _emitFilteredScanResults();

    if (!_connectionSnapshot.state.isConnected) {
      _emitConnection(
        _connectionSnapshot.copyWith(
          state: BleConnectionState.scanning,
          isBluetoothAdapterOn: true,
          clearErrorMessage: true,
        ),
      );
    }

    try {
      await _adapter.startScan(timeout: scanTimeout);
    } on PomodoroProtocolException catch (e) {
      if (!_connectionSnapshot.state.isConnected) {
        _emitConnection(
          _connectionSnapshot.copyWith(
            state: BleConnectionState.disconnected,
            errorMessage: e.message,
          ),
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> stopScan() async {
    if (_isDisposed) return;
    await _adapter.stopScan();
    if (_connectionSnapshot.state == BleConnectionState.scanning) {
      _emitConnection(
        _connectionSnapshot.copyWith(
          state: _activeSession != null
              ? BleConnectionState.connected
              : BleConnectionState.disconnected,
          isBluetoothAdapterOn: _adapter.isAdapterOnNow,
        ),
      );
    }
  }

  @override
  Future<void> connect(String deviceId) async {
    _ensureNotDisposed();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _manualDisconnect = false;

    final deviceItem = _resolveDeviceItem(deviceId);
    _targetDevice = deviceItem;

    final adapterOn = await _adapter.refreshAdapterOn();
    if (!adapterOn) {
      const msg = '手機藍牙未開啟，請開啟藍牙以連線';
      _emitConnection(
        BleConnectionSnapshot(
          state: BleConnectionState.disconnected,
          device: deviceItem,
          isBluetoothAdapterOn: false,
          errorMessage: msg,
        ),
      );
      throw const BleConnectionException(msg);
    }

    final permission = await _adapter.ensurePermissions();
    if (permission != BlePermissionResult.granted) {
      final msg = _permissionMessage(permission);
      _emitConnection(
        BleConnectionSnapshot(
          state: BleConnectionState.disconnected,
          device: deviceItem,
          isBluetoothAdapterOn: true,
          errorMessage: msg,
        ),
      );
      throw BleConnectionException(msg);
    }

    await _adapter.stopScan();
    _emitConnection(
      BleConnectionSnapshot(
        state: BleConnectionState.connecting,
        device: deviceItem,
        isBluetoothAdapterOn: true,
      ),
    );

    try {
      await _establishSession(deviceId, fallbackDevice: deviceItem);
    } on PomodoroProtocolException catch (e) {
      _emitConnection(
        BleConnectionSnapshot(
          state: BleConnectionState.disconnected,
          device: deviceItem,
          isBluetoothAdapterOn: _adapter.isAdapterOnNow,
          errorMessage: e.message,
        ),
      );
      rethrow;
    } catch (e) {
      final msg = '連線失敗：$e';
      _emitConnection(
        BleConnectionSnapshot(
          state: BleConnectionState.disconnected,
          device: deviceItem,
          isBluetoothAdapterOn: _adapter.isAdapterOnNow,
          errorMessage: msg,
        ),
      );
      throw BleConnectionException(msg);
    }
  }

  @override
  Future<void> disconnect() async {
    if (_isDisposed) return;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final deviceToDisconnect = _activeSession?.deviceId ?? _targetDevice?.id;
    await _teardownActiveSession();
    if (deviceToDisconnect != null && deviceToDisconnect.isNotEmpty) {
      await _adapter.disconnectDevice(deviceToDisconnect);
    }

    _emitConnection(
      BleConnectionSnapshot(
        state: BleConnectionState.disconnected,
        device: _targetDevice,
        reconnectAttempt: 0,
        isBluetoothAdapterOn: _adapter.isAdapterOnNow,
      ),
    );
  }

  @override
  Future<DeviceStatus> readStatus() async {
    _ensureNotDisposed();
    final session = _activeSession;
    if (session == null || !_connectionSnapshot.state.isConnected) {
      throw const BleDisconnectedException();
    }

    final rawBytes = await session.readStatus();
    final response = RpcResponse.fromBytes(rawBytes);
    _logger.bleRx(response.toJsonString());
    response.ensureOk();
    final status = DeviceStatus.fromData(response.data);
    _latestStatus = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
    return status;
  }

  @override
  Future<RpcResponse> sendRpc(RpcRequest request) {
    _ensureNotDisposed();
    final queue = _rpcQueue;
    if (queue == null || !_connectionSnapshot.state.isConnected) {
      return Future<RpcResponse>.error(const BleDisconnectedException());
    }
    return queue.enqueue(request);
  }

  Future<void> _establishSession(
    String deviceId, {
    BleDeviceItem? fallbackDevice,
  }) async {
    await _teardownActiveSession();
    final session = await _adapter.connectAndSetupGatt(
      deviceId,
      timeout: connectTimeout,
    );
    if (_isDisposed || _manualDisconnect) {
      await session.close();
      await _adapter.disconnectDevice(deviceId);
      return;
    }

    final queue = RpcCommandQueue(
      writer: session.writeRpc,
      timeout: rpcTimeout,
      logger: _logger,
    );

    _activeSession = session;
    _rpcQueue = queue;
    _rpcNotifySub = session.rpcNotifications.listen(
      queue.handleNotificationBytes,
      onError: (_) {},
    );
    _statusNotifySub = session.statusNotifications.listen(
      _onStatusNotifyBytes,
      onError: (_) {},
    );
    _sessionDisconnectSub = session.onDisconnected.listen((_) {
      _handleUnexpectedDisconnect(deviceId);
    });

    final resolvedName = session.deviceName.trim().isNotEmpty
        ? session.deviceName.trim()
        : (fallbackDevice?.name ?? _targetDevice?.name ?? deviceId);
    final resolvedDevice = BleDeviceItem(
      id: deviceId,
      name: resolvedName,
      rssi: fallbackDevice?.rssi ?? _targetDevice?.rssi ?? 0,
      isMock: false,
      matchesPomodoroService: true,
    );
    _targetDevice = resolvedDevice;

    await _preferences.setLastDeviceId(deviceId);
    await _preferences.setLastDeviceName(resolvedName);

    _emitConnection(
      BleConnectionSnapshot(
        state: BleConnectionState.connected,
        device: resolvedDevice,
        reconnectAttempt: 0,
        isBluetoothAdapterOn: true,
      ),
    );
  }

  void _onStatusNotifyBytes(List<int> bytes) {
    if (_isDisposed) return;
    try {
      final response = RpcResponse.fromBytes(bytes);
      _logger.bleRx(response.toJsonString());
      if (response.cmd != CmdId.evtStatus.code) return;
      final status = DeviceStatus.fromData(response.data);
      _latestStatus = status;
      if (!_statusController.isClosed) {
        _statusController.add(status);
      }
    } on PomodoroProtocolException catch (e) {
      _logger.bleRx('Ignored invalid Status notify: ${e.message}');
    }
  }

  void _handleUnexpectedDisconnect(String deviceId) {
    if (_isDisposed) return;
    unawaited(_teardownActiveSession());

    if (_manualDisconnect || !_adapter.isAdapterOnNow) {
      _emitConnection(
        BleConnectionSnapshot(
          state: BleConnectionState.disconnected,
          device: _targetDevice,
          reconnectAttempt: 0,
          isBluetoothAdapterOn: _adapter.isAdapterOnNow,
          errorMessage: _adapter.isAdapterOnNow
              ? null
              : '手機藍牙未開啟，請開啟藍牙以連線',
        ),
      );
      return;
    }

    _scheduleReconnect(deviceId, attempt: 1);
  }

  void _scheduleReconnect(
    String deviceId, {
    required int attempt,
    String? errorMessage,
  }) {
    if (_isDisposed || _manualDisconnect || !_adapter.isAdapterOnNow) {
      return;
    }
    _reconnectTimer?.cancel();
    final delay = _backoffPolicy.delayForAttempt(attempt);
    _logger.sync(
      'BLE disconnected unexpectedly; scheduling reconnect #$attempt in ${delay.inSeconds}s',
    );
    _emitConnection(
      BleConnectionSnapshot(
        state: BleConnectionState.reconnecting,
        device: _targetDevice,
        reconnectAttempt: attempt,
        nextRetryDelay: delay,
        isBluetoothAdapterOn: _adapter.isAdapterOnNow,
        errorMessage: errorMessage,
      ),
    );

    _reconnectTimer = Timer(delay, () {
      unawaited(_attemptReconnect(deviceId, attempt));
    });
  }

  Future<void> _attemptReconnect(String deviceId, int attempt) async {
    if (_isDisposed ||
        _manualDisconnect ||
        !_adapter.isAdapterOnNow ||
        _activeSession != null) {
      return;
    }

    try {
      await _establishSession(deviceId, fallbackDevice: _targetDevice);
    } on PomodoroProtocolException catch (e) {
      if (_isDisposed || _manualDisconnect || !_adapter.isAdapterOnNow) {
        return;
      }
      _scheduleReconnect(
        deviceId,
        attempt: attempt + 1,
        errorMessage: e.message,
      );
    } catch (e) {
      if (_isDisposed || _manualDisconnect || !_adapter.isAdapterOnNow) {
        return;
      }
      _scheduleReconnect(
        deviceId,
        attempt: attempt + 1,
        errorMessage: '重連失敗：$e',
      );
    }
  }

  void _onAdapterStateChanged(bool isOn) {
    if (_isDisposed) return;
    if (!isOn) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      unawaited(_adapter.stopScan());
      unawaited(_teardownActiveSession());
      _emitConnection(
        BleConnectionSnapshot(
          state: BleConnectionState.disconnected,
          device: _targetDevice,
          reconnectAttempt: 0,
          isBluetoothAdapterOn: false,
          errorMessage: '手機藍牙未開啟，請開啟藍牙以連線',
        ),
      );
      return;
    }

    _emitConnection(
      _connectionSnapshot.copyWith(
        isBluetoothAdapterOn: true,
        clearErrorMessage: true,
      ),
    );
  }

  void _onScanningChanged(bool scanning) {
    if (_isDisposed) return;
    if (!scanning && _connectionSnapshot.state == BleConnectionState.scanning) {
      _emitConnection(
        _connectionSnapshot.copyWith(
          state: _activeSession != null
              ? BleConnectionState.connected
              : BleConnectionState.disconnected,
          isBluetoothAdapterOn: _adapter.isAdapterOnNow,
        ),
      );
    }
  }

  void _onScanEntries(List<BleRawScanEntry> entries) {
    if (_isDisposed) return;
    _latestRawScanEntries = List<BleRawScanEntry>.unmodifiable(entries);
    _emitFilteredScanResults();
  }

  List<BleDeviceItem> _filterEntries(List<BleRawScanEntry> entries) {
    final items = entries
        .where((entry) => _includeAllDevices || entry.matchesPomodoro)
        .map((entry) => entry.toDeviceItem())
        .toList();
    items.sort((a, b) {
      if (a.matchesPomodoroService != b.matchesPomodoroService) {
        return a.matchesPomodoroService ? -1 : 1;
      }
      return b.rssi.compareTo(a.rssi);
    });
    return List<BleDeviceItem>.unmodifiable(items);
  }

  void _emitFilteredScanResults() {
    if (_scanController.isClosed) return;
    _scanController.add(_filterEntries(_latestRawScanEntries));
  }

  BleDeviceItem _resolveDeviceItem(String deviceId) {
    for (final entry in _latestRawScanEntries) {
      if (entry.id == deviceId) {
        return entry.toDeviceItem();
      }
    }
    if (_targetDevice != null && _targetDevice!.id == deviceId) {
      return _targetDevice!;
    }
    return BleDeviceItem(
      id: deviceId,
      name: deviceId,
      rssi: 0,
      isMock: false,
      matchesPomodoroService: false,
    );
  }

  Future<void> _teardownActiveSession() async {
    final queue = _rpcQueue;
    _rpcQueue = null;
    queue?.failAllPending(const BleDisconnectedException());
    queue?.dispose();

    final rpcSub = _rpcNotifySub;
    _rpcNotifySub = null;
    final statusSub = _statusNotifySub;
    _statusNotifySub = null;
    final disconnectSub = _sessionDisconnectSub;
    _sessionDisconnectSub = null;
    final session = _activeSession;
    _activeSession = null;

    await Future.wait(<Future<void>>[
      ?rpcSub?.cancel(),
      ?statusSub?.cancel(),
      ?disconnectSub?.cancel(),
      ?session?.close(),
    ]);
  }

  void _emitConnection(BleConnectionSnapshot snapshot) {
    _connectionSnapshot = snapshot;
    if (!_connectionController.isClosed) {
      _connectionController.add(snapshot);
    }
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('RealBleRepository has already been disposed');
    }
  }

  static String _permissionMessage(BlePermissionResult result) {
    return switch (result) {
      BlePermissionResult.granted => '',
      BlePermissionResult.denied => '請授予藍牙掃描與連線權限，否則無法搜尋 SmartPomodoro 裝置',
      BlePermissionResult.permanentlyDenied =>
        '藍牙權限已被永久拒絕，請至系統設定開啟「鄰近裝置」權限',
    };
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_adapterSub?.cancel());
    unawaited(_scanningSub?.cancel());
    unawaited(_scanEntriesSub?.cancel());
    unawaited(_teardownActiveSession());
    _connectionController.close();
    _statusController.close();
    _scanController.close();
  }
}
