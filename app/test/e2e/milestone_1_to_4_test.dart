import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/data/local/app_database.dart';
import 'package:pomodoro/data/local/preferences_store.dart';
import 'package:pomodoro/data/native/focus_guard_service.dart';
import 'package:pomodoro/state/ble_providers.dart';
import 'package:pomodoro/state/focus_guard_controller.dart';
import 'package:pomodoro/state/todo_controller.dart';

class _MilestoneRecordingGuardService implements FocusGuardPlatformService {
  int startCount = 0;
  int stopCount = 0;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<FocusGuardPermissions> checkPermissions() async =>
      const FocusGuardPermissions(
        dndGranted: true,
        usageAccessGranted: true,
        overlayGranted: true,
        notificationsGranted: true,
      );

  @override
  Future<List<InstalledAppInfo>> getInstalledApps() async =>
      const <InstalledAppInfo>[];

  @override
  Future<bool> openPermissionSettings(FocusPermissionKind kind) async => true;

  @override
  Future<void> startOrUpdateGuard({
    required int remainingSeconds,
    required bool dndEnabled,
    required bool appLockEnabled,
    required List<String> blacklistedPackages,
    String? taskTitle,
  }) async {
    startCount++;
  }

  @override
  Future<void> stopGuard() async {
    stopCount++;
  }
}

void main() {
  group('docs/spec.md §8.2 Milestones 1-4 End-to-End Acceptance Suite', () {
    testWidgets(
      'verifies handshake, focus/away closed loop, NVS power-cycle persistence, and offline safety-valve sync',
      (WidgetTester tester) async {
        final logger = AppLogger(printer: (_) {});
        final nvsStore = InMemoryMockNvsStore();
        final mockRepo = MockBleRepository(nvsStore: nvsStore, logger: logger);
        final database = InMemoryAppDatabase();
        final guardService = _MilestoneRecordingGuardService();
        final prefs = InMemoryPreferencesStore(
          isDebugMode: true,
          isMockBleMode: true,
          dndEnabled: true,
          appLockEnabled: true,
          blacklistedPackages: const <String>['com.google.android.calculator'],
        );

        addTearDown(() async {
          await database.close();
          mockRepo.dispose();
          logger.dispose();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mockNvsStoreProvider.overrideWithValue(nvsStore),
              mockBleRepositoryProvider.overrideWith((ref) {
                ref.onDispose(mockRepo.dispose);
                return mockRepo;
              }),
              appDatabaseProvider.overrideWithValue(database),
              preferencesStoreProvider.overrideWithValue(prefs),
              focusGuardServiceProvider.overrideWithValue(guardService),
              appLoggerProvider.overrideWithValue(logger),
            ],
            child: const PomodoroApp(),
          ),
        );
        await tester.pumpAndSettle();

        // ------------------------------------------------------------------
        // Milestone 1: Handshake, MTU=512, Notify, and CMD_SYNC_TIME (10)
        // ------------------------------------------------------------------
        expect(mockRepo.isClockSynced, isTrue);
        expect(
          logger.entries.any(
            (e) =>
                e.category == LogCategory.bleTx &&
                e.message.contains('"cmd":10'),
          ),
          isTrue,
        );
        expect(
          logger.entries.any(
            (e) =>
                e.category == LogCategory.bleTx &&
                e.message.contains('"cmd":100'),
          ),
          isTrue,
        );
        expect(
          logger.entries.any(
            (e) =>
                e.category == LogCategory.bleTx &&
                e.message.contains('"cmd":200'),
          ),
          isTrue,
        );
        expect(find.text('25:00'), findsOneWidget);
        expect(find.text('待機中'), findsOneWidget);

        // ------------------------------------------------------------------
        // Milestone 2: Core Focus Loop -> 1Hz EVT_STATUS -> Away -> Resume
        // ------------------------------------------------------------------
        await tester.tap(find.byKey(const Key('btn_start_focus')));
        await tester.pump();
        await tester.pump();
        expect(find.text('專注中'), findsOneWidget);
        expect(guardService.startCount, greaterThan(0));

        await tester.pump(const Duration(seconds: 1));
        expect(find.text('24:59'), findsOneWidget);

        final stopCountBeforeAway = guardService.stopCount;
        mockRepo.simulateAway(true);
        await tester.pump();
        await tester.pump();
        expect(find.text('離位暫停'), findsOneWidget);
        expect(find.byKey(const Key('btn_resume')), findsNothing);
        expect(guardService.stopCount, stopCountBeforeAway + 1);

        final startCountBeforeReturn = guardService.startCount;
        mockRepo.simulateAway(false);
        await tester.pump();
        await tester.pump();
        expect(find.text('專注中'), findsOneWidget);
        expect(guardService.startCount, greaterThan(startCountBeforeReturn));

        // Stop early (< 60s) back to IDLE cleanly.
        await tester.tap(find.byKey(const Key('btn_stop')));
        await tester.pumpAndSettle();
        expect(find.text('待機中'), findsOneWidget);

        // ------------------------------------------------------------------
        // Milestone 3: Config (101), Todos CRUD + Swap (205), NVS Power Cycle
        // ------------------------------------------------------------------
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

        await tester.tap(find.byKey(const Key('nav_todos')));
        await tester.pumpAndSettle();

        for (final title in const <String>['Task Alpha', 'Task Beta']) {
          await tester.tap(find.byKey(const Key('btn_add_todo')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('input_todo_title')),
            title,
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('btn_save_todo_dialog')));
          await tester.pumpAndSettle();
        }

        final todosElement = tester.element(
          find.byKey(const Key('screen_todos')),
        );
        final container = ProviderScope.containerOf(todosElement);
        final reordered =
            await container.read(todoControllerProvider.notifier).reorderTodos(
                  0,
                  4,
                );
        expect(reordered, isTrue);
        await tester.pumpAndSettle();

        expect(
          mockRepo.debugTodosSnapshot.map((t) => t.title).toList(),
          const <String>[
            'Verify BLE Protocol',
            'Task Alpha',
            'Task Beta',
            'Read Embedded Spec',
          ],
        );
        expect(
          logger.entries.any(
            (e) =>
                e.category == LogCategory.bleTx &&
                e.message.contains('"cmd":205'),
          ),
          isTrue,
        );

        // Simulate ESP32 power cycle -> clock resets, then handshake reloads NVS.
        final powerCycleFuture = mockRepo.simulatePowerCycle();
        await tester.pump(Duration.zero);
        await powerCycleFuture;
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        expect(mockRepo.isClockSynced, isTrue);
        final reloadedCfg = await mockRepo.getConfig();
        expect(reloadedCfg.focusMinutes, 30);
        expect(reloadedCfg.mute, isTrue);
        expect(
          container.read(todoControllerProvider).items.map((t) => t.title),
          const <String>[
            'Verify BLE Protocol',
            'Task Alpha',
            'Task Beta',
            'Read Embedded Spec',
          ],
        );

        // ------------------------------------------------------------------
        // Milestone 4: Disconnect Mid-Focus -> Safety Valve -> History Sync
        // ------------------------------------------------------------------
        await tester.tap(find.byKey(const Key('nav_timer')));
        await tester.pumpAndSettle();
        expect(find.text('30:00'), findsOneWidget);

        await tester.tap(find.byKey(const Key('selector_bound_todo')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Verify BLE Protocol').last);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('btn_start_focus')));
        await tester.pump();
        await tester.pump();

        mockRepo.fastForwardRemaining(4);
        await tester.pump();

        final stopBeforeDisconnect = guardService.stopCount;
        mockRepo.simulateDisconnect();
        await tester.pump();
        await tester.pump();

        expect(find.byKey(const Key('banner_disconnected')), findsOneWidget);
        expect(
          find.byKey(const Key('txt_safety_valve_countdown')),
          findsOneWidget,
        );
        expect(guardService.stopCount, stopBeforeDisconnect);

        // Let both local safety valve (4s) and background mock countdown finish.
        await tester.pump(const Duration(seconds: 4));
        await tester.pump();

        expect(
          find.byKey(const Key('txt_safety_valve_tripped')),
          findsOneWidget,
        );
        expect(guardService.stopCount, stopBeforeDisconnect + 1);
        expect(mockRepo.debugUnsyncedCount, 1);

        // Reconnect drains offline NVS queue into SQLite & updates StatsScreen.
        await mockRepo.simulateReconnect();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        expect(mockRepo.debugUnsyncedCount, 0);

        await tester.tap(find.byKey(const Key('nav_stats')));
        await tester.pumpAndSettle();

        expect(find.text('1 顆'), findsOneWidget);
        expect(find.text('30 分鐘'), findsOneWidget);
        expect(find.text('Verify BLE Protocol'), findsWidgets);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
