import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../state/ble_providers.dart';
import '../../state/focus_guard_controller.dart';
import '../connection/device_scan_sheet.dart';
import '../settings/settings_screen.dart';
import '../stats/stats_screen.dart';
import '../timer/timer_screen.dart';
import '../todos/todos_screen.dart';
import 'widgets/connection_banner.dart';

/// Top-level navigation tabs for the Phase 1 application shell.
enum AppTab {
  timer(label: '計時'),
  todos(label: '待辦'),
  stats(label: '統計'),
  settings(label: '設定');

  const AppTab({required this.label});

  final String label;
}

/// Manages active bottom navigation tab selection.
class SelectedTabNotifier extends Notifier<AppTab> {
  @override
  AppTab build() => AppTab.timer;

  void select(AppTab tab) {
    if (state == tab) return;
    state = tab;
    AppLogger.instance.app('Switched tab -> ${tab.name}');
  }
}

final selectedTabProvider = NotifierProvider<SelectedTabNotifier, AppTab>(
  SelectedTabNotifier.new,
);

/// Root 4-tab application shell for Smart Pomodoro (Phase 1).
class MainShellScreen extends ConsumerWidget {
  const MainShellScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(handshakeCoordinatorProvider);
    ref.watch(focusGuardControllerProvider);
    final activeTab = ref.watch(selectedTabProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Pomodoro'),
        actions: const <Widget>[
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: _ModeBadge(),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            const ConnectionBanner(),
            Expanded(
              child: switch (activeTab) {
                AppTab.timer => const TimerScreen(key: Key('screen_timer')),
                AppTab.todos => const TodosScreen(key: Key('screen_todos')),
                AppTab.stats => const StatsScreen(key: Key('screen_stats')),
                AppTab.settings =>
                  const SettingsScreen(key: Key('screen_settings')),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: AppColors.border),
          ),
        ),
        child: NavigationBar(
          selectedIndex: activeTab.index,
          onDestinationSelected: (index) {
            ref.read(selectedTabProvider.notifier).select(AppTab.values[index]);
          },
          destinations: const <NavigationDestination>[
            NavigationDestination(
              key: Key('nav_timer'),
              icon: Icon(Icons.timer_outlined),
              selectedIcon: Icon(Icons.timer),
              label: '計時',
            ),
            NavigationDestination(
              key: Key('nav_todos'),
              icon: Icon(Icons.checklist_outlined),
              selectedIcon: Icon(Icons.checklist_rounded),
              label: '待辦',
            ),
            NavigationDestination(
              key: Key('nav_stats'),
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart_rounded),
              label: '統計',
            ),
            NavigationDestination(
              key: Key('nav_settings'),
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune_rounded),
              label: '設定',
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeBadge extends ConsumerWidget {
  const _ModeBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(bleConnectionProvider).asData?.value;
    final isConnected = connection?.state.isConnected ?? false;
    final isAdapterOn = connection?.isBluetoothAdapterOn ?? true;
    final isMock = ref.watch(isMockBleModeProvider);
    final label = isMock
        ? (isConnected ? 'Mock 已連線' : 'Mock ${connection?.state.label ?? '待機'}')
        : (!isAdapterOn
            ? '藍牙未開啟'
            : (isConnected
                ? 'BLE 已連線'
                : 'BLE ${connection?.state.label ?? '未連線'}'));

    return InkWell(
      key: const Key('btn_appbar_connection'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => DeviceScanSheet.show(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceRecessed,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isConnected
                    ? AppColors.signalBreak
                    : (!isAdapterOn ? AppColors.signalFocus : AppColors.signalWarn),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppColors.ink,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
