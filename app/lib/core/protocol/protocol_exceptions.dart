import 'protocol_constants.dart';

/// Base exception for BLE protocol encoding, transport, and RPC errors.
sealed class PomodoroProtocolException implements Exception {
  const PomodoroProtocolException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when an outgoing or incoming packet violates ASCII, length, or JSON
/// envelope constraints.
class PacketValidationException extends PomodoroProtocolException {
  const PacketValidationException(super.message);
}

/// Thrown when the ESP32 responds to an RPC command with a non-zero `code`.
class RpcErrorException extends PomodoroProtocolException {
  RpcErrorException({
    required this.cmd,
    required this.code,
    ErrCode? errCode,
    Map<String, dynamic> data = const <String, dynamic>{},
  })  : errCode = errCode ?? ErrCode.tryFromCode(code),
        data = Map<String, dynamic>.unmodifiable(data),
        super(ErrCode.describe(code));

  final int cmd;
  final int code;
  final ErrCode? errCode;
  final Map<String, dynamic> data;

  String get userMessage => errCode?.message ?? ErrCode.describe(code);
}

/// Thrown when an in-flight RPC command does not receive a matching response
/// within the configured timeout window.
class BleTimeoutException extends PomodoroProtocolException {
  BleTimeoutException({
    required this.cmd,
    required this.timeout,
  }) : super('指令 $cmd 等待回應逾時 (${timeout.inSeconds} 秒)');

  final int cmd;
  final Duration timeout;
}

/// Thrown when an operation cannot complete because the BLE link disconnected.
class BleDisconnectedException extends PomodoroProtocolException {
  const BleDisconnectedException([super.message = '裝置已斷線']);
}

/// Thrown when BLE adapter, permissions, scan, or GATT service discovery fails.
class BleConnectionException extends PomodoroProtocolException {
  const BleConnectionException(super.message);
}
