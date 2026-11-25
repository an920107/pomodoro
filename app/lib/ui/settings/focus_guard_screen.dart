import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';
import '../../data/native/focus_guard_service.dart';
import '../../state/focus_guard_controller.dart';

/// Configures Android DND permission, Usage Access, Overlay permission, and
/// blacklisted distracting apps for FocusGuard.
class FocusGuardScreen extends ConsumerStatefulWidget {
  const FocusGuardScreen({super.key});

  @override
  ConsumerState<FocusGuardScreen> createState() => _FocusGuardScreenState();
}

class _FocusGuardScreenState extends ConsumerState<FocusGuardScreen>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.microtask(() async {
      final controller = ref.read(focusGuardControllerProvider.notifier);
      await controller.refreshPermissions();
      await controller.loadInstalledApps();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref.read(focusGuardControllerProvider.notifier).refreshPermissions(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final guardState = ref.watch(focusGuardControllerProvider);
    final controller = ref.read(focusGuardControllerProvider.notifier);
    final isAndroidSupported =
        ref.watch(focusGuardServiceProvider).isSupportedPlatform;
    final textTheme = Theme.of(context).textTheme;
    final normalizedQuery = _searchQuery.trim().toLowerCase();

    final blacklistedSet = guardState.blacklistedPackages.toSet();
    final filteredApps = guardState.installedApps
        .where((app) {
          if (normalizedQuery.isEmpty) return true;
          return app.appName.toLowerCase().contains(normalizedQuery) ||
              app.packageName.toLowerCase().contains(normalizedQuery);
        })
        .toList(growable: false)
      ..sort((a, b) {
        final aChecked = blacklistedSet.contains(a.packageName);
        final bChecked = blacklistedSet.contains(b.packageName);
        if (aChecked != bChecked) {
          return aChecked ? -1 : 1;
        }
        return a.appName.toLowerCase().compareTo(b.appName.toLowerCase());
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('專注守護設定'),
        actions: <Widget>[
          IconButton(
            key: const Key('btn_refresh_guard_permissions'),
            tooltip: '重新檢查權限',
            onPressed: () {
              unawaited(controller.refreshPermissions());
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: <Widget>[
            if (!isAndroidSupported) ...<Widget>[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  '目前非 Android 實機環境，系統勿擾與前景鎖定遮罩將安全降級為僅記錄狀態。',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (guardState.errorMessage != null) ...<Widget>[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.signalFocus),
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.signalFocus,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        guardState.errorMessage!,
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.signalFocus,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: controller.clearError,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Android 系統權限', style: textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '專注中自動切換勿擾與偵測分心 App 需先開啟對應系統權限',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _PermissionRow(
                      buttonKey: const Key('btn_grant_dnd'),
                      title: '勿擾模式存取權 (DND)',
                      granted: guardState.permissions.dndGranted,
                      onPressed: () {
                        unawaited(
                          controller.openPermissionSettings(
                            FocusPermissionKind.dnd,
                          ),
                        );
                      },
                    ),
                    const Divider(height: 16),
                    _PermissionRow(
                      buttonKey: const Key('btn_grant_usage'),
                      title: '使用情況存取權 (UsageStats)',
                      granted: guardState.permissions.usageAccessGranted,
                      onPressed: () {
                        unawaited(
                          controller.openPermissionSettings(
                            FocusPermissionKind.usageAccess,
                          ),
                        );
                      },
                    ),
                    const Divider(height: 16),
                    _PermissionRow(
                      buttonKey: const Key('btn_grant_overlay'),
                      title: '顯示於其他應用程式上層 (Overlay)',
                      granted: guardState.permissions.overlayGranted,
                      onPressed: () {
                        unawaited(
                          controller.openPermissionSettings(
                            FocusPermissionKind.overlay,
                          ),
                        );
                      },
                    ),
                    if (!guardState.permissions.notificationsGranted) ...<Widget>[
                      const Divider(height: 16),
                      _PermissionRow(
                        buttonKey: const Key('btn_grant_notifications'),
                        title: '通知權限 (前景服務通知)',
                        granted: false,
                        onPressed: () {
                          unawaited(
                            controller.openPermissionSettings(
                              FocusPermissionKind.notifications,
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('專注防護策略', style: textTheme.titleMedium),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      key: const Key('switch_guard_dnd'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('專注期間自動開啟勿擾 (DND)'),
                      subtitle: const Text(
                        '進入 FOCUS_RUNNING 時開啟勿擾；暫停、離位或結束立即還原',
                      ),
                      value: guardState.dndEnabled,
                      onChanged: (val) {
                        unawaited(controller.setDndEnabled(val));
                      },
                    ),
                    const Divider(height: 12),
                    SwitchListTile(
                      key: const Key('switch_guard_app_lock'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('鎖定黑名單應用程式'),
                      subtitle: const Text(
                        '開啟已勾選的黑名單 App 時立即彈出專注遮罩',
                      ),
                      value: guardState.appLockEnabled,
                      onChanged: (val) {
                        unawaited(controller.setAppLockEnabled(val));
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '應用程式黑名單',
                            style: textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          '已選 ${guardState.blacklistedPackages.length} 項',
                          key: const Key('txt_blacklist_count'),
                          style: textTheme.labelMedium?.copyWith(
                            color: AppColors.signalFocus,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const Key('input_search_apps'),
                      controller: _searchController,
                      keyboardType: TextInputType.visiblePassword,
                      onChanged: (val) {
                        setState(() {
                          _searchQuery = val;
                        });
                      },
                      decoration: InputDecoration(
                        hintText: '搜尋名稱或 package (e.g. settings)',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _searchQuery = '';
                                  });
                                },
                                icon: const Icon(Icons.clear_rounded),
                              )
                            : null,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (guardState.isLoadingApps)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (filteredApps.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceRecessed,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          guardState.installedApps.isEmpty
                              ? '未取得可啟動應用程式清單'
                              : '找不到符合「$_searchQuery」的應用程式',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.inkMuted,
                          ),
                        ),
                      )
                    else
                      for (var i = 0; i < filteredApps.length; i++) ...<Widget>[
                        CheckboxListTile(
                          key: Key(
                            'checkbox_app_${filteredApps[i].packageName}',
                          ),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: guardState.blacklistedPackages.contains(
                            filteredApps[i].packageName,
                          ),
                          onChanged: (_) {
                            unawaited(
                              controller.toggleBlacklistedPackage(
                                filteredApps[i].packageName,
                              ),
                            );
                          },
                          title: Text(
                            filteredApps[i].appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            filteredApps[i].packageName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelSmall?.copyWith(
                              color: AppColors.inkMuted,
                            ),
                          ),
                        ),
                        if (i < filteredApps.length - 1)
                          const Divider(height: 1, color: AppColors.border),
                      ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.buttonKey,
    required this.title,
    required this.granted,
    required this.onPressed,
  });

  final Key buttonKey;
  final String title;
  final bool granted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final badgeColor = granted ? AppColors.signalBreak : AppColors.signalWarn;

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: textTheme.bodyMedium),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  granted ? '已授權' : '未授權',
                  style: textTheme.labelSmall?.copyWith(
                    color: badgeColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          key: buttonKey,
          onPressed: onPressed,
          child: Text(granted ? '已開啟' : '前往授權'),
        ),
      ],
    );
  }
}
