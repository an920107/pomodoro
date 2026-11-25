import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme.dart';
import '../../state/ble_providers.dart';

/// Collapsible hardware simulator visible only when running in Mock BLE mode.
/// Lets developers trigger proximity, fast-forward, disconnect, and power-cycle
/// scenarios directly on a single Android phone without an ESP32 board.
class MockDebugPanel extends ConsumerStatefulWidget {
  const MockDebugPanel({super.key});

  @override
  ConsumerState<MockDebugPanel> createState() => _MockDebugPanelState();
}

class _MockDebugPanelState extends ConsumerState<MockDebugPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isMock = ref.watch(isMockBleModeProvider);
    if (!isMock) {
      return const SizedBox.shrink();
    }

    final mockRepo = ref.watch(mockBleRepositoryProvider);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surfaceRecessed,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            key: const Key('btn_toggle_mock_panel'),
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() {
                _expanded = !_expanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.memory_outlined,
                    size: 18,
                    color: AppColors.ink,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Mock 虛擬韌體模擬器',
                      style: textTheme.titleMedium,
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: AppColors.inkMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...<Widget>[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '直接對虛擬 ESP32 注入硬體事件（無須實體開發板）',
                    style: textTheme.bodyMedium?.copyWith(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _SimActionButton(
                        key: const Key('mock_btn_away'),
                        label: '模擬離位',
                        icon: Icons.directions_walk_rounded,
                        onPressed: () => mockRepo.simulateAway(true),
                      ),
                      _SimActionButton(
                        key: const Key('mock_btn_seat'),
                        label: '模擬回座',
                        icon: Icons.chair_alt_rounded,
                        onPressed: () => mockRepo.simulateAway(false),
                      ),
                      _SimActionButton(
                        key: const Key('mock_btn_ff_5s'),
                        label: '快轉剩 5 秒',
                        icon: Icons.fast_forward_rounded,
                        onPressed: () => mockRepo.fastForwardRemaining(5),
                      ),
                      _SimActionButton(
                        key: const Key('mock_btn_ff_0s'),
                        label: '立即完賽 (0s)',
                        icon: Icons.done_all_rounded,
                        onPressed: () => mockRepo.fastForwardRemaining(0),
                      ),
                      _SimActionButton(
                        key: const Key('mock_btn_disconnect'),
                        label: '模擬斷線',
                        icon: Icons.link_off_rounded,
                        onPressed: () => mockRepo.simulateDisconnect(),
                      ),
                      _SimActionButton(
                        key: const Key('mock_btn_flaky_reconnect'),
                        label: '模擬退避重連',
                        icon: Icons.sync_problem_rounded,
                        onPressed: () => mockRepo.simulateDisconnect(
                          autoReconnect: true,
                          failCount: 2,
                        ),
                      ),
                      _SimActionButton(
                        key: const Key('mock_btn_reconnect'),
                        label: '模擬重連',
                        icon: Icons.link_rounded,
                        onPressed: () {
                          mockRepo.simulateReconnect();
                        },
                      ),
                      _SimActionButton(
                        key: const Key('mock_btn_power_cycle'),
                        label: '模擬斷電重啟',
                        icon: Icons.power_settings_new_rounded,
                        onPressed: () {
                          mockRepo.simulatePowerCycle();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SimActionButton extends StatelessWidget {
  const _SimActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    );
  }
}
