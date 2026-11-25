import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/core/protocol/packet_envelope.dart';
import 'package:pomodoro/core/protocol/protocol_constants.dart';
import 'package:pomodoro/core/protocol/protocol_exceptions.dart';
import 'package:pomodoro/core/protocol/protocol_self_check.dart';
import 'package:pomodoro/data/ble/rpc_command_queue.dart';

void main() {
  group('RpcCommandQueue', () {
    test('executes commands strictly serially in FIFO order', () async {
      final logger = AppLogger(printer: (_) {});
      addTearDown(logger.dispose);

      final writtenCmds = <int>[];
      final queue = RpcCommandQueue(
        logger: logger,
        writer: (bytes) async {
          writtenCmds.add(RpcRequest.fromBytes(bytes).cmd);
        },
      );
      addTearDown(queue.dispose);

      final f1 = queue.enqueue(RpcRequest.command(CmdId.syncTime));
      final f2 = queue.enqueue(RpcRequest.command(CmdId.cfgGet));
      final f3 = queue.enqueue(RpcRequest.command(CmdId.todoGetLen));

      await Future<void>.delayed(Duration.zero);
      // Only the 1st command may be written while in-flight.
      expect(writtenCmds, <int>[10]);
      expect(queue.hasInFlight, isTrue);
      expect(queue.pendingCount, 2);

      queue.handleResponse(RpcResponse(cmd: 10, code: 0));
      final r1 = await f1;
      expect(r1.cmd, 10);
      await Future<void>.delayed(Duration.zero);
      expect(writtenCmds, <int>[10, 100]);

      queue.handleResponse(RpcResponse(cmd: 100, code: 0));
      final r2 = await f2;
      expect(r2.cmd, 100);
      await Future<void>.delayed(Duration.zero);
      expect(writtenCmds, <int>[10, 100, 200]);

      queue.handleResponse(
        RpcResponse(cmd: 200, code: 0, data: const {'len': 2, 'max': 10}),
      );
      final r3 = await f3;
      expect(r3.data['len'], 2);
      expect(queue.hasInFlight, isFalse);
      expect(queue.pendingCount, 0);
    });

    test('ignores mismatched or malformed notifications while awaiting match',
        () async {
      final logger = AppLogger(printer: (_) {});
      addTearDown(logger.dispose);

      final queue = RpcCommandQueue(
        logger: logger,
        writer: (_) async {},
      );
      addTearDown(queue.dispose);

      final future = queue.enqueue(RpcRequest.command(CmdId.cfgGet));
      await Future<void>.delayed(Duration.zero);

      queue.handleNotificationBytes(<int>[0x7B, 0x01]); // invalid ASCII JSON
      queue.handleResponse(RpcResponse(cmd: 10, code: 0)); // wrong cmd
      expect(queue.hasInFlight, isTrue);

      queue.handleResponse(RpcResponse(cmd: 100, code: 0));
      final res = await future;
      expect(res.cmd, 100);
    });

    test('times out in-flight command and advances to next queued command',
        () async {
      final logger = AppLogger(printer: (_) {});
      addTearDown(logger.dispose);

      final writtenCmds = <int>[];
      final queue = RpcCommandQueue(
        logger: logger,
        timeout: const Duration(milliseconds: 30),
        writer: (bytes) async {
          writtenCmds.add(RpcRequest.fromBytes(bytes).cmd);
        },
      );
      addTearDown(queue.dispose);

      final first = queue.enqueue(RpcRequest.command(CmdId.syncTime));
      final second = queue.enqueue(RpcRequest.command(CmdId.cfgGet));

      await expectLater(first, throwsA(isA<BleTimeoutException>()));
      await Future<void>.delayed(Duration.zero);
      expect(writtenCmds, <int>[10, 100]);

      queue.handleResponse(RpcResponse(cmd: 100, code: 0));
      final secondResp = await second;
      expect(secondResp.cmd, 100);
    });

    test('rejects all pending commands immediately on disconnect', () async {
      final logger = AppLogger(printer: (_) {});
      addTearDown(logger.dispose);

      final queue = RpcCommandQueue(
        logger: logger,
        writer: (_) async {},
      );
      addTearDown(queue.dispose);

      final first = queue.enqueue(RpcRequest.command(CmdId.syncTime));
      final second = queue.enqueue(RpcRequest.command(CmdId.cfgGet));
      await Future<void>.delayed(Duration.zero);

      queue.failAllPending();

      await expectLater(first, throwsA(isA<BleDisconnectedException>()));
      await expectLater(second, throwsA(isA<BleDisconnectedException>()));
      expect(queue.hasInFlight, isFalse);
      expect(queue.pendingCount, 0);
    });

    test('sendAndEnsureOk throws RpcErrorException on non-zero code', () async {
      final logger = AppLogger(printer: (_) {});
      addTearDown(logger.dispose);

      late final RpcCommandQueue queue;
      queue = RpcCommandQueue(
        logger: logger,
        writer: (bytes) async {
          final req = RpcRequest.fromBytes(bytes);
          if (req.cmd == CmdId.todoAppend.code) {
            queue.handleResponse(
              RpcResponse(cmd: req.cmd, code: ErrCode.todoFull.code),
            );
          } else {
            queue.handleResponse(
              RpcResponse(cmd: req.cmd, code: ErrCode.histEmpty.code),
            );
          }
        },
      );
      addTearDown(queue.dispose);

      await expectLater(
        queue.sendAndEnsureOk(
          RpcRequest.command(CmdId.todoAppend, const {'t': 'Full List'}),
        ),
        throwsA(
          isA<RpcErrorException>()
              .having((e) => e.errCode, 'errCode', ErrCode.todoFull),
        ),
      );

      final histResp = await queue.enqueue(RpcRequest.command(CmdId.histPeek));
      expect(histResp.errCode, ErrCode.histEmpty);
    });

    test('runProtocolSelfCheck passes cleanly and logs TX/RX entries',
        () async {
      final logger = AppLogger(printer: (_) {});
      addTearDown(logger.dispose);

      final summary = await runProtocolSelfCheck(logger: logger);
      expect(summary, contains('通過'));
      expect(
        logger.entries.where((e) => e.category == LogCategory.bleTx).length,
        3,
      );
      expect(
        logger.entries.where((e) => e.category == LogCategory.bleRx).length,
        3,
      );
    });
  });
}
