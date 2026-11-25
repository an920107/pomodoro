import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../core/logging/app_logger.dart';
import '../../core/protocol/packet_envelope.dart';
import '../../core/protocol/protocol_constants.dart';
import '../../core/protocol/protocol_exceptions.dart';

typedef BleRpcWriter = Future<void> Function(Uint8List bytes);

class _QueuedRpcEntry {
  _QueuedRpcEntry({
    required this.request,
    required this.bytes,
    required this.completer,
  });

  final RpcRequest request;
  final Uint8List bytes;
  final Completer<RpcResponse> completer;
}

/// Serializes all `RPC (...5601)` requests so strictly one `WRITE` is in
/// flight at a time, matched 1-to-1 against `RPC Notify` by `cmd` with a
/// 3-second timeout (`docs/spec.md` §3.2).
class RpcCommandQueue {
  RpcCommandQueue({
    required this.writer,
    this.timeout = BleProtocolConstants.rpcTimeout,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger.instance;

  final BleRpcWriter writer;
  final Duration timeout;
  final AppLogger _logger;

  final Queue<_QueuedRpcEntry> _pending = Queue<_QueuedRpcEntry>();
  _QueuedRpcEntry? _inFlight;
  Timer? _inFlightTimer;
  bool _isDisposed = false;

  bool get hasInFlight => _inFlight != null;

  int get pendingCount => _pending.length;

  /// Enqueues [request] and returns its matching [RpcResponse].
  /// Validates ASCII and `< 120` byte limits immediately before queueing.
  Future<RpcResponse> enqueue(RpcRequest request) {
    if (_isDisposed) {
      return Future<RpcResponse>.error(const BleDisconnectedException());
    }

    final Uint8List bytes;
    try {
      bytes = request.toBytes();
    } catch (e) {
      return Future<RpcResponse>.error(e);
    }

    final completer = Completer<RpcResponse>();
    final entry = _QueuedRpcEntry(
      request: request,
      bytes: bytes,
      completer: completer,
    );
    _pending.addLast(entry);
    _pumpNext();
    return completer.future;
  }

  /// Convenience wrapper that sends [request] and validates `code == 0`.
  Future<RpcResponse> sendAndEnsureOk(RpcRequest request) async {
    final response = await enqueue(request);
    return response.ensureOk();
  }

  /// Processes raw bytes arriving on the `RPC (...5601)` Notify characteristic.
  void handleNotificationBytes(List<int> bytes) {
    if (_isDisposed) return;
    final RpcResponse response;
    try {
      response = RpcResponse.fromBytes(bytes);
    } on PacketValidationException catch (e) {
      _logger.bleRx('Ignored invalid RPC packet: ${e.message}');
      return;
    }
    handleResponse(response);
  }

  /// Processes an already-decoded [RpcResponse] arriving on `RPC (...5601)`.
  void handleResponse(RpcResponse response) {
    if (_isDisposed) return;
    _logger.bleRx(response.toJsonString());

    final current = _inFlight;
    if (current == null) {
      _logger.bleRx(
        'Ignored unsolicited RPC response for cmd=${response.cmd}',
      );
      return;
    }

    if (response.cmd != current.request.cmd) {
      _logger.bleRx(
        'Ignored mismatched RPC cmd=${response.cmd} (waiting for ${current.request.cmd})',
      );
      return;
    }

    _completeInFlight((completer) {
      completer.complete(response);
    });
  }

  /// Fails the in-flight entry and all queued entries (e.g. on BLE disconnect).
  void failAllPending([Object? error]) {
    final failure = error ?? const BleDisconnectedException();
    _inFlightTimer?.cancel();
    _inFlightTimer = null;

    final current = _inFlight;
    _inFlight = null;
    if (current != null && !current.completer.isCompleted) {
      current.completer.completeError(failure);
    }

    while (_pending.isNotEmpty) {
      final entry = _pending.removeFirst();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(failure);
      }
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    failAllPending(const BleDisconnectedException());
  }

  void _pumpNext() {
    if (_isDisposed || _inFlight != null || _pending.isEmpty) {
      return;
    }

    final next = _pending.removeFirst();
    _inFlight = next;

    _inFlightTimer = Timer(timeout, () {
      if (!identical(_inFlight, next)) return;
      _completeInFlight((completer) {
        completer.completeError(
          BleTimeoutException(cmd: next.request.cmd, timeout: timeout),
        );
      });
    });

    _logger.bleTx(next.request.toJsonString());

    Future<void>.sync(() => writer(next.bytes)).catchError((Object err, StackTrace st) {
      if (!identical(_inFlight, next)) return;
      _completeInFlight((completer) {
        completer.completeError(err, st);
      });
    });
  }

  void _completeInFlight(void Function(Completer<RpcResponse>) complete) {
    final current = _inFlight;
    _inFlight = null;
    _inFlightTimer?.cancel();
    _inFlightTimer = null;

    if (current != null && !current.completer.isCompleted) {
      complete(current.completer);
    }
    _pumpNext();
  }
}
