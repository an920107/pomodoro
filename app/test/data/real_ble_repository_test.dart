import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/core/protocol/packet_envelope.dart';
import 'package:pomodoro/core/protocol/protocol_constants.dart';
import 'package:pomodoro/core/protocol/protocol_exceptions.dart';
import 'package:pomodoro/data/ble/ble_client_adapter.dart';
import 'package:pomodoro/data/ble/ble_repository.dart';
import 'package:pomodoro/data/ble/handshake_coordinator.dart';
import 'package:pomodoro/data/ble/real_ble_repository.dart';
import 'package:pomodoro/data/local/app_database.dart';
import 'package:pomodoro/data/local/preferences_store.dart';
import 'package:pomodoro/data/models/device_config.dart';
import 'package:pomodoro/data/models/session_log.dart';
import 'package:pomodoro/data/models/todo_item.dart';
import 'package:pomodoro/state/ble_providers.dart';

class _FakeGattSession implements BleConnectedGattSession {
  _FakeGattSession({
    required this.deviceId,
    required this.deviceName,
    required this.negotiatedMtu,
    required this.onWriteRpc,
    required this.onReadStatus,
  });

  @override
  final String deviceId;
  @override
  final String deviceName;
  @override
  final int negotiatedMtu;

  final Future<void> Function(Uint8List bytes) onWriteRpc;
  final Future<List<int>> Function() onReadStatus;

  final StreamController<List<int>> _rpcController =
      StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _statusController =
      StreamController<List<int>>.broadcast();
  final StreamController<void> _disconnectController =
      StreamController<void>.broadcast();
  bool _closed = false;

  void emitRpc(Map<String, dynamic> envelope) {
    if (_closed || _rpcController.isClosed) return;
    _rpcController.add(utf8.encode(jsonEncode(envelope)));
  }

  void emitStatus(Map<String, dynamic> statusData) {
    if (_closed || _statusController.isClosed) return;
    final envelope = RpcResponse(
      cmd: CmdId.evtStatus.code,
      code: ErrCode.ok.code,
      data: statusData,
    ).toBytes();
    _statusController.add(envelope);
  }

  void triggerRemoteDisconnect() {
    if (_closed || _disconnectController.isClosed) return;
    _disconnectController.add(null);
  }

  @override
  Stream<List<int>> get rpcNotifications => _rpcController.stream;

  @override
  Stream<List<int>> get statusNotifications => _statusController.stream;

  @override
  Stream<void> get onDisconnected => _disconnectController.stream;

  @override
  Future<void> writeRpc(Uint8List bytes) => onWriteRpc(bytes);

  @override
  Future<List<int>> readStatus() => onReadStatus();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _rpcController.close();
    await _statusController.close();
    await _disconnectController.close();
  }
}

class _FakeBleClientAdapter implements BleClientAdapter {
  _FakeBleClientAdapter({this._adapterOn = true});

  final StreamController<bool> _adapterController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _scanningController =
      StreamController<bool>.broadcast();
  final StreamController<List<BleRawScanEntry>> _scanEntriesController =
      StreamController<List<BleRawScanEntry>>.broadcast();

  bool _adapterOn;
  BlePermissionResult permissionResult = BlePermissionResult.granted;
  bool failConnect = false;
  bool failMissingService = false;
  bool autoEmitScanEntries = true;
  int connectCalls = 0;
  int stopScanCalls = 0;
  final List<String> connectedIds = <String>[];
  final List<String> disconnectedIds = <String>[];
  final List<int> recordedRpcCommands = <int>[];
  _FakeGattSession? activeSession;

  List<BleRawScanEntry> scanCatalog = const <BleRawScanEntry>[];
  DeviceConfig serverConfig = const DeviceConfig.defaults();
  List<TodoItem> serverTodos = const <TodoItem>[
    TodoItem(index: 0, id: 1, title: 'Real BLE Task', done: false),
  ];
  List<SessionLog> serverHistory = <SessionLog>[
    const SessionLog(
      logId: 10,
      startEpoch: 0,
      durationSeconds: 1500,
      type: SessionType.focus,
      result: SessionResult.completed,
      todoId: 1,
    ),
  ];

  void setAdapterOn(bool isOn) {
    if (_adapterOn == isOn) return;
    _adapterOn = isOn;
    if (!_adapterController.isClosed) {
      _adapterController.add(isOn);
    }
  }

  void finishScan() {
    if (!_scanningController.isClosed) {
      _scanningController.add(false);
    }
  }

  @override
  bool get isAdapterOnNow => _adapterOn;

  @override
  Future<bool> refreshAdapterOn() async => _adapterOn;

  @override
  Stream<bool> get adapterOnStream => _adapterController.stream;

  @override
  Stream<bool> get isScanningStream => _scanningController.stream;

  @override
  Stream<List<BleRawScanEntry>> get scanEntriesStream =>
      _scanEntriesController.stream;

  @override
  Future<BlePermissionResult> ensurePermissions() async => permissionResult;

  @override
  Future<bool> openSystemAppSettings() async => true;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _scanningController.add(true);
    if (autoEmitScanEntries) {
      _scanEntriesController.add(scanCatalog);
      _scanningController.add(false);
    }
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
    if (!_scanningController.isClosed) {
      _scanningController.add(false);
    }
  }

  @override
  Future<BleConnectedGattSession> connectAndSetupGatt(
    String deviceId, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    connectCalls++;
    connectedIds.add(deviceId);
    if (failMissingService) {
      throw const BleConnectionException(
        '此裝置不包含 SmartPomodoro 服務 (...5600)，已中斷連線',
      );
    }
    if (failConnect) {
      throw const BleConnectionException('連線逾時，請確認 SmartPomodoro 已開啟並靠近手機');
    }

    final session = _FakeGattSession(
      deviceId: deviceId,
      deviceName: 'SmartPomodoro',
      negotiatedMtu: 512,
      onWriteRpc: (bytes) async {
        final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final cmd = (decoded['cmd'] as num).toInt();
        final data = (decoded['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        recordedRpcCommands.add(cmd);

        scheduleMicrotask(() {
          _respondToRpc(cmd, data);
        });
      },
      onReadStatus: () async {
        return RpcResponse(
          cmd: CmdId.evtStatus.code,
          code: ErrCode.ok.code,
          data: <String, dynamic>{
            'state': PomodoroState.idle.code,
            'rem': 0,
            'tot': 0,
            'away': false,
            'todo_id': BleProtocolConstants.unboundTodoId,
            'unsynced': serverHistory.length,
          },
        ).toBytes();
      },
    );
    activeSession = session;
    return session;
  }

  void _respondToRpc(int cmd, Map<String, dynamic> data) {
    final session = activeSession;
    if (session == null) return;
    switch (cmd) {
      case 10:
      case 11:
      case 12:
      case 13:
      case 14:
      case 15:
        session.emitRpc(<String, dynamic>{'cmd': cmd, 'code': 0, 'data': {}});
      case 100:
        session.emitRpc(<String, dynamic>{
          'cmd': 100,
          'code': 0,
          'data': serverConfig.toData(),
        });
      case 200:
        session.emitRpc(<String, dynamic>{
          'cmd': 200,
          'code': 0,
          'data': {'len': serverTodos.length, 'max': 10},
        });
      case 201:
        final idx = (data['i'] as num).toInt();
        final todo = serverTodos[idx];
        session.emitRpc(<String, dynamic>{
          'cmd': 201,
          'code': 0,
          'data': {
            'i': idx,
            'id': todo.id,
            't': todo.title,
            'd': todo.done,
          },
        });
      case 300:
        if (serverHistory.isEmpty) {
          session.emitRpc(<String, dynamic>{
            'cmd': 300,
            'code': ErrCode.histEmpty.code,
            'data': {},
          });
        } else {
          final log = serverHistory.first;
          session.emitRpc(<String, dynamic>{
            'cmd': 300,
            'code': 0,
            'data': {
              'log_id': log.logId,
              'start': log.startEpoch,
              'dur': log.durationSeconds,
              'type': log.type.code,
              'res': log.result.code,
              'todo_id': log.todoId,
            },
          });
        }
      case 301:
        final ackId = (data['log_id'] as num).toInt();
        if (serverHistory.isNotEmpty && serverHistory.first.logId == ackId) {
          serverHistory.removeAt(0);
          session.emitRpc(<String, dynamic>{
            'cmd': 301,
            'code': 0,
            'data': {'unsynced': serverHistory.length},
          });
        } else {
          session.emitRpc(<String, dynamic>{
            'cmd': 301,
            'code': ErrCode.histIdMismatch.code,
            'data': {},
          });
        }
    }
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {
    disconnectedIds.add(deviceId);
    await activeSession?.close();
    activeSession = null;
  }

  @override
  void dispose() {
    unawaited(_adapterController.close());
    unawaited(_scanningController.close());
    unawaited(_scanEntriesController.close());
  }
}

void main() {
  group('RealBleRepository', () {
    late AppLogger logger;
    late _FakeBleClientAdapter adapter;
    late InMemoryPreferencesStore prefs;
    late RealBleRepository repo;

    setUp(() {
      logger = AppLogger(printer: (_) {});
      adapter = _FakeBleClientAdapter();
      prefs = InMemoryPreferencesStore(isMockBleMode: false);
      repo = RealBleRepository(
        adapter: adapter,
        preferences: prefs,
        logger: logger,
      );
    });

    tearDown(() {
      repo.dispose();
      adapter.dispose();
      logger.dispose();
    });

    test('filters Pomodoro devices by name/UUID by default and allows all when toggled',
        () async {
      adapter.scanCatalog = const <BleRawScanEntry>[
        BleRawScanEntry(id: '11:22:33:44:55:01', name: 'RandomSpeaker', rssi: -45),
        BleRawScanEntry(
          id: '11:22:33:44:55:02',
          name: 'SmartPomodoro',
          rssi: -62,
        ),
        BleRawScanEntry(
          id: '11:22:33:44:55:03',
          name: 'ESP_CustomName',
          rssi: -58,
          serviceUuids: <String>[BleProtocolConstants.serviceUuid],
        ),
        BleRawScanEntry(
          id: '11:22:33:44:55:04',
          name: 'Pomodoro_9F1A',
          rssi: -70,
        ),
      ];

      final emitted = <List<BleDeviceItem>>[];
      final sub = repo.scanResultsStream.listen(emitted.add);
      addTearDown(sub.cancel);

      await repo.startScan(includeAllDevices: false);
      await Future<void>.delayed(Duration.zero);

      expect(emitted.last.map((d) => d.id).toList(), <String>[
        '11:22:33:44:55:03',
        '11:22:33:44:55:02',
        '11:22:33:44:55:04',
      ]);

      repo.setIncludeAllDevices(true);
      await Future<void>.delayed(Duration.zero);
      expect(emitted.last.map((d) => d.id).toList(), <String>[
        '11:22:33:44:55:03',
        '11:22:33:44:55:02',
        '11:22:33:44:55:04',
        '11:22:33:44:55:01',
      ]);
    });

    test('handles permission denied, missing service, and adapter off cleanly',
        () async {
      adapter.permissionResult = BlePermissionResult.permanentlyDenied;
      await expectLater(
        repo.startScan(),
        throwsA(isA<BleConnectionException>()),
      );
      expect(repo.currentConnection.errorMessage, contains('系統設定'));

      adapter.permissionResult = BlePermissionResult.granted;
      adapter.failMissingService = true;
      await expectLater(
        repo.connect('AA:BB:CC:DD:EE:01'),
        throwsA(isA<BleConnectionException>()),
      );
      expect(repo.currentConnection.state, BleConnectionState.disconnected);
      expect(repo.currentConnection.errorMessage, contains('...5600'));

      adapter.setAdapterOn(false);
      await Future<void>.delayed(Duration.zero);
      expect(repo.currentConnection.isBluetoothAdapterOn, isFalse);
      await expectLater(
        repo.startScan(),
        throwsA(isA<BleConnectionException>()),
      );
    });

    test('connects, persists lastDeviceId, and runs full 5-step HandshakeCoordinator',
        () async {
      final db = InMemoryAppDatabase();
      addTearDown(db.close);

      final coordinator = HandshakeCoordinator(
        repository: repo,
        database: db,
        nowEpochSeconds: () => 1700050000,
        tzOffsetSeconds: () => 28800,
        onLoadConfig: () => repo.getConfig(),
        onLoadTodos: () async {
          final meta = await repo.getTodoLength();
          final items = <TodoItem>[];
          for (var i = 0; i < meta.length; i++) {
            items.add(await repo.getTodoItem(i));
          }
          return items;
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();

      await repo.connect('AA:BB:CC:DD:EE:02');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(repo.currentConnection.state, BleConnectionState.connected);
      expect(prefs.lastDeviceId, 'AA:BB:CC:DD:EE:02');
      expect(prefs.lastDeviceName, 'SmartPomodoro');
      expect(adapter.recordedRpcCommands, <int>[10, 100, 200, 201, 300, 301]);

      final logs = await db.fetchAllSessionLogs();
      expect(logs, hasLength(1));
      expect(logs.single.log.isEstimatedTime, isTrue);
      expect(logs.single.displayTodoTitle, 'Real BLE Task');
    });

    testWidgets(
        'unexpected disconnect schedules 3s x 5 -> 10s backoff; manual disconnect cancels',
        (WidgetTester tester) async {
      final localLogger = AppLogger(printer: (_) {});
      final localAdapter = _FakeBleClientAdapter();
      final localPrefs = InMemoryPreferencesStore(isMockBleMode: false);
      final localRepo = RealBleRepository(
        adapter: localAdapter,
        preferences: localPrefs,
        logger: localLogger,
      );

      await localRepo.connect('AA:BB:CC:DD:EE:03');
      await tester.pump();
      expect(localRepo.currentConnection.state, BleConnectionState.connected);

      // Make subsequent reconnects fail so backoff advances 1..6.
      localAdapter.failConnect = true;
      localAdapter.activeSession!.triggerRemoteDisconnect();
      await tester.pump();

      expect(localRepo.currentConnection.state, BleConnectionState.reconnecting);
      expect(localRepo.currentConnection.reconnectAttempt, 1);
      expect(
        localRepo.currentConnection.nextRetryDelay,
        const Duration(seconds: 3),
      );

      final connectCountBeforeRetries = localAdapter.connectCalls;

      // Attempts 1..5 each run every 3s.
      for (var i = 1; i <= 5; i++) {
        await tester.pump(const Duration(seconds: 3));
        expect(localAdapter.connectCalls, connectCountBeforeRetries + i);
        expect(localRepo.currentConnection.reconnectAttempt, i + 1);
      }

      // Attempt 6 uses 10s delay, so after 9s it must NOT have fired yet.
      expect(
        localRepo.currentConnection.nextRetryDelay,
        const Duration(seconds: 10),
      );
      await tester.pump(const Duration(seconds: 9));
      expect(localAdapter.connectCalls, connectCountBeforeRetries + 5);

      // At 10s attempt 6 fires and schedules attempt 7 (10s).
      await tester.pump(const Duration(seconds: 1));
      expect(localAdapter.connectCalls, connectCountBeforeRetries + 6);
      expect(localRepo.currentConnection.reconnectAttempt, 7);

      // Manual disconnect stops all scheduled reconnect attempts.
      await localRepo.disconnect();
      expect(localRepo.currentConnection.state, BleConnectionState.disconnected);
      await tester.pump(const Duration(seconds: 30));
      expect(localAdapter.connectCalls, connectCountBeforeRetries + 6);

      localRepo.dispose();
      localAdapter.dispose();
      localLogger.dispose();
    });
  });

  group('SettingsScreen & DeviceScanSheet UI flow', () {
    testWidgets(
        'defaults to Mock mode, opens DeviceScanSheet, switches to Real BLE, handles empty/adapter-off, and falls back to Mock',
        (WidgetTester tester) async {
      final fakeAdapter = _FakeBleClientAdapter(adapterOn: true);
      final fakeAdapterLogger = AppLogger(printer: (_) {});
      addTearDown(fakeAdapterLogger.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bleClientAdapterProvider.overrideWith((ref) {
              ref.onDispose(fakeAdapter.dispose);
              return fakeAdapter;
            }),
          ],
          child: const PomodoroApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Default mode must be Mock.
      expect(find.text('Mock 已連線'), findsOneWidget);

      // Go to Settings tab and toggle Real BLE mode.
      await tester.tap(find.byKey(const Key('nav_settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chip_ble_mode_real')));
      await tester.pumpAndSettle();
      expect(find.text('BLE 未連線'), findsOneWidget);

      // Open scan sheet and scan -> shows empty state when no SmartPomodoro exists.
      await tester.tap(find.byKey(const Key('btn_open_scan_sheet')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet_device_scan')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_start_ble_scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('empty_ble_scan_results')), findsOneWidget);

      // Adapter OFF disables scan button and renders warning card.
      fakeAdapter.setAdapterOn(false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card_bt_adapter_off')), findsOneWidget);
      final scanBtn = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('btn_start_ble_scan')),
      );
      expect(scanBtn.onPressed, isNull);

      // Adapter ON re-enables scan button.
      fakeAdapter.setAdapterOn(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card_bt_adapter_off')), findsNothing);

      // Tap fallback button -> returns to Mock mode cleanly.
      await tester.tap(find.byKey(const Key('btn_empty_fallback_mock')));
      await tester.pumpAndSettle();
      expect(find.text('Mock 已連線'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
