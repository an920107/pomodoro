import 'dart:convert';
import 'dart:typed_data';

import 'protocol_constants.dart';
import 'protocol_exceptions.dart';

/// Validates printable ASCII (`0x20..0x7E`) and `< 120` byte packet limits
/// required by `docs/spec.md` v1.2.
abstract final class AsciiValidator {
  static bool isPrintableAscii(String input) {
    for (final unit in input.codeUnits) {
      if (unit < BleProtocolConstants.asciiMin ||
          unit > BleProtocolConstants.asciiMax) {
        return false;
      }
    }
    return true;
  }

  static bool isValidTodoTitle(String title) {
    return title.length >= BleProtocolConstants.minTodoTitleLength &&
        title.length <= BleProtocolConstants.maxTodoTitleLength &&
        isPrintableAscii(title);
  }

  static void validateTodoTitle(String title) {
    if (title.length < BleProtocolConstants.minTodoTitleLength ||
        title.length > BleProtocolConstants.maxTodoTitleLength) {
      throw const PacketValidationException(
        'Todo title length must be 1..24 characters',
      );
    }
    if (!isPrintableAscii(title)) {
      throw const PacketValidationException(
        'Todo title must contain only printable ASCII (0x20..0x7E)',
      );
    }
  }

  static void validateJsonValueStrings(Object? value) {
    if (value is String) {
      if (!isPrintableAscii(value)) {
        throw const PacketValidationException(
          'JSON string values must contain only printable ASCII (0x20..0x7E)',
        );
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        validateJsonValueStrings(entry.key);
        validateJsonValueStrings(entry.value);
      }
      return;
    }
    if (value is Iterable) {
      for (final item in value) {
        validateJsonValueStrings(item);
      }
    }
  }

  static void validatePacketBytes(List<int> bytes) {
    if (bytes.isEmpty) {
      throw const PacketValidationException('Packet must not be empty');
    }
    if (bytes.length >= BleProtocolConstants.maxPacketBytes) {
      throw PacketValidationException(
        'Packet length ${bytes.length} exceeds limit (< ${BleProtocolConstants.maxPacketBytes} bytes)',
      );
    }
    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b < BleProtocolConstants.asciiMin ||
          b > BleProtocolConstants.asciiMax) {
        throw PacketValidationException(
          'Non-printable ASCII byte 0x${b.toRadixString(16)} at index $i',
        );
      }
    }
  }

  static List<int> trimTrailingTerminators(List<int> bytes) {
    var end = bytes.length;
    while (end > 0) {
      final b = bytes[end - 1];
      if (b == 0x00 || b == 0x0A || b == 0x0D) {
        end--;
      } else {
        break;
      }
    }
    return end == bytes.length ? bytes : bytes.sublist(0, end);
  }
}

/// Outgoing App -> ESP32 request envelope: `{"cmd": <int>, "data": {...}}`.
class RpcRequest {
  RpcRequest({
    required this.cmd,
    Map<String, dynamic> data = const <String, dynamic>{},
  }) : data = Map<String, dynamic>.unmodifiable(data);

  factory RpcRequest.command(
    CmdId cmd, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) {
    return RpcRequest(cmd: cmd.code, data: data);
  }

  factory RpcRequest.fromBytes(List<int> bytes) {
    final trimmed = AsciiValidator.trimTrailingTerminators(bytes);
    AsciiValidator.validatePacketBytes(trimmed);
    return RpcRequest.fromJsonString(ascii.decode(trimmed));
  }

  factory RpcRequest.fromJsonString(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw PacketValidationException('Invalid request JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const PacketValidationException('Request JSON must be an object');
    }
    final cmd = decoded['cmd'];
    final data = decoded['data'];
    if (cmd is! int) {
      throw const PacketValidationException('Request missing integer "cmd"');
    }
    if (data is! Map) {
      throw const PacketValidationException('Request missing object "data"');
    }
    return RpcRequest(
      cmd: cmd,
      data: Map<String, dynamic>.from(data),
    );
  }

  final int cmd;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cmd': cmd,
        'data': data,
      };

  String toJsonString() => jsonEncode(toJson());

  Uint8List toBytes() {
    AsciiValidator.validateJsonValueStrings(data);
    final encoded = utf8.encode(toJsonString());
    AsciiValidator.validatePacketBytes(encoded);
    return Uint8List.fromList(encoded);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RpcRequest &&
        other.cmd == cmd &&
        toJsonString() == other.toJsonString();
  }

  @override
  int get hashCode => Object.hash(cmd, toJsonString());

  @override
  String toString() => 'RpcRequest(${toJsonString()})';
}

/// Incoming ESP32 -> App response / notification envelope:
/// `{"cmd": <int>, "code": <int>, "data": {...}}`.
class RpcResponse {
  RpcResponse({
    required this.cmd,
    required this.code,
    Map<String, dynamic> data = const <String, dynamic>{},
  }) : data = Map<String, dynamic>.unmodifiable(data);

  factory RpcResponse.fromBytes(List<int> bytes) {
    final trimmed = AsciiValidator.trimTrailingTerminators(bytes);
    AsciiValidator.validatePacketBytes(trimmed);
    return RpcResponse.fromJsonString(ascii.decode(trimmed));
  }

  factory RpcResponse.fromJsonString(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw PacketValidationException('Invalid response JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const PacketValidationException('Response JSON must be an object');
    }
    final cmd = decoded['cmd'];
    final code = decoded['code'];
    final data = decoded['data'];
    if (cmd is! int) {
      throw const PacketValidationException('Response missing integer "cmd"');
    }
    if (code is! int) {
      throw const PacketValidationException('Response missing integer "code"');
    }
    if (data is! Map) {
      throw const PacketValidationException('Response missing object "data"');
    }
    return RpcResponse(
      cmd: cmd,
      code: code,
      data: Map<String, dynamic>.from(data),
    );
  }

  final int cmd;
  final int code;
  final Map<String, dynamic> data;

  bool get isOk => code == ErrCode.ok.code;

  ErrCode? get errCode => ErrCode.tryFromCode(code);

  RpcResponse ensureOk() {
    if (!isOk) {
      throw RpcErrorException(
        cmd: cmd,
        code: code,
        errCode: errCode,
        data: data,
      );
    }
    return this;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cmd': cmd,
        'code': code,
        'data': data,
      };

  String toJsonString() => jsonEncode(toJson());

  Uint8List toBytes() {
    AsciiValidator.validateJsonValueStrings(data);
    final encoded = utf8.encode(toJsonString());
    AsciiValidator.validatePacketBytes(encoded);
    return Uint8List.fromList(encoded);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RpcResponse &&
        other.cmd == cmd &&
        other.code == code &&
        toJsonString() == other.toJsonString();
  }

  @override
  int get hashCode => Object.hash(cmd, code, toJsonString());

  @override
  String toString() => 'RpcResponse(${toJsonString()})';
}
