import '../../data/ble/rpc_command_queue.dart';
import '../../data/models/device_config.dart';
import '../../data/models/device_status.dart';
import '../../data/models/session_log.dart';
import '../../data/models/todo_item.dart';
import '../logging/app_logger.dart';
import 'packet_envelope.dart';
import 'protocol_constants.dart';
import 'protocol_exceptions.dart';

/// Runs an on-device diagnostic check of the v1.2 protocol encoder/decoder,
/// model serialization, ASCII/120B guards, and serial [RpcCommandQueue].
Future<String> runProtocolSelfCheck({AppLogger? logger}) async {
  final activeLogger = logger ?? AppLogger.instance;
  activeLogger.app('Running v1.2 protocol & queue self-check');

  // 1. Validate spec packet serialization and model parsing.
  final appendReq = RpcRequest.command(
    CmdId.todoAppend,
    const <String, dynamic>{'t': 'Write Report'},
  );
  final appendBytes = appendReq.toBytes();
  final statusResp = RpcResponse.fromJsonString(
    '{"cmd":1,"code":0,"data":{"state":1,"rem":1485,"tot":1500,"away":false,"todo_id":12,"unsynced":2}}',
  );
  final status = DeviceStatus.fromData(statusResp.data);
  if (status.state != PomodoroState.focusRunning ||
      status.remainingSeconds != 1485) {
    throw StateError('DeviceStatus parsing mismatch');
  }

  const cfg = DeviceConfig.defaults();
  cfg.validate();

  final todo = TodoItem.fromData(
    const <String, dynamic>{
      'i': 0,
      'id': 12,
      't': 'Embedded Final',
      'd': false,
    },
  );
  if (todo.title != 'Embedded Final') {
    throw StateError('TodoItem parsing mismatch');
  }

  final session = SessionLog.fromPeekData(
    const <String, dynamic>{
      'log_id': 104,
      'start': 0,
      'dur': 1500,
      'type': 0,
      'res': 0,
      'todo_id': 12,
    },
  ).resolveReceivedTimestamp(1763970900);
  if (!session.isEstimatedTime || session.startEpoch != 1763969400) {
    throw StateError('SessionLog start==0 estimation mismatch');
  }

  // 2. Verify non-ASCII rejection before transmission.
  var rejectedNonAscii = false;
  try {
    RpcRequest.command(
      CmdId.todoAppend,
      const <String, dynamic>{'t': '中文測試'},
    ).toBytes();
  } on PacketValidationException {
    rejectedNonAscii = true;
  }
  if (!rejectedNonAscii) {
    throw StateError('Expected non-ASCII todo title to be rejected');
  }

  // 3. Exercise 3-command sequential loopback through RpcCommandQueue.
  late final RpcCommandQueue queue;
  final sentCmds = <int>[];
  queue = RpcCommandQueue(
    logger: activeLogger,
    writer: (bytes) async {
      final decoded = RpcRequest.fromBytes(bytes);
      sentCmds.add(decoded.cmd);
      final Map<String, dynamic> responseData = switch (decoded.cmd) {
        10 => const <String, dynamic>{},
        100 => const DeviceConfig.defaults().toData(),
        202 => const <String, dynamic>{'i': 0, 'id': 1, 'len': 1},
        _ => const <String, dynamic>{},
      };
      final responseBytes = RpcResponse(
        cmd: decoded.cmd,
        code: ErrCode.ok.code,
        data: responseData,
      ).toBytes();
      queue.handleNotificationBytes(responseBytes);
    },
  );

  try {
    final results = await Future.wait(<Future<RpcResponse>>[
      queue.sendAndEnsureOk(
        RpcRequest.command(
          CmdId.syncTime,
          const <String, dynamic>{'epoch': 1763970900, 'tz': 28800},
        ),
      ),
      queue.sendAndEnsureOk(RpcRequest.command(CmdId.cfgGet)),
      queue.sendAndEnsureOk(appendReq),
    ]);

    if (sentCmds.length != 3 ||
        sentCmds[0] != CmdId.syncTime.code ||
        sentCmds[1] != CmdId.cfgGet.code ||
        sentCmds[2] != CmdId.todoAppend.code ||
        results.length != 3) {
      throw StateError('Serial queue sequence mismatch: $sentCmds');
    }
  } finally {
    queue.dispose();
  }

  final summary =
      '通過：ASCII/120B 檢查 (${appendBytes.length}B)、Model 解析、'
      '序列佇列 3 指令 (${sentCmds.join(" -> ")})';
  activeLogger.app('Self-check passed: $summary');
  return summary;
}
