import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/data/ble/ble_client_adapter.dart';
import 'package:pomodoro/data/local/preferences_store.dart';
import 'package:pomodoro/state/ble_providers.dart';
import 'package:pomodoro/state/debug_mode_controller.dart';

class _NoopBleClientAdapter implements BleClientAdapter {
  final StreamController<bool> _adapterOnController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _isScanningController =
      StreamController<bool>.broadcast();
  final StreamController<List<BleRawScanEntry>> _scanEntriesController =
      StreamController<List<BleRawScanEntry>>.broadcast();

  @override
  bool get isAdapterOnNow => true;

  @override
  Stream<bool> get adapterOnStream => _adapterOnController.stream;

  @override
  Stream<bool> get isScanningStream => _isScanningController.stream;

  @override
  Stream<List<BleRawScanEntry>> get scanEntriesStream =>
      _scanEntriesController.stream;

  @override
  Future<bool> refreshAdapterOn() async => true;

  @override
  Future<BlePermissionResult> ensurePermissions() async =>
      BlePermissionResult.granted;

  @override
  Future<bool> openSystemAppSettings() async => true;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<BleConnectedGattSession> connectAndSetupGatt(
    String deviceId, {
    Duration timeout = const Duration(seconds: 12),
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> disconnectDevice(String deviceId) async {}

  @override
  void dispose() {
    _adapterOnController.close();
    _isScanningController.close();
    _scanEntriesController.close();
  }
}

void main() {
  group('Commit 10 Debug Mode 5-Tap Gate', () {
    testWidgets('defaults to clean Normal Mode hiding all Mock and Debug UI', (
      WidgetTester tester,
    ) async {
      final prefs = InMemoryPreferencesStore();
      final adapter = _NoopBleClientAdapter();
      addTearDown(adapter.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesStoreProvider.overrideWithValue(prefs),
            bleClientAdapterProvider.overrideWithValue(adapter),
          ],
          child: const PomodoroApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Normal mode displays consumer BLE label without 'Mock' or 'BLE' debug prefix.
      expect(prefs.isDebugMode, isFalse);
      expect(prefs.isMockBleMode, isFalse);
      expect(find.text('未連線'), findsOneWidget);
      expect(find.textContaining('Mock'), findsNothing);
      expect(
        find.text('尚未配對 SmartPomodoro，請點擊「掃描裝置」連線'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('btn_toggle_mock_panel')), findsNothing);

      // Settings tab hides debug cards and Mock/Real mode switcher chips.
      await tester.tap(find.byKey(const Key('nav_settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card_ble_device_normal')), findsOneWidget);
      expect(find.byKey(const Key('card_ble_mode_settings')), findsNothing);
      expect(find.byKey(const Key('chip_ble_mode_mock')), findsNothing);
      expect(find.byKey(const Key('card_packet_inspector_entry')), findsNothing);
      expect(find.byKey(const Key('btn_open_packet_inspector')), findsNothing);
      expect(find.byKey(const Key('btn_toggle_diagnostics')), findsNothing);
      expect(find.byKey(const Key('card_focus_guard_entry')), findsOneWidget);

      // Device scan sheet in Normal Mode hides Mock toggle chips and fallback button.
      await tester.tap(find.byKey(const Key('btn_open_scan_sheet')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet_device_scan')), findsOneWidget);
      expect(find.byKey(const Key('btn_sheet_switch_mock')), findsNothing);
      expect(find.byKey(const Key('btn_empty_fallback_mock')), findsNothing);
      expect(
        find.text('找不到附近的 SmartPomodoro 裝置，請確認裝置已開機並處於廣播狀態'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('btn_close_scan_sheet')));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '5-tap settings trigger resets on tab switch or >3s timeout, and toggles Debug + Mock cleanly',
      (WidgetTester tester) async {
        final prefs = InMemoryPreferencesStore();
        final adapter = _NoopBleClientAdapter();
        addTearDown(adapter.dispose);
        var now = DateTime(2026, 1, 1, 12, 0, 0);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesStoreProvider.overrideWithValue(prefs),
              bleClientAdapterProvider.overrideWithValue(adapter),
              debugTapClockProvider.overrideWithValue(() => now),
            ],
            child: const PomodoroApp(),
          ),
        );
        await tester.pumpAndSettle();

        Future<void> tapSettings(Duration step) async {
          now = now.add(step);
          await tester.tap(find.byKey(const Key('nav_settings')));
          await tester.pumpAndSettle();
        }

        // 3 taps -> sheet does not open.
        await tapSettings(const Duration(milliseconds: 200));
        await tapSettings(const Duration(milliseconds: 200));
        await tapSettings(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('sheet_debug_mode')), findsNothing);

        // Switching to Timer tab resets counter -> 4 more settings taps still doesn't open.
        await tester.tap(find.byKey(const Key('nav_timer')));
        await tester.pumpAndSettle();
        for (var i = 0; i < 4; i++) {
          await tapSettings(const Duration(milliseconds: 200));
        }
        expect(find.byKey(const Key('sheet_debug_mode')), findsNothing);

        // Advancing clock > 3s resets counter -> 4 taps still doesn't open.
        now = now.add(const Duration(seconds: 4));
        for (var i = 0; i < 4; i++) {
          await tapSettings(const Duration(milliseconds: 200));
        }
        expect(find.byKey(const Key('sheet_debug_mode')), findsNothing);

        // 5th consecutive tap within 3s opens DebugModeSheet.
        await tapSettings(const Duration(milliseconds: 200));
        expect(find.byKey(const Key('sheet_debug_mode')), findsOneWidget);

        // Enable Debug Mode + Mock virtual firmware.
        await tester.tap(find.byKey(const Key('switch_debug_mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('switch_debug_mock_ble')));
        await tester.pumpAndSettle();
        expect(prefs.isDebugMode, isTrue);
        expect(prefs.isMockBleMode, isTrue);

        await tester.tap(find.byKey(const Key('btn_close_debug_sheet')));
        await tester.pumpAndSettle();

        // Debug/Mock UI is now revealed in AppBar, Settings, and Timer tabs.
        expect(find.text('Mock 已連線'), findsOneWidget);
        expect(find.byKey(const Key('card_ble_mode_settings')), findsOneWidget);
        expect(find.byKey(const Key('chip_ble_mode_mock')), findsOneWidget);
        expect(
          find.byKey(const Key('card_packet_inspector_entry')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('btn_toggle_diagnostics')), findsOneWidget);

        await tester.tap(find.byKey(const Key('nav_timer')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('btn_toggle_mock_panel')), findsOneWidget);

        // 5 consecutive taps on Settings again -> disable Debug Mode -> auto-reverts to Real BLE.
        for (var i = 0; i < 5; i++) {
          await tapSettings(const Duration(milliseconds: 200));
        }
        expect(find.byKey(const Key('sheet_debug_mode')), findsOneWidget);

        await tester.tap(find.byKey(const Key('switch_debug_mode')));
        await tester.pumpAndSettle();
        expect(prefs.isDebugMode, isFalse);
        expect(prefs.isMockBleMode, isFalse);

        await tester.tap(find.byKey(const Key('btn_close_debug_sheet')));
        await tester.pumpAndSettle();

        expect(find.text('未連線'), findsOneWidget);
        expect(find.byKey(const Key('card_ble_device_normal')), findsOneWidget);
        expect(find.byKey(const Key('card_ble_mode_settings')), findsNothing);
        expect(
          find.byKey(const Key('card_packet_inspector_entry')),
          findsNothing,
        );

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
