import '../../data/ble/mock_ble_repository.dart';
import '../logging/app_logger.dart';
import 'protocol_constants.dart';
import 'protocol_exceptions.dart';

/// Executes an end-to-end closed-loop check against an isolated
/// [MockBleRepository] instance to verify Phase 1 state transitions,
/// proximity pause/resume, offline background completion, and NVS history sync.
Future<String> runMockBleSelfCheck({AppLogger? logger}) async {
  final activeLogger = logger ?? AppLogger.instance;
  activeLogger.app('Running MockBleRepository closed-loop self-check');

  final mock = MockBleRepository(logger: activeLogger);
  try {
    await mock.syncTime(epochSeconds: 1763970900, tzOffsetSeconds: 28800);
    final appended = await mock.appendTodo('Mock Task');

    await mock.startFocus(todoId: appended.id);
    if (mock.latestStatus?.state != PomodoroState.focusRunning) {
      throw StateError('Expected FOCUS_RUNNING after startFocus');
    }

    mock.simulateAway(true);
    if (mock.latestStatus?.state != PomodoroState.focusPausedAway) {
      throw StateError('Expected FOCUS_PAUSED_AWAY on away=true');
    }

    mock.simulateAway(false);
    if (mock.latestStatus?.state != PomodoroState.focusRunning) {
      throw StateError('Expected FOCUS_RUNNING on away=false');
    }

    // Disconnect while running: RPC must fail, but virtual device finishes
    // countdown offline into simulated NVS.
    mock.simulateDisconnect();
    var blockedWhileDisconnected = false;
    try {
      await mock.pauseTimer();
    } on BleDisconnectedException {
      blockedWhileDisconnected = true;
    }
    if (!blockedWhileDisconnected) {
      throw StateError('Expected BleDisconnectedException while disconnected');
    }

    mock.fastForwardRemaining(0);
    await mock.simulateReconnect();

    final status = await mock.readStatus();
    if (status.state != PomodoroState.idle || status.unsyncedCount < 1) {
      throw StateError(
        'Expected IDLE with unsynced log after offline completion, got $status',
      );
    }

    final peeked = await mock.peekHistory();
    if (peeked == null || peeked.todoId != appended.id) {
      throw StateError('Expected synced SessionLog bound to todoId=${appended.id}');
    }
    final remaining = await mock.ackHistory(peeked.logId);
    if (remaining != status.unsyncedCount - 1) {
      throw StateError('Unexpected remaining unsynced count: $remaining');
    }

    final summary =
        '通過：狀態機離位暫停/回座、斷線背景完賽 (log_id=${peeked.logId})、重連補帳 (unsynced=$remaining)';
    activeLogger.app('Mock BLE self-check passed: $summary');
    return summary;
  } finally {
    mock.dispose();
  }
}
