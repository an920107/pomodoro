import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pomodoro/app.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/data/local/preferences_store.dart';
import 'package:pomodoro/data/native/focus_guard_service.dart';
import 'package:pomodoro/state/ble_providers.dart';
import 'package:pomodoro/state/focus_guard_controller.dart';
import 'package:pomodoro/ui/settings/focus_guard_screen.dart';

class _StartCall {
  const _StartCall({
    required this.remainingSeconds,
    required this.dndEnabled,
    required this.appLockEnabled,
    required this.blacklistedPackages,
    this.taskTitle,
  });

  final int remainingSeconds;
  final bool dndEnabled;
  final bool appLockEnabled;
  final List<String> blacklistedPackages;
  final String? taskTitle;
}

class _RecordingFocusGuardService implements FocusGuardPlatformService {
  _RecordingFocusGuardService({
    this.permissions = const FocusGuardPermissions(
      dndGranted: true,
      usageAccessGranted: true,
      overlayGranted: true,
      notificationsGranted: true,
    ),
  });

  FocusGuardPermissions permissions;
  List<InstalledAppInfo> apps = const <InstalledAppInfo>[
    InstalledAppInfo(
      packageName: 'com.android.settings',
      appName: '設定',
      isSystemApp: true,
    ),
    InstalledAppInfo(
      packageName: 'com.android.chrome',
      appName: 'Chrome',
      isSystemApp: false,
    ),
  ];
  final List<_StartCall> startCalls = <_StartCall>[];
  int stopCallCount = 0;
  final List<FocusPermissionKind> openedSettings = <FocusPermissionKind>[];

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<FocusGuardPermissions> checkPermissions() async => permissions;

  @override
  Future<bool> openPermissionSettings(FocusPermissionKind kind) async {
    openedSettings.add(kind);
    return true;
  }

  @override
  Future<List<InstalledAppInfo>> getInstalledApps() async => apps;

  @override
  Future<void> startOrUpdateGuard({
    required int remainingSeconds,
    required bool dndEnabled,
    required bool appLockEnabled,
    required List<String> blacklistedPackages,
    String? taskTitle,
  }) async {
    startCalls.add(
      _StartCall(
        remainingSeconds: remainingSeconds,
        dndEnabled: dndEnabled,
        appLockEnabled: appLockEnabled,
        blacklistedPackages: List<String>.unmodifiable(blacklistedPackages),
        taskTitle: taskTitle,
      ),
    );
  }

  @override
  Future<void> stopGuard() async {
    stopCallCount++;
  }
}

void main() {
  group('FocusGuardController & FocusGuardScreen', () {
    testWidgets(
        'engages on FOCUS_RUNNING, releases on AWAY, preserves during safety valve, and stops on expiry',
        (WidgetTester tester) async {
      final logger = AppLogger(printer: (_) {});
      final mockRepo = MockBleRepository(
        nvsStore: InMemoryMockNvsStore(),
        logger: logger,
      );
      final prefs = InMemoryPreferencesStore(
        isDebugMode: true,
        isMockBleMode: true,
        dndEnabled: true,
        appLockEnabled: true,
        blacklistedPackages: const <String>['com.android.settings'],
      );
      final fakeGuard = _RecordingFocusGuardService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mockBleRepositoryProvider.overrideWith((ref) {
              ref.onDispose(mockRepo.dispose);
              return mockRepo;
            }),
            preferencesStoreProvider.overrideWithValue(prefs),
            focusGuardServiceProvider.overrideWithValue(fakeGuard),
          ],
          child: const PomodoroApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(fakeGuard.startCalls, isEmpty);
      expect(fakeGuard.stopCallCount, 0);

      // Start Focus -> engages FocusGuard immediately.
      await tester.tap(find.byKey(const Key('btn_start_focus')));
      await tester.pump();
      await tester.pump();
      expect(fakeGuard.startCalls, isNotEmpty);
      expect(fakeGuard.startCalls.last.dndEnabled, isTrue);
      expect(fakeGuard.startCalls.last.appLockEnabled, isTrue);
      expect(
        fakeGuard.startCalls.last.blacklistedPackages,
        <String>['com.android.settings'],
      );

      // Proximity Away -> FOCUS_PAUSED_AWAY releases DND & overlay immediately.
      mockRepo.simulateAway(true);
      await tester.pump();
      await tester.pump();
      expect(fakeGuard.stopCallCount, 1);

      // Back in seat -> FOCUS_RUNNING re-engages guard.
      final callsBeforeResume = fakeGuard.startCalls.length;
      mockRepo.simulateAway(false);
      await tester.pump();
      await tester.pump();
      expect(fakeGuard.startCalls.length, greaterThan(callsBeforeResume));

      // Disconnect mid-focus with 4s remaining -> MUST NOT stop guard yet.
      mockRepo.fastForwardRemaining(4);
      await tester.pump();
      final stopCountBeforeDisconnect = fakeGuard.stopCallCount;
      final startCountBeforeDisconnect = fakeGuard.startCalls.length;
      mockRepo.simulateDisconnect();
      await tester.pump();
      await tester.pump();
      expect(fakeGuard.stopCallCount, stopCountBeforeDisconnect);

      // Advance 2s while offline -> guard remains active without extending deadline.
      await tester.pump(const Duration(seconds: 2));
      expect(fakeGuard.stopCallCount, stopCountBeforeDisconnect);
      expect(fakeGuard.startCalls.length, startCountBeforeDisconnect);

      // Advance remaining 2s -> safety valve expires -> stops FocusGuard automatically.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(fakeGuard.stopCallCount, stopCountBeforeDisconnect + 1);

      await tester.pumpWidget(const SizedBox.shrink());
      logger.dispose();
    });

    testWidgets(
        'FocusGuardScreen persists DND/AppLock switches and filters blacklisted apps',
        (WidgetTester tester) async {
      final prefs = InMemoryPreferencesStore();
      final fakeGuard = _RecordingFocusGuardService(
        permissions: const FocusGuardPermissions(
          dndGranted: false,
          usageAccessGranted: true,
          overlayGranted: true,
          notificationsGranted: true,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesStoreProvider.overrideWithValue(prefs),
            focusGuardServiceProvider.overrideWithValue(fakeGuard),
          ],
          child: const MaterialApp(home: FocusGuardScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // Permission status & grant shortcut work.
      expect(find.text('未授權'), findsOneWidget);
      expect(find.text('已授權'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('btn_grant_dnd')));
      await tester.pump();
      expect(fakeGuard.openedSettings, <FocusPermissionKind>[
        FocusPermissionKind.dnd,
      ]);

      // Enable DND & AppLock switches cleanly.
      await tester.ensureVisible(find.byKey(const Key('switch_guard_dnd')));
      await tester.tap(find.byKey(const Key('switch_guard_dnd')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('switch_guard_app_lock')));
      await tester.tap(find.byKey(const Key('switch_guard_app_lock')));
      await tester.pump();
      expect(prefs.dndEnabled, isTrue);
      expect(prefs.appLockEnabled, isTrue);

      // Search 'settings' and select com.android.settings.
      await tester.ensureVisible(find.byKey(const Key('input_search_apps')));
      await tester.enterText(
        find.byKey(const Key('input_search_apps')),
        'settings',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('checkbox_app_com.android.settings')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('checkbox_app_com.android.chrome')),
        findsNothing,
      );

      await tester.ensureVisible(
        find.byKey(const Key('checkbox_app_com.android.settings')),
      );
      await tester.tap(
        find.byKey(const Key('checkbox_app_com.android.settings')),
      );
      await tester.pumpAndSettle();

      expect(prefs.blacklistedPackages, <String>['com.android.settings']);
      expect(find.text('已選 1 項'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
