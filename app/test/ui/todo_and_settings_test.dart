import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/state/ble_providers.dart';
import 'package:pomodoro/ui/todos/todos_screen.dart';

void main() {
  group('TodosScreen & SettingsScreen', () {
    late AppLogger logger;
    late MockBleRepository mockRepo;

    setUp(() {
      logger = AppLogger(printer: (_) {});
      mockRepo = MockBleRepository(
        nvsStore: InMemoryMockNvsStore(),
        logger: logger,
      );
    });

    tearDown(() {
      mockRepo.dispose();
      logger.dispose();
    });

    Widget buildApp() {
      return ProviderScope(
        overrides: [
          mockBleRepositoryProvider.overrideWithValue(mockRepo),
        ],
        child: const PomodoroApp(),
      );
    }

    test('todoAsciiInputFormatter strips non-ASCII and keeps printable ASCII',
        () {
      const oldVal = TextEditingValue.empty;
      final filtered = todoAsciiInputFormatter.formatEditUpdate(
        oldVal,
        const TextEditingValue(text: 'Write 讀書 Report 🚀 #1\n'),
      );
      expect(filtered.text, 'Write  Report  #1');
    });

    testWidgets(
        'To-Do CRUD enforces ASCII, 24-char limit, 10-item cap, and disconnect lock',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav_todos')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('badge_todo_capacity')), findsOneWidget);
      expect(find.text('2 / 10 筆'), findsOneWidget);

      // Open Add dialog, enter mixed non-ASCII + >24 chars.
      await tester.tap(find.byKey(const Key('btn_add_todo')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_todo_title')),
        '中文12345678901234567890123456',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_save_todo_dialog')));
      await tester.pumpAndSettle();

      expect(find.text('3 / 10 筆'), findsOneWidget);
      expect(find.text('123456789012345678901234'), findsOneWidget);

      // Toggle done on first item (id=1).
      await tester.tap(find.byKey(const Key('todo_check_1')));
      await tester.pumpAndSettle();
      expect((await mockRepo.getTodoItem(0)).done, isTrue);

      // Fill up to 10 items via repository and refresh UI -> button disables.
      for (var i = 3; i < 10; i++) {
        await mockRepo.appendTodo('Fill Item $i');
      }
      await tester.tap(find.byKey(const Key('btn_refresh_todos')));
      await tester.pumpAndSettle();
      expect(find.text('10 / 10 筆'), findsOneWidget);

      final addBtn = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('btn_add_todo')),
      );
      expect(addBtn.onPressed, isNull);

      // Delete one item -> 9 / 10, re-enables Add button.
      await tester.tap(find.byKey(const Key('todo_delete_1')));
      await tester.pumpAndSettle();
      expect(find.text('9 / 10 筆'), findsOneWidget);

      // Disconnect locks checkbox/delete/add.
      mockRepo.simulateDisconnect();
      await tester.pumpAndSettle();
      final checkbox = tester.widget<Checkbox>(
        find.byKey(const Key('todo_check_2')),
      );
      expect(checkbox.onChanged, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('SettingsScreen updates device config and TimerScreen reflects 30:00',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav_settings')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('chip_focus_30')));
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('switch_cfg_mute')));
      await tester.tap(find.byKey(const Key('switch_cfg_mute')));
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('btn_save_config')));
      await tester.tap(find.byKey(const Key('btn_save_config')));
      await tester.pumpAndSettle();

      expect(find.text('裝置設定已儲存'), findsOneWidget);
      final savedCfg = await mockRepo.getConfig();
      expect(savedCfg.focusMinutes, 30);
      expect(savedCfg.mute, isTrue);

      // Switch back to Timer tab and confirm dial reads 30:00.
      await tester.tap(find.byKey(const Key('nav_timer')));
      await tester.pumpAndSettle();
      expect(find.text('30:00'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
