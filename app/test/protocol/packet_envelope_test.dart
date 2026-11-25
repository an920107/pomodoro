import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/core/protocol/packet_envelope.dart';
import 'package:pomodoro/core/protocol/protocol_constants.dart';
import 'package:pomodoro/core/protocol/protocol_exceptions.dart';
import 'package:pomodoro/data/models/device_config.dart';
import 'package:pomodoro/data/models/device_status.dart';
import 'package:pomodoro/data/models/session_log.dart';
import 'package:pomodoro/data/models/todo_item.dart';

void main() {
  group('PacketEnvelope & AsciiValidator', () {
    test('encodes and decodes spec v1.2 request and response examples', () {
      final request = RpcRequest.command(
        CmdId.todoAppend,
        const <String, dynamic>{'t': 'Write Report'},
      );
      final bytes = request.toBytes();
      expect(ascii.decode(bytes), '{"cmd":202,"data":{"t":"Write Report"}}');
      expect(RpcRequest.fromBytes(bytes), request);

      final response = RpcResponse.fromJsonString(
        '{"cmd":202,"code":0,"data":{"i":2,"id":15,"len":3}}',
      );
      expect(response.cmd, CmdId.todoAppend.code);
      expect(response.isOk, isTrue);
      expect(response.errCode, ErrCode.ok);

      final appendResult = TodoAppendResult.fromData(response.data);
      expect(appendResult.index, 2);
      expect(appendResult.id, 15);
      expect(appendResult.length, 3);
    });

    test('rejects non-ASCII characters (Chinese, Emoji, control bytes)', () {
      for (final badTitle in <String>[
        '中文待辦',
        'Study 😀',
        'Line1\nLine2',
        'Tab\tChar',
        'Del\x7FChar',
      ]) {
        expect(
          () => AsciiValidator.validateTodoTitle(badTitle),
          throwsA(isA<PacketValidationException>()),
        );
        expect(
          () => RpcRequest.command(
            CmdId.todoAppend,
            <String, dynamic>{'t': badTitle},
          ).toBytes(),
          throwsA(isA<PacketValidationException>()),
        );
      }
    });

    test('enforces strictly < 120 byte packet size limit', () {
      // {"cmd":202,"data":{"t":"..."}} -> overhead is 27 chars.
      // 92 chars payload => 27 + 92 = 119 bytes (allowed).
      final maxPassingPayload = 'A' * 92;
      final okBytes = RpcRequest.command(
        CmdId.todoAppend,
        <String, dynamic>{'t': maxPassingPayload},
      ).toBytes();
      expect(okBytes.length, 119);

      // 93 chars payload => 27 + 93 = 120 bytes (must reject).
      final tooLongPayload = 'A' * 93;
      expect(
        () => RpcRequest.command(
          CmdId.todoAppend,
          <String, dynamic>{'t': tooLongPayload},
        ).toBytes(),
        throwsA(isA<PacketValidationException>()),
      );
    });

    test('trims optional trailing terminators and rejects malformed JSON', () {
      final padded = <int>[
        ...ascii.encode('{"cmd":10,"code":0,"data":{}}'),
        0x0D,
        0x0A,
        0x00,
      ];
      final response = RpcResponse.fromBytes(padded);
      expect(response.cmd, 10);
      expect(response.code, 0);

      for (final raw in <String>[
        '{bad json',
        '[]',
        '{"code":0,"data":{}}',
        '{"cmd":10,"data":{}}',
        '{"cmd":10,"code":0}',
        '{"cmd":10,"code":0,"data":[]}',
      ]) {
        expect(
          () => RpcResponse.fromJsonString(raw),
          throwsA(isA<PacketValidationException>()),
        );
      }
    });
  });

  group('Protocol Models', () {
    test('parses EVT_STATUS payload from spec example', () {
      final response = RpcResponse.fromJsonString(
        '{"cmd":1,"code":0,"data":{"state":1,"rem":1485,"tot":1500,"away":false,"todo_id":12,"unsynced":2}}',
      );
      final status = DeviceStatus.fromData(response.data);
      expect(status.state, PomodoroState.focusRunning);
      expect(status.remainingSeconds, 1485);
      expect(status.totalSeconds, 1500);
      expect(status.elapsedSeconds, 15);
      expect(status.isAway, isFalse);
      expect(status.todoId, 12);
      expect(status.hasBoundTodo, isTrue);
      expect(status.unsyncedCount, 2);
      expect(status.toData()['state'], 1);
    });

    test('validates DeviceConfig ranges', () {
      const DeviceConfig.defaults().validate();

      expect(
        () => const DeviceConfig.defaults().copyWith(focusMinutes: 0).validate(),
        throwsA(isA<PacketValidationException>()),
      );
      expect(
        () => const DeviceConfig.defaults().copyWith(focusMinutes: 121).validate(),
        throwsA(isA<PacketValidationException>()),
      );
      expect(
        () => const DeviceConfig.defaults().copyWith(breakMinutes: 61).validate(),
        throwsA(isA<PacketValidationException>()),
      );
    });

    test('parses TodoItem and resolves SessionLog start == 0 estimation', () {
      final todo = TodoItem.fromData(
        const <String, dynamic>{
          'i': 0,
          'id': 12,
          't': 'Embedded Final',
          'd': false,
        },
      );
      expect(todo.id, 12);
      expect(todo.done, isFalse);

      final unsyncedClockLog = SessionLog.fromPeekData(
        const <String, dynamic>{
          'log_id': 104,
          'start': 0,
          'dur': 1500,
          'type': 0,
          'res': 0,
          'todo_id': 12,
        },
      ).resolveReceivedTimestamp(1763970900);
      expect(unsyncedClockLog.isEstimatedTime, isTrue);
      expect(unsyncedClockLog.startEpoch, 1763969400);

      final syncedClockLog = SessionLog.fromPeekData(
        const <String, dynamic>{
          'log_id': 105,
          'start': 1763960000,
          'dur': 1500,
          'type': 0,
          'res': 1,
          'todo_id': -1,
        },
      ).resolveReceivedTimestamp(1763970900);
      expect(syncedClockLog.isEstimatedTime, isFalse);
      expect(syncedClockLog.startEpoch, 1763960000);
      expect(syncedClockLog.result, SessionResult.aborted);
    });
  });
}
