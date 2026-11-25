import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/logging/app_logger.dart';
import 'ble_providers.dart';

/// Clock abstraction for testing the 5-tap settings trigger window deterministically.
final debugTapClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Controls developer Debug Mode visibility and detects 5 consecutive taps on
/// the bottom navigation Settings tab within [tapWindow].
class DebugModeController extends Notifier<bool> {
  static const int requiredTaps = 5;
  static const Duration tapWindow = Duration(seconds: 3);

  int _consecutiveSettingsTaps = 0;
  DateTime? _lastTapAt;

  @override
  bool build() {
    _consecutiveSettingsTaps = 0;
    _lastTapAt = null;
    return ref.watch(preferencesStoreProvider).isDebugMode;
  }

  /// Registers a bottom navigation tap and returns `true` when 5 consecutive
  /// taps land on the Settings tab within [tapWindow].
  bool registerTabTap({required bool isSettingsTab}) {
    if (!isSettingsTab) {
      _consecutiveSettingsTaps = 0;
      _lastTapAt = null;
      return false;
    }

    final now = ref.read(debugTapClockProvider)();
    if (_lastTapAt == null || now.difference(_lastTapAt!) > tapWindow) {
      _consecutiveSettingsTaps = 1;
    } else {
      _consecutiveSettingsTaps++;
    }
    _lastTapAt = now;

    if (_consecutiveSettingsTaps >= requiredTaps) {
      _consecutiveSettingsTaps = 0;
      _lastTapAt = null;
      AppLogger.instance.app('5-tap settings trigger -> opening DebugModeSheet');
      return true;
    }
    return false;
  }

  /// Enables or disables Debug Mode. Turning Debug Mode off clears the
  /// Mock flag as well so [BleModeNotifier] reverts cleanly to Real BLE.
  Future<void> setDebugMode(bool enabled) async {
    if (state == enabled) return;
    final prefs = ref.read(preferencesStoreProvider);
    final persistFutures = <Future<void>>[prefs.setDebugMode(enabled)];
    if (!enabled) {
      persistFutures.add(prefs.setMockBleMode(false));
    }
    state = enabled;
    AppLogger.instance.app('Debug mode -> ${enabled ? 'ENABLED' : 'DISABLED'}');
    await Future.wait<void>(persistFutures);
  }
}

final debugModeProvider = NotifierProvider<DebugModeController, bool>(
  DebugModeController.new,
);
