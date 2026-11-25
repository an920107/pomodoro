import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/core/logging/app_logger.dart';

void main() {
  group('AppLogger', () {
    test('formats and prints expected tags for all categories', () {
      final printed = <String>[];
      final logger = AppLogger(maxEntries: 10, printer: printed.add);
      addTearDown(logger.dispose);

      logger.bleTx('{"cmd":11,"data":{"todo_id":-1}}');
      logger.bleRx('{"cmd":1,"code":0,"data":{}}');
      logger.sync('Handshake completed');
      logger.guard('DND enabled');
      logger.app('Shell ready');

      expect(printed, <String>[
        '[BLE-TX] {"cmd":11,"data":{"todo_id":-1}}',
        '[BLE-RX] {"cmd":1,"code":0,"data":{}}',
        '[SYNC] Handshake completed',
        '[GUARD] DND enabled',
        '[APP] Shell ready',
      ]);
      expect(logger.entries.length, 5);
      expect(logger.entries.first.format(), contains('[BLE-TX]'));
    });

    test('evicts oldest entry when exceeding maxEntries and broadcasts stream',
        () async {
      final logger = AppLogger(maxEntries: 3, printer: (_) {});
      addTearDown(logger.dispose);

      final snapshots = <int>[];
      final sub = logger.stream.listen((items) {
        snapshots.add(items.length);
      });
      addTearDown(sub.cancel);

      logger.app('one');
      logger.app('two');
      logger.app('three');
      logger.app('four');
      await Future<void>.delayed(Duration.zero);

      expect(logger.entries.map((e) => e.message).toList(), <String>[
        'two',
        'three',
        'four',
      ]);
      expect(snapshots, <int>[1, 2, 3, 3]);

      logger.clear();
      await Future<void>.delayed(Duration.zero);
      expect(logger.entries, isEmpty);
      expect(snapshots.last, 0);
    });
  });
}
