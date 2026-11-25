import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/state/ble_providers.dart';

void main() {
  group('TimerScreen & PomodoroController', () {
    late AppLogger logger;
    late MockBleRepository mockRepo;

    setUp(() {
      logger = AppLogger(printer: (_) {});
      mockRepo = MockBleRepository(
        nvsStore: InMemoryMockNvsStore(),
        logger: logger,
        tickInterval: const Duration(seconds: 1),
      );
    });

    tearDown(() {
      mockRepo.dispose();
      logger.dispose();
    });

    Widget buildApp() {
      return ProviderScope(
        overrides: [
          mockBleRepositoryProvider.overrideWith((ref) {
            ref.onDispose(mockRepo.dispose);
            return mockRepo;
          }),
        ],
        child: const PomodoroApp(),
      );
    }

    Future<void> flushUi(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    testWidgets('drives IDLE -> FOCUS_RUNNING -> AWAY -> USER_PAUSE -> BREAK',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('screen_timer')), findsOneWidget);
      expect(find.byKey(const Key('btn_start_focus')), findsOneWidget);
      expect(find.byKey(const Key('btn_start_break')), findsOneWidget);
      expect(find.text('25:00'), findsOneWidget);

      // Start focus.
      await tester.tap(find.byKey(const Key('btn_start_focus')));
      await flushUi(tester);
      expect(find.byKey(const Key('btn_pause')), findsOneWidget);
      expect(find.byKey(const Key('btn_stop')), findsOneWidget);

      // Simulate proximity away -> hides resume/pause, shows away alert.
      mockRepo.simulateAway(true);
      await flushUi(tester);
      expect(find.byKey(const Key('banner_away_paused')), findsOneWidget);
      expect(find.byKey(const Key('btn_resume')), findsNothing);
      expect(find.byKey(const Key('btn_pause')), findsNothing);
      expect(find.byKey(const Key('btn_stop')), findsOneWidget);

      // Simulate back in seat -> resumes FOCUS_RUNNING.
      mockRepo.simulateAway(false);
      await flushUi(tester);
      expect(find.byKey(const Key('banner_away_paused')), findsNothing);
      expect(find.byKey(const Key('btn_pause')), findsOneWidget);

      // Manual pause -> shows Resume + Stop.
      await tester.tap(find.byKey(const Key('btn_pause')));
      await flushUi(tester);
      expect(find.byKey(const Key('btn_resume')), findsOneWidget);

      // Stop back to IDLE, then start break -> pause break.
      await tester.tap(find.byKey(const Key('btn_stop')));
      await flushUi(tester);
      expect(find.byKey(const Key('btn_start_break')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_start_break')));
      await flushUi(tester);
      expect(find.text('休息中'), findsOneWidget);
      expect(find.byKey(const Key('btn_pause')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_pause')));
      await flushUi(tester);
      expect(find.text('休息暫停'), findsOneWidget);
      expect(find.byKey(const Key('btn_resume')), findsOneWidget);

      // Clean unmount to cancel timers cleanly.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'locks controls and runs safety-valve countdown when disconnected mid-focus',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_start_focus')));
      await tester.pump();
      await tester.pump();
      mockRepo.fastForwardRemaining(4);
      await tester.pump();

      mockRepo.simulateDisconnect();
      await tester.pump();

      expect(find.byKey(const Key('banner_disconnected')), findsOneWidget);
      expect(
        find.byKey(const Key('txt_safety_valve_countdown')),
        findsOneWidget,
      );

      // Buttons must be disabled while disconnected.
      final pauseButton =
          tester.widget<ButtonStyleButton>(find.byKey(const Key('btn_pause')));
      final stopButton =
          tester.widget<ButtonStyleButton>(find.byKey(const Key('btn_stop')));
      expect(pauseButton.onPressed, isNull);
      expect(stopButton.onPressed, isNull);

      // Advance 4 seconds so safety valve trips while offline.
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const Key('txt_safety_valve_tripped')), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);

      // Reconnect syncs real device status (already completed to IDLE).
      await mockRepo.simulateReconnect();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('banner_disconnected')), findsNothing);
      expect(find.byKey(const Key('btn_start_focus')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
