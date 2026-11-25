import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/logging/app_logger.dart';
import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';
import 'ble_repository.dart';

/// Result of requesting platform BLE scan/connect runtime permissions.
enum BlePermissionResult { granted, denied, permanentlyDenied }

/// Raw peripheral advertisement summary produced by [BleClientAdapter].
class BleRawScanEntry {
  const BleRawScanEntry({
    required this.id,
    required this.name,
    required this.rssi,
    this.serviceUuids = const <String>[],
  });

  final String id;
  final String name;
  final int rssi;
  final List<String> serviceUuids;

  /// Matches `SmartPomodoro`, `Pomodoro_*`, or Service UUID `...5600` (`spec.md` §3.1).
  bool get matchesPomodoro {
    final normalizedName = name.trim();
    if (normalizedName == BleProtocolConstants.deviceNameExact ||
        normalizedName.startsWith(BleProtocolConstants.deviceNamePrefix)) {
      return true;
    }
    final targetUuid = BleProtocolConstants.serviceUuid.toLowerCase();
    return serviceUuids.any((uuid) => uuid.toLowerCase() == targetUuid);
  }

  BleDeviceItem toDeviceItem() {
    final trimmed = name.trim();
    return BleDeviceItem(
      id: id,
      name: trimmed.isEmpty ? '未命名裝置 ($id)' : trimmed,
      rssi: rssi,
      isMock: false,
      matchesPomodoroService: matchesPomodoro,
    );
  }
}

/// Active connected GATT channel exposing isolated `RPC (...5601)` and
/// `Status (...5602)` operations (`docs/spec.md` §3.1).
abstract class BleConnectedGattSession {
  String get deviceId;

  String get deviceName;

  int get negotiatedMtu;

  Stream<List<int>> get rpcNotifications;

  Stream<List<int>> get statusNotifications;

  Stream<void> get onDisconnected;

  Future<void> writeRpc(Uint8List bytes);

  Future<List<int>> readStatus();

  Future<void> close();
}

/// Abstract platform BLE transport adapter so [RealBleRepository] can be tested
/// deterministically without external ESP32 hardware (`plan.md` §4 Commit 7).
abstract class BleClientAdapter {
  bool get isAdapterOnNow;

  Stream<bool> get adapterOnStream;

  Stream<bool> get isScanningStream;

  Stream<List<BleRawScanEntry>> get scanEntriesStream;

  Future<bool> refreshAdapterOn() async => isAdapterOnNow;

  Future<BlePermissionResult> ensurePermissions();

  Future<bool> openSystemAppSettings();

  Future<void> startScan({Duration timeout = const Duration(seconds: 10)});

  Future<void> stopScan();

  Future<BleConnectedGattSession> connectAndSetupGatt(
    String deviceId, {
    Duration timeout = const Duration(seconds: 12),
  });

  Future<void> disconnectDevice(String deviceId);

  void dispose();
}

/// Production [BleClientAdapter] backed by `flutter_blue_plus` and `permission_handler`.
class FlutterBluePlusClientAdapter implements BleClientAdapter {
  FlutterBluePlusClientAdapter({AppLogger? logger})
    : _logger = logger ?? AppLogger.instance {
    _initAdapterMonitor();
    _initScanMonitors();
  }

  final AppLogger _logger;
  final StreamController<bool> _adapterOnController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isScanningController =
      StreamController<bool>.broadcast();
  final StreamController<List<BleRawScanEntry>> _scanEntriesController =
      StreamController<List<BleRawScanEntry>>.broadcast();

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<List<ScanResult>>? _scanResultsSub;

  bool _isAdapterOn = true;
  bool _isDisposed = false;

  void _initAdapterMonitor() {
    try {
      final current = FlutterBluePlus.adapterStateNow;
      if (_isDefinitiveAdapterOff(current)) {
        _isAdapterOn = false;
      } else if (current == BluetoothAdapterState.on) {
        _isAdapterOn = true;
      }

      _adapterSub = FlutterBluePlus.adapterState.listen(
        (state) {
          if (_isDisposed) return;
          bool? next;
          if (state == BluetoothAdapterState.on) {
            next = true;
          } else if (_isDefinitiveAdapterOff(state)) {
            next = false;
          }
          if (next != null && next != _isAdapterOn) {
            _isAdapterOn = next;
            _adapterOnController.add(next);
          }
        },
        onError: (_) {},
      );
    } catch (_) {
      // Unsupported platform in non-mobile unit tests; keep safe defaults.
    }
  }

  void _initScanMonitors() {
    try {
      _scanningSub = FlutterBluePlus.isScanning.listen(
        (scanning) {
          if (!_isDisposed) {
            _isScanningController.add(scanning);
          }
        },
        onError: (_) {},
      );
      _scanResultsSub = FlutterBluePlus.scanResults.listen(
        (results) {
          if (_isDisposed) return;
          final entries = results
              .map((result) {
                final advName = result.advertisementData.advName.trim();
                final platformName = result.device.platformName.trim();
                final name = advName.isNotEmpty ? advName : platformName;
                final serviceUuids = result.advertisementData.serviceUuids
                    .map((guid) => guid.str.toLowerCase())
                    .toList(growable: false);
                return BleRawScanEntry(
                  id: result.device.remoteId.str,
                  name: name,
                  rssi: result.rssi,
                  serviceUuids: serviceUuids,
                );
              })
              .toList(growable: false);
          _scanEntriesController.add(entries);
        },
        onError: (_) {},
      );
    } catch (_) {
      // Unsupported platform in non-mobile unit tests.
    }
  }

  static bool _isDefinitiveAdapterOff(BluetoothAdapterState state) {
    return state == BluetoothAdapterState.off ||
        state == BluetoothAdapterState.turningOff ||
        state == BluetoothAdapterState.unauthorized ||
        state == BluetoothAdapterState.unavailable;
  }

  @override
  bool get isAdapterOnNow => _isAdapterOn;

  @override
  Future<bool> refreshAdapterOn() async {
    try {
      final state = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(milliseconds: 500));
      final next = state == BluetoothAdapterState.on;
      if (next != _isAdapterOn) {
        _isAdapterOn = next;
        if (!_adapterOnController.isClosed) {
          _adapterOnController.add(next);
        }
      }
      return _isAdapterOn;
    } catch (_) {
      return _isAdapterOn;
    }
  }

  @override
  Stream<bool> get adapterOnStream => _adapterOnController.stream;

  @override
  Stream<bool> get isScanningStream => _isScanningController.stream;

  @override
  Stream<List<BleRawScanEntry>> get scanEntriesStream =>
      _scanEntriesController.stream;

  @override
  Future<BlePermissionResult> ensurePermissions() async {
    if (kIsWeb || !Platform.isAndroid) {
      return BlePermissionResult.granted;
    }

    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    final scanStatus = statuses[Permission.bluetoothScan];
    final connectStatus = statuses[Permission.bluetoothConnect];
    if (scanStatus == null || connectStatus == null) {
      return BlePermissionResult.denied;
    }
    if (scanStatus.isPermanentlyDenied || connectStatus.isPermanentlyDenied) {
      return BlePermissionResult.permanentlyDenied;
    }
    if (scanStatus.isGranted && connectStatus.isGranted) {
      return BlePermissionResult.granted;
    }
    return BlePermissionResult.denied;
  }

  @override
  Future<bool> openSystemAppSettings() => openAppSettings();

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: false,
        androidCheckLocationServices: false,
      );
    } on FlutterBluePlusException catch (e) {
      // Fallback for legacy Android <= 11 devices where scan needs location permission.
      final desc = (e.description ?? '').toLowerCase();
      if (!kIsWeb && Platform.isAndroid && desc.contains('location')) {
        final locStatus = await Permission.locationWhenInUse.request();
        if (locStatus.isGranted) {
          await FlutterBluePlus.startScan(
            timeout: timeout,
            androidUsesFineLocation: true,
            androidCheckLocationServices: true,
          );
          return;
        }
        throw BleConnectionException(
          locStatus.isPermanentlyDenied
              ? '此 Android 版本需要開啟位置權限才能掃描藍牙裝置'
              : '請授予位置權限以進行藍牙掃描',
        );
      }
      throw BleConnectionException(e.description ?? '無法啟動藍牙掃描');
    } catch (e) {
      throw BleConnectionException('藍牙掃描失敗：$e');
    }
  }

  @override
  Future<void> stopScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {
      // Ignore stop failures during teardown or adapter shutdown.
    }
  }

  @override
  Future<BleConnectedGattSession> connectAndSetupGatt(
    String deviceId, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final device = BluetoothDevice.fromId(deviceId);
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: timeout,
        mtu: null,
        autoConnect: false,
      );
    } on FlutterBluePlusException catch (e) {
      throw BleConnectionException(_describeConnectFailure(e));
    } catch (e) {
      throw BleConnectionException('藍牙連線失敗：$e');
    }

    var negotiatedMtu = 23;
    try {
      if (!kIsWeb && Platform.isAndroid) {
        negotiatedMtu = await device.requestMtu(
          BleProtocolConstants.targetMtu,
        );
        _logger.sync('Step 1: Android requestMtu(512) -> MTU=$negotiatedMtu');
      }

      final services = await device.discoverServices(timeout: 12);
      final targetServiceUuid = Guid(BleProtocolConstants.serviceUuid);
      final targetRpcUuid = Guid(BleProtocolConstants.rpcCharUuid);
      final targetStatusUuid = Guid(BleProtocolConstants.statusCharUuid);

      BluetoothService? matchedService;
      for (final service in services) {
        if (service.serviceUuid == targetServiceUuid) {
          matchedService = service;
          break;
        }
      }
      if (matchedService == null) {
        throw const BleConnectionException(
          '此裝置不包含 SmartPomodoro 服務 (...5600)，已中斷連線',
        );
      }

      BluetoothCharacteristic? rpcChar;
      BluetoothCharacteristic? statusChar;
      for (final characteristic in matchedService.characteristics) {
        if (characteristic.characteristicUuid == targetRpcUuid) {
          rpcChar = characteristic;
        } else if (characteristic.characteristicUuid == targetStatusUuid) {
          statusChar = characteristic;
        }
      }
      if (rpcChar == null || statusChar == null) {
        throw const BleConnectionException(
          '裝置缺少 RPC (...5601) 或 Status (...5602) 特徵，已中斷連線',
        );
      }

      await rpcChar.setNotifyValue(true);
      await statusChar.setNotifyValue(true);
      _logger.sync('Step 2: Subscribed Notify on RPC (...5601) & Status (...5602)');

      if (!device.isConnected) {
        throw const BleDisconnectedException();
      }

      return _FlutterBluePlusGattSession(
        device: device,
        rpcChar: rpcChar,
        statusChar: statusChar,
        negotiatedMtu: negotiatedMtu,
      );
    } catch (e) {
      try {
        await device.disconnect(queue: false, androidDelay: 0);
      } catch (_) {}
      if (e is PomodoroProtocolException) rethrow;
      if (e is FlutterBluePlusException) {
        throw BleConnectionException(_describeConnectFailure(e));
      }
      throw BleConnectionException('GATT 初始化失敗：$e');
    }
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    if (deviceId.isEmpty) return;
    try {
      final device = BluetoothDevice.fromId(deviceId);
      if (device.isConnected) {
        await device.disconnect(queue: false, androidDelay: 200);
      }
    } catch (_) {
      // Best-effort cleanup when link is already torn down.
    }
  }

  static String _describeConnectFailure(FlutterBluePlusException error) {
    if (error.code == FbpErrorCode.timeout.index) {
      return '連線逾時，請確認 SmartPomodoro 已開啟並靠近手機';
    }
    if (error.code == FbpErrorCode.adapterIsOff.index) {
      return '手機藍牙未開啟，請開啟藍牙以連線';
    }
    final detail = error.description;
    if (detail != null && detail.isNotEmpty) {
      return '藍牙連線失敗 ($detail)';
    }
    return '無法連線至藍牙裝置';
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _adapterSub?.cancel();
    _scanningSub?.cancel();
    _scanResultsSub?.cancel();
    _adapterOnController.close();
    _isScanningController.close();
    _scanEntriesController.close();
  }
}

class _FlutterBluePlusGattSession implements BleConnectedGattSession {
  _FlutterBluePlusGattSession({
    required this.device,
    required this.rpcChar,
    required this.statusChar,
    required this.negotiatedMtu,
  }) : _disconnectController = StreamController<void>.broadcast() {
    _connSub = device.connectionState
        .where((state) => state == BluetoothConnectionState.disconnected)
        .listen((_) {
          if (!_closed && !_disconnectController.isClosed) {
            _disconnectController.add(null);
          }
        });
  }

  final BluetoothDevice device;
  final BluetoothCharacteristic rpcChar;
  final BluetoothCharacteristic statusChar;
  @override
  final int negotiatedMtu;

  final StreamController<void> _disconnectController;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _closed = false;

  @override
  String get deviceId => device.remoteId.str;

  @override
  String get deviceName => device.platformName.trim().isNotEmpty
      ? device.platformName.trim()
      : device.advName.trim();

  @override
  Stream<List<int>> get rpcNotifications => rpcChar.onValueReceived;

  @override
  Stream<List<int>> get statusNotifications => statusChar.onValueReceived;

  @override
  Stream<void> get onDisconnected => _disconnectController.stream;

  @override
  Future<void> writeRpc(Uint8List bytes) async {
    if (_closed || device.isDisconnected) {
      throw const BleDisconnectedException();
    }
    final useWithoutResponse =
        !rpcChar.properties.write && rpcChar.properties.writeWithoutResponse;
    try {
      await rpcChar.write(bytes, withoutResponse: useWithoutResponse);
    } on FlutterBluePlusException catch (e) {
      if (e.code == FbpErrorCode.deviceIsDisconnected.index ||
          device.isDisconnected) {
        throw const BleDisconnectedException();
      }
      throw BleConnectionException(e.description ?? '寫入 RPC 指令失敗');
    }
  }

  @override
  Future<List<int>> readStatus() async {
    if (_closed || device.isDisconnected) {
      throw const BleDisconnectedException();
    }
    try {
      return await statusChar.read(timeout: 5);
    } on FlutterBluePlusException catch (e) {
      if (e.code == FbpErrorCode.deviceIsDisconnected.index ||
          device.isDisconnected) {
        throw const BleDisconnectedException();
      }
      throw BleConnectionException(e.description ?? '讀取裝置狀態失敗');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _connSub?.cancel();
    if (!_disconnectController.isClosed) {
      await _disconnectController.close();
    }
  }
}
