/// BLE, GATT, state machine, command, and error constants defined in
/// `docs/spec.md` (v1.2).
abstract final class BleProtocolConstants {
  static const String deviceNameExact = 'SmartPomodoro';
  static const String deviceNamePrefix = 'Pomodoro_';
  static const int targetMtu = 512;

  static const String serviceUuid = 'a0b1c2d3-e4f5-4678-9abc-def012345600';
  static const String rpcCharUuid = 'a0b1c2d3-e4f5-4678-9abc-def012345601';
  static const String statusCharUuid = 'a0b1c2d3-e4f5-4678-9abc-def012345602';

  static const int maxPacketBytes = 120;
  static const int asciiMin = 0x20;
  static const int asciiMax = 0x7E;
  static const Duration rpcTimeout = Duration(seconds: 3);

  static const int maxTodos = 10;
  static const int minTodoTitleLength = 1;
  static const int maxTodoTitleLength = 24;
  static const int unboundTodoId = -1;

  static const int minFocusMinutes = 1;
  static const int maxFocusMinutes = 120;
  static const int defaultFocusMinutes = 25;

  static const int minBreakMinutes = 1;
  static const int maxBreakMinutes = 60;
  static const int defaultBreakMinutes = 5;

  static const int minAwayCm = 20;
  static const int maxAwayCm = 300;
  static const int defaultAwayCm = 80;

  static const int minAwayGraceSec = 1;
  static const int maxAwayGraceSec = 60;
  static const int defaultAwayGraceSec = 5;

  static const int minAbortLogSeconds = 60;
}

/// Device-owned Pomodoro state machine (`spec.md` Section 2).
enum PomodoroState {
  idle(0, 'IDLE', '待機中'),
  focusRunning(1, 'FOCUS_RUNNING', '專注中'),
  focusPausedUser(2, 'FOCUS_PAUSED_USER', '專注暫停'),
  focusPausedAway(3, 'FOCUS_PAUSED_AWAY', '離位暫停'),
  breakRunning(4, 'BREAK_RUNNING', '休息中'),
  breakPausedUser(5, 'BREAK_PAUSED_USER', '休息暫停');

  const PomodoroState(this.code, this.specName, this.label);

  final int code;
  final String specName;
  final String label;

  bool get isFocus =>
      this == focusRunning ||
      this == focusPausedUser ||
      this == focusPausedAway;

  bool get isBreak => this == breakRunning || this == breakPausedUser;

  bool get isRunning => this == focusRunning || this == breakRunning;

  static PomodoroState fromCode(int code) {
    return tryFromCode(code) ??
        (throw ArgumentError.value(code, 'code', 'Unknown PomodoroState'));
  }

  static PomodoroState? tryFromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// Command identifiers (`cmd` Enum in `spec.md` Section 3.3).
enum CmdId {
  evtStatus(1, 'EVT_STATUS'),
  syncTime(10, 'CMD_SYNC_TIME'),
  startFocus(11, 'CMD_START_FOCUS'),
  startBreak(12, 'CMD_START_BREAK'),
  pause(13, 'CMD_PAUSE'),
  resume(14, 'CMD_RESUME'),
  stop(15, 'CMD_STOP'),
  cfgGet(100, 'CMD_CFG_GET'),
  cfgSet(101, 'CMD_CFG_SET'),
  todoGetLen(200, 'CMD_TODO_GET_LEN'),
  todoGet(201, 'CMD_TODO_GET'),
  todoAppend(202, 'CMD_TODO_APPEND'),
  todoUpdate(203, 'CMD_TODO_UPDATE'),
  todoDelete(204, 'CMD_TODO_DELETE'),
  todoSwap(205, 'CMD_TODO_SWAP'),
  histPeek(300, 'CMD_HIST_PEEK'),
  histAck(301, 'CMD_HIST_ACK');

  const CmdId(this.code, this.specName);

  final int code;
  final String specName;

  static CmdId fromCode(int code) {
    return tryFromCode(code) ??
        (throw ArgumentError.value(code, 'code', 'Unknown CmdId'));
  }

  static CmdId? tryFromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// Response status and error codes (`code` Enum in `spec.md` Section 3.4).
enum ErrCode {
  ok(0, 'ERR_OK', '執行成功'),
  invalidJson(1, 'ERR_INVALID_JSON', '通訊封包格式錯誤'),
  unknownCmd(2, 'ERR_UNKNOWN_CMD', '裝置不支援此指令'),
  invalidParam(3, 'ERR_INVALID_PARAM', '參數型別錯誤或超出合法範圍'),
  invalidState(4, 'ERR_INVALID_STATE', '目前裝置狀態不允許執行此操作'),
  todoFull(10, 'ERR_TODO_FULL', '待辦清單已達 10 筆上限'),
  todoOutOfRange(11, 'ERR_TODO_OUT_OF_RANGE', '待辦項目索引超出範圍'),
  todoInvalidTitle(
    12,
    'ERR_TODO_INVALID_TITLE',
    '待辦標題需為 1~24 字元純 ASCII',
  ),
  histEmpty(20, 'ERR_HIST_EMPTY', '目前沒有未同步的歷史紀錄'),
  histIdMismatch(21, 'ERR_HIST_ID_MISMATCH', '歷史紀錄同步編號不符');

  const ErrCode(this.code, this.specName, this.message);

  final int code;
  final String specName;
  final String message;

  static ErrCode? tryFromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }

  static String describe(int code) {
    return tryFromCode(code)?.message ?? '裝置回傳未知錯誤碼 ($code)';
  }
}

/// Session log type (`spec.md` Section 3.3.E).
enum SessionType {
  focus(0, 'FOCUS', '專注'),
  breakSession(1, 'BREAK', '休息');

  const SessionType(this.code, this.specName, this.label);

  final int code;
  final String specName;
  final String label;

  static SessionType fromCode(int code) {
    return tryFromCode(code) ??
        (throw ArgumentError.value(code, 'code', 'Unknown SessionType'));
  }

  static SessionType? tryFromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// Session log completion result (`spec.md` Section 3.3.E).
enum SessionResult {
  completed(0, 'COMPLETED', '已完成'),
  aborted(1, 'ABORTED', '中途停止');

  const SessionResult(this.code, this.specName, this.label);

  final int code;
  final String specName;
  final String label;

  static SessionResult fromCode(int code) {
    return tryFromCode(code) ??
        (throw ArgumentError.value(code, 'code', 'Unknown SessionResult'));
  }

  static SessionResult? tryFromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
