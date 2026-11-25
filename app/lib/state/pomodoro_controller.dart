import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/app_logger.dart';
import '../core/protocol/protocol_constants.dart';
import '../core/protocol/protocol_exceptions.dart';
import '../data/ble/ble_repository.dart';
import '../data/ble/mock_ble_repository.dart';
import '../data/models/device_config.dart';
import '../data/models/device_status.dart';
import '../data/models/todo_item.dart';
import 'ble_providers.dart';
import 'config_controller.dart';
import 'todo_controller.dart';

/// Immutable UI snapshot combining BLE link state, ESP32 device status,
/// cached settings, bindable To-Dos, and the disconnect safety valve timer.
class PomodoroViewState {
  const PomodoroViewState({
    required this.connection,
    required this.status,
    this.config = const DeviceConfig.defaults(),
    this.todos = const <TodoItem>[],
    this.selectedTodoId = BleProtocolConstants.unboundTodoId,
    this.isBusy = false,
    this.safetyValveRemainingSeconds,
    this.safetyValveTripped = false,
    this.errorMessage,
  });

  final BleConnectionSnapshot connection;
  final DeviceStatus status;
  final DeviceConfig config;
  final List<TodoItem> todos;
  final int selectedTodoId;
  final bool isBusy;
  final int? safetyValveRemainingSeconds;
  final bool safetyValveTripped;
  final String? errorMessage;

  bool get isConnected => connection.state.isConnected;

  bool get isControlsLocked => !isConnected || isBusy;

  bool get isSafetyValveActive =>
      !isConnected &&
      safetyValveRemainingSeconds != null &&
      safetyValveRemainingSeconds! > 0;

  int get displaySeconds {
    if (isSafetyValveActive) {
      return safetyValveRemainingSeconds!;
    }
    if (!isConnected && safetyValveTripped) {
      return 0;
    }
    if (status.state == PomodoroState.idle) {
      return config.focusMinutes * 60;
    }
    return status.remainingSeconds;
  }

  double get displayProgress {
    if (status.state == PomodoroState.idle) {
      return 0.0;
    }
    if (!isConnected && safetyValveTripped) {
      return 0.0;
    }
    if (isSafetyValveActive && status.totalSeconds > 0) {
      return (safetyValveRemainingSeconds! / status.totalSeconds)
          .clamp(0.0, 1.0);
    }
    return status.progress;
  }

  String? get boundTodoTitle {
    final activeId =
        status.state == PomodoroState.idle ? selectedTodoId : status.todoId;
    if (activeId == BleProtocolConstants.unboundTodoId) {
      return null;
    }
    for (final todo in todos) {
      if (todo.id == activeId) return todo.title;
    }
    return 'Task #$activeId';
  }

  PomodoroViewState copyWith({
    BleConnectionSnapshot? connection,
    DeviceStatus? status,
    DeviceConfig? config,
    List<TodoItem>? todos,
    int? selectedTodoId,
    bool? isBusy,
    int? safetyValveRemainingSeconds,
    bool clearSafetyValve = false,
    bool? safetyValveTripped,
    String? errorMessage,
    bool clearError = false,
  }) {
    return PomodoroViewState(
      connection: connection ?? this.connection,
      status: status ?? this.status,
      config: config ?? this.config,
      todos: todos ?? this.todos,
      selectedTodoId: selectedTodoId ?? this.selectedTodoId,
      isBusy: isBusy ?? this.isBusy,
      safetyValveRemainingSeconds: clearSafetyValve
          ? null
          : (safetyValveRemainingSeconds ?? this.safetyValveRemainingSeconds),
      safetyValveTripped: safetyValveTripped ?? this.safetyValveTripped,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Formats seconds as `MM:SS` (e.g. `25:00`, `00:05`).
String formatMmSs(int totalSeconds) {
  final safe = totalSeconds < 0 ? 0 : totalSeconds;
  final minutes = (safe ~/ 60).toString().padLeft(2, '0');
  final seconds = (safe % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Coordinates Pomodoro timer state, control RPCs, and the disconnect
/// safety-valve countdown (`docs/spec.md` §2 & §4.1.2).
class PomodoroController extends Notifier<PomodoroViewState> {
  StreamSubscription<BleConnectionSnapshot>? _connectionSub;
  StreamSubscription<DeviceStatus>? _statusSub;
  Timer? _safetyValveTimer;
  bool _disposed = false;
  late BleConnectionState _lastConnectionState;

  @override
  PomodoroViewState build() {
    _disposed = false;
    final repo = ref.watch(bleRepositoryProvider);
    final initialTodos = ref.read(todoControllerProvider);
    final initialConfig = ref.read(configControllerProvider);
    _lastConnectionState = repo.currentConnection.state;

    _connectionSub?.cancel();
    _statusSub?.cancel();
    _safetyValveTimer?.cancel();

    _connectionSub = repo.connectionStream.listen(_onConnectionChanged);
    _statusSub = repo.statusStream.listen(_onStatusReceived);

    ref.listen<TodoListState>(todoControllerProvider, (_, next) {
      if (_disposed) return;
      var nextSelected = state.selectedTodoId;
      if (nextSelected != BleProtocolConstants.unboundTodoId &&
          !next.items.any((t) => t.id == nextSelected)) {
        nextSelected = BleProtocolConstants.unboundTodoId;
      }
      if (identical(state.todos, next.items) &&
          nextSelected == state.selectedTodoId) {
        return;
      }
      state = state.copyWith(
        todos: next.items,
        selectedTodoId: nextSelected,
      );
    });

    ref.listen<ConfigState>(configControllerProvider, (_, next) {
      if (_disposed) return;
      if (state.config == next.config) return;
      state = state.copyWith(config: next.config);
    });

    ref.onDispose(() {
      _disposed = true;
      _connectionSub?.cancel();
      _statusSub?.cancel();
      _safetyValveTimer?.cancel();
      _safetyValveTimer = null;
    });

    return PomodoroViewState(
      connection: repo.currentConnection,
      status: repo.latestStatus ?? const DeviceStatus.initial(),
      config: initialConfig.config,
      todos: initialTodos.items,
    );
  }

  void selectTodo(int todoId) {
    if (state.status.state != PomodoroState.idle) return;
    state = state.copyWith(selectedTodoId: todoId);
  }

  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  /// Applies a freshly fetched [DeviceStatus] snapshot (e.g. from Step 4 handshake).
  void applyDeviceStatus(DeviceStatus status) {
    if (_disposed) return;
    state = state.copyWith(status: status, clearError: true);
  }

  Future<void> _refreshStatusOnly() async {
    if (_disposed) return;
    final repo = ref.read(bleRepositoryProvider);
    if (!repo.currentConnection.state.isConnected) return;

    try {
      final status = await repo.readStatus();
      if (_disposed) return;
      state = state.copyWith(status: status, clearError: true);
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return;
      state = state.copyWith(errorMessage: e.message);
    }
  }

  Future<void> refreshSnapshot() async {
    await _refreshStatusOnly();
    if (_disposed) return;
    await Future.wait(<Future<void>>[
      ref.read(configControllerProvider.notifier).loadConfig(),
      ref.read(todoControllerProvider.notifier).loadTodos(),
    ]);
  }

  Future<void> startFocus() => _runControl((repo) {
        return repo.startFocus(todoId: state.selectedTodoId);
      });

  Future<void> startBreak() => _runControl((repo) => repo.startBreak());

  Future<void> pause() => _runControl((repo) => repo.pauseTimer());

  Future<void> resume() => _runControl((repo) => repo.resumeTimer());

  Future<void> stop() => _runControl((repo) => repo.stopTimer());

  Future<void> reconnectNow() async {
    if (_disposed) return;
    final isMock = ref.read(isMockBleModeProvider);
    final repo = ref.read(bleRepositoryProvider);
    final deviceId = isMock
        ? (state.connection.device?.id ?? MockBleRepository.mockDevice.id)
        : (state.connection.device?.id ??
              ref.read(preferencesStoreProvider).lastDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      state = state.copyWith(
        errorMessage: '尚未配對裝置，請點擊「掃描裝置」搜尋 SmartPomodoro',
      );
      return;
    }
    try {
      await repo.connect(deviceId);
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return;
      state = state.copyWith(errorMessage: e.message);
    }
  }

  Future<void> _runControl(
    Future<void> Function(BleRepository repo) action,
  ) async {
    if (_disposed || state.isControlsLocked) return;
    final repo = ref.read(bleRepositoryProvider);
    state = state.copyWith(isBusy: true, clearError: true);
    try {
      await action(repo);
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return;
      state = state.copyWith(errorMessage: e.message);
    } finally {
      if (!_disposed) {
        state = state.copyWith(isBusy: false);
      }
    }
  }

  void _onStatusReceived(DeviceStatus nextStatus) {
    if (_disposed) return;
    if (state.isConnected &&
        (state.safetyValveRemainingSeconds != null ||
            state.safetyValveTripped)) {
      _cancelSafetyValve();
    }
    state = state.copyWith(status: nextStatus);
  }

  void _onConnectionChanged(BleConnectionSnapshot next) {
    if (_disposed) return;
    final wasConnected = _lastConnectionState.isConnected;
    _lastConnectionState = next.state;

    if (wasConnected && !next.state.isConnected) {
      // Dropped connection: trigger local safety-valve estimation if previously
      // in FOCUS_RUNNING (`docs/spec.md` §4.1.2).
      if (state.status.state == PomodoroState.focusRunning &&
          state.status.remainingSeconds > 0) {
        _startSafetyValve(state.status.remainingSeconds, next);
      } else {
        state = state.copyWith(connection: next);
      }
      return;
    }

    if (!wasConnected && next.state.isConnected) {
      _cancelSafetyValve();
      state = state.copyWith(
        connection: next,
        clearSafetyValve: true,
        safetyValveTripped: false,
        clearError: true,
      );
      return;
    }

    state = state.copyWith(connection: next);
  }

  void _startSafetyValve(int initialSeconds, BleConnectionSnapshot connection) {
    _safetyValveTimer?.cancel();
    AppLogger.instance.guard(
      'Disconnected during FOCUS_RUNNING; starting safety-valve countdown ($initialSeconds s)',
    );
    state = state.copyWith(
      connection: connection,
      safetyValveRemainingSeconds: initialSeconds,
      safetyValveTripped: false,
    );

    _safetyValveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed || state.isConnected) {
        _cancelSafetyValve();
        return;
      }
      final current = state.safetyValveRemainingSeconds ?? 0;
      if (current <= 1) {
        _safetyValveTimer?.cancel();
        _safetyValveTimer = null;
        AppLogger.instance.guard(
          'Safety valve countdown reached 0 while disconnected',
        );
        state = state.copyWith(
          safetyValveRemainingSeconds: 0,
          safetyValveTripped: true,
        );
        return;
      }
      state = state.copyWith(safetyValveRemainingSeconds: current - 1);
    });
  }

  void _cancelSafetyValve() {
    _safetyValveTimer?.cancel();
    _safetyValveTimer = null;
  }
}

final pomodoroControllerProvider =
    NotifierProvider<PomodoroController, PomodoroViewState>(
  PomodoroController.new,
);
