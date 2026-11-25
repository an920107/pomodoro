/// Stepped reconnect backoff policy for [RealBleRepository] (`plan.md` §3.2):
/// attempts 1..5 wait [fastDelay] (3s); attempt 6+ waits [slowDelay] (10s).
class ReconnectBackoffPolicy {
  const ReconnectBackoffPolicy({
    this.fastDelay = const Duration(seconds: 3),
    this.slowDelay = const Duration(seconds: 10),
    this.fastAttemptLimit = 5,
  });

  final Duration fastDelay;
  final Duration slowDelay;
  final int fastAttemptLimit;

  /// Returns the delay to wait before starting reconnect [attempt] (1-based).
  Duration delayForAttempt(int attempt) {
    if (attempt <= fastAttemptLimit) {
      return fastDelay;
    }
    return slowDelay;
  }
}
