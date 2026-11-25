import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/core/protocol/protocol_constants.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/data/local/app_database.dart';
import 'package:pomodoro/data/local/preferences_store.dart';
import 'package:pomodoro/state/ble_providers.dart';

void main() {
  group('Commit 9 Stop Confirmation & PacketInspectorScreen', () {
    testWidgets(
      'skips dialog when elapsed < 60s and confirms + syncs ABORTED log when elapsed >= 60s',
      (WidgetTester tester) async {
        final logger = AppLogger(printer: (_) {});
        final mockRepo = MockBleRepository(
          nvsStore: InMemoryMockNvsStore(),
          logger: logger,
        );
        final database = InMemoryAppDatabase();

        addTearDown(() async {
          await database.close();
          mockRepo.dispose();
          logger.dispose();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mockBleRepositoryProvider.overrideWith((ref) {
                ref.onDispose(mockRepo.dispose);
                return mockRepo;
              }),
              appDatabaseProvider.overrideWithValue(database),
              preferencesStoreProvider.overrideWithValue(
                InMemoryPreferencesStore(),
              ),
              appLoggerProvider.overrideWithValue(logger),
            ],
            child: const PomodoroApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Start focus and stop immediately (< 60s) -> no confirmation dialog.
        await tester.tap(find.byKey(const Key('btn_start_focus')));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('btn_stop')), findsOneWidget);

        await tester.tap(find.byKey(const Key('btn_stop')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('dialog_stop_confirm')), findsNothing);
        expect(find.byKey(const Key('btn_start_focus')), findsOneWidget);
        expect(await database.fetchAllSessionLogs(), isEmpty);

        // Start focus again, fast-forward elapsed to 65s (>= 60s), tap Stop -> confirm dialog.
        await tester.tap(find.byKey(const Key('btn_start_focus')));
        await tester.pumpAndSettle();

        mockRepo.fastForwardElapsed(65);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('btn_stop')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('dialog_stop_confirm')), findsOneWidget);
        expect(
          find.text('是否確認中止（將記錄為未完成專注）'),
          findsOneWidget,
        );

        // Cancel stops closing dialog without aborting focus.
        await tester.tap(find.byKey(const Key('btn_cancel_stop_focus')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('dialog_stop_confirm')), findsNothing);
        expect(find.byKey(const Key('btn_stop')), findsOneWidget);

        // Tap Stop again and confirm abort -> logs ABORTED entry and syncs to SQLite.
        await tester.tap(find.byKey(const Key('btn_stop')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_confirm_stop_focus')));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('btn_start_focus')), findsOneWidget);
        final logs = await database.fetchAllSessionLogs();
        expect(logs, hasLength(1));
        expect(logs.first.log.result, SessionResult.aborted);
        expect(logs.first.log.durationSeconds, greaterThanOrEqualTo(65));

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'PacketInspectorScreen renders live entries, filters by category, copies, and clears logs',
      (WidgetTester tester) async {
        final logger = AppLogger(printer: (_) {});
        final mockRepo = MockBleRepository(
          nvsStore: InMemoryMockNvsStore(),
          logger: logger,
        );
        final database = InMemoryAppDatabase();
        String? copiedClipboardText;

        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall methodCall) async {
            if (methodCall.method == 'Clipboard.setData') {
              final args = methodCall.arguments as Map<dynamic, dynamic>?;
              copiedClipboardText = args?['text'] as String?;
            }
            return null;
          },
        );

        addTearDown(() async {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
          await database.close();
          mockRepo.dispose();
          logger.dispose();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mockBleRepositoryProvider.overrideWith((ref) {
                ref.onDispose(mockRepo.dispose);
                return mockRepo;
              }),
              appDatabaseProvider.overrideWithValue(database),
              preferencesStoreProvider.overrideWithValue(
                InMemoryPreferencesStore(),
              ),
              appLoggerProvider.overrideWithValue(logger),
            ],
            child: const PomodoroApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Ensure sync and guard categories are also represented in logger.
        logger.sync('Handshake verified for test');
        logger.guard('FocusGuard test log');

        await tester.tap(find.byKey(const Key('nav_settings')));
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(
          find.byKey(const Key('btn_open_packet_inspector')),
          200,
        );
        await tester.tap(find.byKey(const Key('btn_open_packet_inspector')));
        await tester.pumpAndSettle();

        expect(find.text('BLE 封包即時監看器'), findsOneWidget);
        expect(find.text('[BLE-TX]'), findsWidgets);
        expect(find.text('[BLE-RX]'), findsWidgets);
        expect(find.text('Handshake verified for test'), findsOneWidget);

        // Filter strictly by [BLE-TX].
        await tester.tap(find.byKey(const Key('chip_log_filter_bleTx')));
        await tester.pumpAndSettle();
        expect(find.text('[BLE-TX]'), findsWidgets);
        expect(find.text('Handshake verified for test'), findsNothing);

        // Toggle ascending/descending order and copy filtered TX logs.
        await tester.tap(find.byKey(const Key('btn_toggle_log_order')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_copy_logs')));
        await tester.pumpAndSettle();

        expect(copiedClipboardText, isNotNull);
        expect(copiedClipboardText, contains('[BLE-TX]'));
        expect(copiedClipboardText, isNot(contains('[SYNC]')));

        // Reset filter to All, then clear buffer.
        await tester.tap(find.byKey(const Key('chip_log_filter_all')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_clear_logs')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('txt_logs_empty')), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
