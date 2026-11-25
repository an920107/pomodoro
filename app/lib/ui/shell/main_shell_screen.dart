import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_theme.dart';

/// Top-level navigation tabs for the Phase 1 application shell.
enum AppTab {
  timer(
    label: '計時',
    headline: '專注計時控制',
    summary: '顯示裝置回報的即時狀態與倒數秒數，並發送開始、暫停、恢復與停止指令。',
    specSection: 'BLE Status (...5602) 與 RPC 控制 (cmd 11~15)',
    nextStep: '將於 Commit 2~4 接上協定佇列、Mock 模擬器與 6 態控制介面。',
    accentColor: AppColors.signalFocus,
  ),
  todos(
    label: '待辦',
    headline: '待辦事項清單',
    summary: '管理儲存在裝置 NVS 中的待辦事項，支援純 ASCII 標題、完成標記與拖曳排序。',
    specSection: '待辦操作指令 (cmd 200~205，上限 10 筆)',
    nextStep: '將於 Commit 5 實作新增、編輯、刪除與相鄰交換排序。',
    accentColor: AppColors.ink,
  ),
  stats(
    label: '統計',
    headline: '專注歷史與報表',
    summary: '保存裝置同步回來的專注與休息紀錄，呈現今日累積、近七日趨勢與待辦耗時分佈。',
    specSection: '歷史紀錄同步 (cmd 300~301) 與 SQLite 本地資料庫',
    nextStep: '將於 Commit 6 實作五步驟連線同步與自繪統計圖表。',
    accentColor: AppColors.signalBreak,
  ),
  settings(
    label: '設定',
    headline: '裝置參數與專注防護',
    summary: '調整專注與休息時長、提示音與離位感測參數，並管理 Android 勿擾與應用程式鎖定。',
    specSection: '裝置設定 (cmd 100~101) 與 FocusGuard 原生服務',
    nextStep: '將於 Commit 5、7、8 陸續接上參數設定、真實藍牙與原生守護服務。',
    accentColor: AppColors.signalWarn,
  );

  const AppTab({
    required this.label,
    required this.headline,
    required this.summary,
    required this.specSection,
    required this.nextStep,
    required this.accentColor,
  });

  final String label;
  final String headline;
  final String summary;
  final String specSection;
  final String nextStep;
  final Color accentColor;
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _TabPlaceholderPanel(
            key: Key('screen_${activeTab.name}'),
            tab: activeTab,
          ),
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

class _ModeBadge extends StatelessWidget {
  const _ModeBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
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
            decoration: const BoxDecoration(
              color: AppColors.signalWarn,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Phase 1 殼層',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AppColors.ink,
                ),
          ),
        ],
      ),
    );
  }
}

class _TabPlaceholderPanel extends StatelessWidget {
  const _TabPlaceholderPanel({
    super.key,
    required this.tab,
  });

  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: tab.accentColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tab.headline,
                style: textTheme.headlineMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          tab.summary,
          style: textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '介面規格與開發進度',
                  style: textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _DetailRow(
                  label: '對應規格',
                  value: tab.specSection,
                ),
                const SizedBox(height: 10),
                _DetailRow(
                  label: '架構原則',
                  value: '狀態以 ESP32 為主，App 僅接收呈現並發送控制指令',
                ),
                const SizedBox(height: 10),
                _DetailRow(
                  label: '整合進度',
                  value: tab.nextStep,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceRecessed,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '等待後續模組接線',
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                '此畫面為 Commit 1 建立的四分頁導覽基線，尚未啟動 BLE 與模擬韌體串流，因此不顯示虛擬計時數值。',
                style: textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: textTheme.labelMedium,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: textTheme.bodyMedium?.copyWith(color: AppColors.ink),
          ),
        ),
      ],
    );
  }
}
