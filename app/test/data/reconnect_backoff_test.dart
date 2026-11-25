import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/data/ble/reconnect_backoff.dart';

void main() {
  group('ReconnectBackoffPolicy', () {
    test('waits 3s for attempts 1..5 and switches to 10s from attempt 6', () {
      const policy = ReconnectBackoffPolicy();

      for (var attempt = 1; attempt <= 5; attempt++) {
        expect(
          policy.delayForAttempt(attempt),
          const Duration(seconds: 3),
          reason: 'attempt=$attempt should use 3s fast delay',
        );
      }

      for (var attempt = 6; attempt <= 15; attempt++) {
        expect(
          policy.delayForAttempt(attempt),
          const Duration(seconds: 10),
          reason: 'attempt=$attempt should use 10s slow delay',
        );
      }
    });
  });
}
