import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';

/// Live device snapshot pushed via `EVT_STATUS (cmd: 1)` on `Status (...5602)`.
class DeviceStatus {
  const DeviceStatus({
    required this.state,
    required this.remainingSeconds,
    required this.totalSeconds,
    required this.isAway,
    required this.todoId,
    required this.unsyncedCount,
  });

  const DeviceStatus.initial()
      : state = PomodoroState.idle,
        remainingSeconds = 0,
        totalSeconds = 0,
        isAway = false,
        todoId = BleProtocolConstants.unboundTodoId,
        unsyncedCount = 0;

  factory DeviceStatus.fromData(Map<String, dynamic> data) {
    final rawState = data['state'];
    final rem = data['rem'];
    final tot = data['tot'];
    final away = data['away'];
    final todoId = data['todo_id'];
    final unsynced = data['unsynced'];

    if (rawState is! int ||
        rem is! int ||
        tot is! int ||
        away is! bool ||
        todoId is! int ||
        unsynced is! int) {
      throw const PacketValidationException('Invalid EVT_STATUS payload');
    }

    final parsedState = PomodoroState.tryFromCode(rawState);
    if (parsedState == null) {
      throw PacketValidationException('Unknown Pomodoro state: $rawState');
    }

    return DeviceStatus(
      state: parsedState,
      remainingSeconds: rem,
      totalSeconds: tot,
      isAway: away,
      todoId: todoId,
      unsyncedCount: unsynced,
    );
  }

  final PomodoroState state;
  final int remainingSeconds;
  final int totalSeconds;
  final bool isAway;
  final int todoId;
  final int unsyncedCount;

  bool get hasBoundTodo => todoId != BleProtocolConstants.unboundTodoId;

  int get elapsedSeconds =>
      totalSeconds > remainingSeconds ? totalSeconds - remainingSeconds : 0;

  double get progress {
    if (totalSeconds <= 0) return 0;
    final ratio = remainingSeconds / totalSeconds;
    return ratio.clamp(0.0, 1.0);
  }

  Map<String, dynamic> toData() => <String, dynamic>{
        'state': state.code,
        'rem': remainingSeconds,
        'tot': totalSeconds,
        'away': isAway,
        'todo_id': todoId,
        'unsynced': unsyncedCount,
      };

  DeviceStatus copyWith({
    PomodoroState? state,
    int? remainingSeconds,
    int? totalSeconds,
    bool? isAway,
    int? todoId,
    int? unsyncedCount,
  }) {
    return DeviceStatus(
      state: state ?? this.state,
      remainingSeconds: remainingSeconds ?? this.remainingSeconds,
      totalSeconds: totalSeconds ?? this.totalSeconds,
      isAway: isAway ?? this.isAway,
      todoId: todoId ?? this.todoId,
      unsyncedCount: unsyncedCount ?? this.unsyncedCount,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceStatus &&
        other.state == state &&
        other.remainingSeconds == remainingSeconds &&
        other.totalSeconds == totalSeconds &&
        other.isAway == isAway &&
        other.todoId == todoId &&
        other.unsyncedCount == unsyncedCount;
  }

  @override
  int get hashCode => Object.hash(
        state,
        remainingSeconds,
        totalSeconds,
        isAway,
        todoId,
        unsyncedCount,
      );

  @override
  String toString() =>
      'DeviceStatus(state: ${state.specName}, rem: $remainingSeconds/$totalSeconds, away: $isAway, todoId: $todoId, unsynced: $unsyncedCount)';
}
