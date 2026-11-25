import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/app.dart';

void main() {
  testWidgets('renders 4-tab shell and switches between tabs cleanly',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PomodoroApp()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('screen_timer')), findsOneWidget);
    expect(find.byKey(const Key('btn_start_focus')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_todos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen_todos')), findsOneWidget);
    expect(find.byKey(const Key('btn_add_todo')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_stats')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen_stats')), findsOneWidget);
    expect(find.text('專注歷史與報表'), findsOneWidget);
    expect(find.byKey(const Key('chart_weekly_focus')), findsOneWidget);
    expect(find.byKey(const Key('empty_stats_logs')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen_settings')), findsOneWidget);
    expect(find.byKey(const Key('btn_save_config')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('btn_toggle_diagnostics')));
    await tester.tap(find.byKey(const Key('btn_toggle_diagnostics')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('btn_protocol_self_check')));
    await tester.tap(find.byKey(const Key('btn_protocol_self_check')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('txt_protocol_self_check_result')), findsOneWidget);
    expect(find.textContaining('通過：'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('btn_mock_ble_self_check')));
    await tester.tap(find.byKey(const Key('btn_mock_ble_self_check')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('txt_mock_ble_self_check_result')), findsOneWidget);
  });
}
