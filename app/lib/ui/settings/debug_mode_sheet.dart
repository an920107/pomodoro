import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';
import '../../state/ble_providers.dart';
import '../../state/config_controller.dart';
import '../../state/debug_mode_controller.dart';
import '../../state/todo_controller.dart';
import 'packet_inspector_screen.dart';

/// Hidden developer modal opened after 5 consecutive taps on the bottom
/// Settings tab within 3 seconds (`plan.md` §4 Commit 10).
class DebugModeSheet extends ConsumerWidget {
  const DebugModeSheet({super.key});

  static bool _isOpen = false;

  static Future<void> show(BuildContext context) async {
    if (_isOpen) return;
    _isOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: AppColors.canvas,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => const DebugModeSheet(key: Key('sheet_debug_mode')),
      );
    } finally {
      _isOpen = false;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDebug = ref.watch(debugModeProvider);
    final isMock = ref.watch(isMockBleModeProvider);
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '開發者除錯模式',
                        style: textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '切換虛擬韌體模擬器、封包監看與診斷工具',
                        style: textTheme.bodySmall?.copyWith(
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('btn_close_debug_sheet'),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Card(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('switch_debug_mode'),
                    title: const Text('啟用 Debug 開發者模式'),
                    subtitle: const Text(
                      '顯示 Mock 模擬面板、自檢工具與封包監看入口；關閉時自動切回正式藍牙模式',
                    ),
                    value: isDebug,
                    onChanged: (val) {
                      unawaited(
                        ref.read(debugModeProvider.notifier).setDebugMode(val),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key('switch_debug_mock_ble'),
                    title: const Text('啟用 Mock 虛擬韌體模擬器'),
                    subtitle: const Text('免實體 ESP32 開發板直接模擬計時、離位與斷線補帳'),
                    value: isDebug && isMock,
                    onChanged: isDebug
                        ? (val) {
                            ref
                                .read(isMockBleModeProvider.notifier)
                                .setMockMode(val);
                          }
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key('btn_debug_open_inspector'),
                  onPressed: isDebug
                      ? () {
                          final navigator = Navigator.of(context);
                          navigator.pop();
                          navigator.push(
                            MaterialPageRoute<void>(
                              builder: (_) => const PacketInspectorScreen(),
                            ),
                          );
                        }
                      : null,
                  icon: const Icon(Icons.terminal_rounded, size: 18),
                  label: const Text('開啟封包監看器'),
                ),
                OutlinedButton.icon(
                  key: const Key('btn_debug_reset_mock_nvs'),
                  onPressed: isDebug
                      ? () async {
                          await ref
                              .read(mockBleRepositoryProvider)
                              .resetMockNvs();
                          if (ref.read(isMockBleModeProvider)) {
                            await ref
                                .read(configControllerProvider.notifier)
                                .loadConfig();
                            await ref
                                .read(todoControllerProvider.notifier)
                                .loadTodos();
                          }
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已重置 Mock 虛擬韌體 NVS'),
                            ),
                          );
                        }
                      : null,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('重置虛擬 NVS'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
