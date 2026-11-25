import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/app.dart';

void main() {
  testWidgets('renders 4-tab shell and switches between tabs cleanly',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PomodoroApp()));

    expect(find.byKey(const Key('screen_timer')), findsOneWidget);
    expect(find.text('專注計時控制'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_todos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen_todos')), findsOneWidget);
    expect(find.text('待辦事項清單'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_stats')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen_stats')), findsOneWidget);
    expect(find.text('專注歷史與報表'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screen_settings')), findsOneWidget);
    expect(find.text('裝置參數與專注防護'), findsOneWidget);
  });
}
