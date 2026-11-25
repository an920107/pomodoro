import 'dart:async';

import 'package:flutter/foundation.dart';

/// Structured log categories aligned with ADB `logcat -s flutter:V` filtering
/// and the in-app Packet Inspector.
enum LogCategory {
  bleTx('[BLE-TX]'),
  bleRx('[BLE-RX]'),
  sync('[SYNC]'),
  guard('[GUARD]'),
  app('[APP]');

  const LogCategory(this.tag);

  final String tag;
}

/// Immutable single log entry stored inside [AppLogger]'s ring buffer.
class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.category,
    required this.message,
  });

  final DateTime timestamp;
  final LogCategory category;
  final String message;

  String get tag => category.tag;

  String format() {
    final hh = timestamp.hour.toString().padLeft(2, '0');
    final mm = timestamp.minute.toString().padLeft(2, '0');
    final ss = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$ms $tag $message';
  }
}

/// Ring-buffer logger that prints formatted lines to Flutter console (`logcat`)
/// and broadcasts updates for UI log inspectors.
class AppLogger {
  AppLogger({
    this.maxEntries = 300,
    void Function(String line)? printer,
  })  : assert(maxEntries > 0),
        _printer = printer ?? _defaultPrinter;

  static final AppLogger instance = AppLogger();

  final int maxEntries;
  final void Function(String line) _printer;
  final List<LogEntry> _entries = <LogEntry>[];
  final StreamController<List<LogEntry>> _controller =
      StreamController<List<LogEntry>>.broadcast();

  static void _defaultPrinter(String line) {
    debugPrint(line);
  }

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  Stream<List<LogEntry>> get stream => _controller.stream;

  void log(LogCategory category, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      category: category,
      message: message,
    );
    if (_entries.length >= maxEntries) {
      _entries.removeAt(0);
    }
    _entries.add(entry);
    _printer('${entry.tag} ${entry.message}');
    if (!_controller.isClosed) {
      _controller.add(entries);
    }
  }

  void bleTx(String message) => log(LogCategory.bleTx, message);

  void bleRx(String message) => log(LogCategory.bleRx, message);

  void sync(String message) => log(LogCategory.sync, message);

  void guard(String message) => log(LogCategory.guard, message);

  void app(String message) => log(LogCategory.app, message);

  void clear() {
    _entries.clear();
    if (!_controller.isClosed) {
      _controller.add(const <LogEntry>[]);
    }
  }

  void dispose() {
    _controller.close();
  }
}
