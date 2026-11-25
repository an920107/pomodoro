import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';

/// Historical focus/break session record synced via `CMD_HIST_PEEK (300)`.
class SessionLog {
  const SessionLog({
    required this.logId,
    required this.startEpoch,
    required this.durationSeconds,
    required this.type,
    required this.result,
    required this.todoId,
    this.isEstimatedTime = false,
  });

  factory SessionLog.fromPeekData(Map<String, dynamic> data) {
    final logId = data['log_id'];
    final start = data['start'];
    final dur = data['dur'];
    final rawType = data['type'];
    final rawRes = data['res'];
    final todoId = data['todo_id'];

    if (logId is! int ||
        start is! int ||
        dur is! int ||
        rawType is! int ||
        rawRes is! int ||
        todoId is! int) {
      throw const PacketValidationException('Invalid CMD_HIST_PEEK payload');
    }

    final type = SessionType.tryFromCode(rawType);
    final result = SessionResult.tryFromCode(rawRes);
    if (type == null || result == null) {
      throw const PacketValidationException(
        'Unknown SessionType or SessionResult in CMD_HIST_PEEK',
      );
    }

    return SessionLog(
      logId: logId,
      startEpoch: start,
      durationSeconds: dur,
      type: type,
      result: result,
      todoId: todoId,
      isEstimatedTime: false,
    );
  }

  factory SessionLog.fromDbMap(Map<String, Object?> map) {
    return SessionLog(
      logId: map['log_id']! as int,
      startEpoch: map['start_epoch']! as int,
      durationSeconds: map['duration_sec']! as int,
      type: SessionType.fromCode(map['type']! as int),
      result: SessionResult.fromCode(map['result']! as int),
      todoId: map['todo_id']! as int,
      isEstimatedTime: (map['is_estimated_time']! as int) == 1,
    );
  }

  final int logId;
  final int startEpoch;
  final int durationSeconds;
  final SessionType type;
  final SessionResult result;
  final int todoId;
  final bool isEstimatedTime;

  /// When ESP32 logged a session before time sync (`start == 0`), `spec.md`
  /// §3.3.E estimates start time upon reception (`nowEpoch - durationSeconds`).
  SessionLog resolveReceivedTimestamp(int nowEpochSeconds) {
    if (startEpoch > 0) return this;
    final estimated = nowEpochSeconds - durationSeconds;
    return copyWith(
      startEpoch: estimated > 0 ? estimated : 0,
      isEstimatedTime: true,
    );
  }

  Map<String, dynamic> toPeekData() => <String, dynamic>{
        'log_id': logId,
        'start': startEpoch,
        'dur': durationSeconds,
        'type': type.code,
        'res': result.code,
        'todo_id': todoId,
      };

  Map<String, Object?> toDbMap({int? syncedAtEpoch}) => <String, Object?>{
        'log_id': logId,
        'start_epoch': startEpoch,
        'duration_sec': durationSeconds,
        'type': type.code,
        'result': result.code,
        'todo_id': todoId,
        'is_estimated_time': isEstimatedTime ? 1 : 0,
        'synced_at': ?syncedAtEpoch,
      };

  SessionLog copyWith({
    int? logId,
    int? startEpoch,
    int? durationSeconds,
    SessionType? type,
    SessionResult? result,
    int? todoId,
    bool? isEstimatedTime,
  }) {
    return SessionLog(
      logId: logId ?? this.logId,
      startEpoch: startEpoch ?? this.startEpoch,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      type: type ?? this.type,
      result: result ?? this.result,
      todoId: todoId ?? this.todoId,
      isEstimatedTime: isEstimatedTime ?? this.isEstimatedTime,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SessionLog &&
        other.logId == logId &&
        other.startEpoch == startEpoch &&
        other.durationSeconds == durationSeconds &&
        other.type == type &&
        other.result == result &&
        other.todoId == todoId &&
        other.isEstimatedTime == isEstimatedTime;
  }

  @override
  int get hashCode => Object.hash(
        logId,
        startEpoch,
        durationSeconds,
        type,
        result,
        todoId,
        isEstimatedTime,
      );
}
