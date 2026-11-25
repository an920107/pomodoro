import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import '../../../state/pomodoro_controller.dart';

/// Top status banner shown whenever the BLE connection is interrupted,
/// displaying reconnect status and safety-valve countdown (`spec.md` §4.1.2).
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(pomodoroControllerProvider);
    if (viewState.isConnected) {
      return const SizedBox.shrink();
    }

    final connection = viewState.connection;
    final textTheme = Theme.of(context).textTheme;

    final String headline;
    if (!connection.isBluetoothAdapterOn) {
      headline = '手機藍牙未開啟，請開啟藍牙以連線';
    } else if (connection.reconnectAttempt > 0) {
      final retryLabel = connection.nextRetryDelay != null
          ? '每 ${connection.nextRetryDelay!.inSeconds} 秒重試'
          : '重試中';
      headline =
          '裝置已斷線，嘗試重連中...（第 ${connection.reconnectAttempt} 次，$retryLabel）';
    } else {
      headline = '裝置已斷線，嘗試重連中...';
    }

    final isTripped = viewState.safetyValveTripped;
    final accent = isTripped ? AppColors.signalBreak : AppColors.signalFocus;

    return Container(
      key: const Key('banner_disconnected'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(color: accent, width: 1.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(
            isTripped ? Icons.lock_open_rounded : Icons.bluetooth_disabled,
            size: 18,
            color: accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  headline,
                  style: textTheme.labelMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (viewState.isSafetyValveActive) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    '安全閥本地估算剩餘 ${formatMmSs(viewState.safetyValveRemainingSeconds!)}（歸零自動解除手機鎖定）',
                    key: const Key('txt_safety_valve_countdown'),
                    style: textTheme.bodyMedium?.copyWith(
                      fontSize: 12,
                      color: AppColors.ink,
                    ),
                  ),
                ] else if (viewState.safetyValveTripped) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    '安全閥已觸發：本地倒數結束，已解除專注鎖定',
                    key: const Key('txt_safety_valve_tripped'),
                    style: textTheme.bodyMedium?.copyWith(
                      fontSize: 12,
                      color: AppColors.signalBreak,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const Key('btn_banner_reconnect'),
            onPressed: () {
              ref.read(pomodoroControllerProvider.notifier).reconnectNow();
            },
            style: TextButton.styleFrom(
              foregroundColor: AppColors.ink,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('立即重連'),
          ),
        ],
      ),
    );
  }
}
