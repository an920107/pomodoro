import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/data/local/app_database.dart';
import 'package:pomodoro/state/ble_providers.dart';

void main() {
  group('StatsScreen end-to-end handshake & history persistence', () {
    late AppLogger logger;
    late MockBleRepository mockRepo;
    late InMemoryAppDatabase database;

    setUp(() {
      logger = AppLogger(printer: (_) {});
      mockRepo = MockBleRepository(
        nvsStore: InMemoryMockNvsStore(),
        logger: logger,
      );
      database = InMemoryAppDatabase();
    });

    tearDown(() async {
      await database.close();
      mockRepo.dispose();
      logger.dispose();
    });

    testWidgets(
        'preserves deleted To-Do title and displays estimated timestamp badge',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mockBleRepositoryProvider.overrideWith((ref) {
              ref.onDispose(mockRepo.dispose);
              return mockRepo;
            }),
            appDatabaseProvider.overrideWithValue(database),
          ],
          child: const PomodoroApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Add To-Do 'WritePaper' on Todos tab.
      await tester.tap(find.byKey(const Key('nav_todos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_add_todo')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_todo_title')),
        'WritePaper',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_save_todo_dialog')));
      await tester.pumpAndSettle();
      expect(find.text('WritePaper'), findsOneWidget);

      // Select 'WritePaper' on Timer tab, complete focus session immediately.
      await tester.tap(find.byKey(const Key('nav_timer')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('selector_bound_todo')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WritePaper').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_start_focus')));
      await tester.pumpAndSettle();

      mockRepo.fastForwardRemaining(0);
      await tester.pumpAndSettle();
      // Give reactive sync microtask/futures a moment to drain log #1.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      // Delete 'WritePaper' from Todos tab -> todo_id 3 removed from ESP32.
      await tester.tap(find.byKey(const Key('nav_todos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('todo_delete_3')));
      await tester.pumpAndSettle();
      expect(find.text('WritePaper'), findsNothing);

      // Disconnect, inject unclocked log (start == 0), then reconnect.
      mockRepo.simulateDisconnect();
      mockRepo.injectOfflineSessionLog(
        startEpoch: 0,
        durationSeconds: 1500,
      );
      await tester.pumpAndSettle();
      await mockRepo.simulateReconnect();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // Switch to Stats tab and inspect aggregated UI.
      await tester.tap(find.byKey(const Key('nav_stats')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chart_weekly_focus')), findsOneWidget);
      expect(find.text('2 顆'), findsOneWidget);
      expect(find.text('50 分鐘'), findsOneWidget);
      expect(find.text('WritePaper'), findsWidgets);

      await tester.scrollUntilVisible(
        find.byKey(const Key('badge_estimated_2')),
        200,
      );
      expect(find.byKey(const Key('badge_estimated_2')), findsOneWidget);
      expect(find.text('估算時間'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
