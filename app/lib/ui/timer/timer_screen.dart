import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/protocol/protocol_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/todo_item.dart';
import '../../state/pomodoro_controller.dart';
import 'mock_debug_panel.dart';

/// Primary Pomodoro controller screen driven strictly by ESP32 `EVT_STATUS`
/// (`docs/spec.md` §2).
class TimerScreen extends ConsumerWidget {
  const TimerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(pomodoroControllerProvider);
    final controller = ref.read(pomodoroControllerProvider.notifier);
    final status = viewState.status;
    final state = status.state;
    final textTheme = Theme.of(context).textTheme;

    final accentColor = _accentForState(
      state: state,
      isSafetyValveActive: viewState.isSafetyValveActive,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _StatusBadge(
                key: const Key('badge_pomodoro_state'),
                dotColor: accentColor,
                label: state.label,
              ),
              _StatusBadge(
                key: const Key('badge_sensor_presence'),
                dotColor:
                    status.isAway ? AppColors.signalWarn : AppColors.signalBreak,
                label: status.isAway ? '感測：離位' : '感測：在位',
              ),
              if (status.unsyncedCount > 0)
                _StatusBadge(
                  key: const Key('badge_unsynced_count'),
                  dotColor: AppColors.inkMuted,
                  label: '待同步 ${status.unsyncedCount} 筆',
                ),
            ],
          ),
          if (viewState.errorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            _InlineErrorBanner(
              message: viewState.errorMessage!,
              onDismiss: controller.clearError,
            ),
          ],
          if (state == PomodoroState.focusPausedAway) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              key: const Key('banner_away_paused'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.signalWarn, width: 1.5),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.sensors_off_rounded,
                    color: AppColors.signalWarn,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '偵測到離開座位，計時已自動暫停',
                          style: textTheme.titleMedium?.copyWith(
                            color: AppColors.signalWarn,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '回到座位後將自動繼續計時，無須手動恢復。',
                          style: textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: 228,
              height: 228,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  CustomPaint(
                    size: const Size.square(228),
                    painter: _DialPainter(
                      progress: viewState.displayProgress,
                      accentColor: accentColor,
                      trackColor: AppColors.surfaceRecessed,
                      tickColor: AppColors.border,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        formatMmSs(viewState.displaySeconds),
                        key: const Key('txt_timer_mmss'),
                        style: textTheme.displayLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _dialSubtitle(viewState),
                        key: const Key('txt_timer_subtitle'),
                        style: textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _BoundTodoCard(viewState: viewState),
          const SizedBox(height: 16),
          _ActionButtonsRow(viewState: viewState),
          const SizedBox(height: 20),
          const MockDebugPanel(),
        ],
      ),
    );
  }

  static Color _accentForState({
    required PomodoroState state,
    required bool isSafetyValveActive,
  }) {
    if (isSafetyValveActive) {
      return AppColors.signalWarn;
    }
    return switch (state) {
      PomodoroState.idle => AppColors.inkMuted,
      PomodoroState.focusRunning => AppColors.signalFocus,
      PomodoroState.focusPausedUser => AppColors.signalFocus,
      PomodoroState.focusPausedAway => AppColors.signalWarn,
      PomodoroState.breakRunning => AppColors.signalBreak,
      PomodoroState.breakPausedUser => AppColors.signalBreak,
    };
  }

  static String _dialSubtitle(PomodoroViewState viewState) {
    if (viewState.isSafetyValveActive) {
      return '離線安全閥估算中';
    }
    if (!viewState.isConnected && viewState.safetyValveTripped) {
      return '安全閥已解除鎖定';
    }
    final status = viewState.status;
    return switch (status.state) {
      PomodoroState.idle => '待命準備 (${viewState.config.focusMinutes} 分鐘)',
      PomodoroState.focusRunning =>
        '總長 ${formatMmSs(status.totalSeconds)}',
      PomodoroState.focusPausedUser => '使用者已暫停',
      PomodoroState.focusPausedAway => '離位自動暫停',
      PomodoroState.breakRunning =>
        '休息中 (${formatMmSs(status.totalSeconds)})',
      PomodoroState.breakPausedUser => '休息已暫停',
    };
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    super.key,
    required this.dotColor,
    required this.label,
  });

  final Color dotColor;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
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
              color: dotColor,
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
    );
  }
}

class _InlineErrorBanner extends StatelessWidget {
  const _InlineErrorBanner({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.signalFocus),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppColors.signalFocus,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.signalFocus,
                  ),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _BoundTodoCard extends ConsumerWidget {
  const _BoundTodoCard({required this.viewState});

  final PomodoroViewState viewState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final isIdle = viewState.status.state == PomodoroState.idle;
    final controller = ref.read(pomodoroControllerProvider.notifier);

    if (!isIdle) {
      final boundTitle = viewState.boundTodoTitle ?? '自由專注（未綁定待辦）';
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.task_alt_rounded,
                size: 18,
                color: AppColors.inkMuted,
              ),
              const SizedBox(width: 10),
              Text('目前任務', style: textTheme.labelMedium),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  boundTitle,
                  key: const Key('txt_bound_todo_readonly'),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final todos = viewState.todos;
    final items = <DropdownMenuItem<int>>[
      const DropdownMenuItem<int>(
        value: BleProtocolConstants.unboundTodoId,
        child: Text('不綁定待辦事項'),
      ),
      ...todos.map(
        (TodoItem item) => DropdownMenuItem<int>(
          value: item.id,
          child: Text(
            item.done ? '${item.title}（已完成）' : item.title,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ];
    final currentSelection = items.any((i) => i.value == viewState.selectedTodoId)
        ? viewState.selectedTodoId
        : BleProtocolConstants.unboundTodoId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('綁定待辦事項', style: textTheme.labelMedium),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.surfaceRecessed,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('selector_bound_todo'),
                  isExpanded: true,
                  value: currentSelection,
                  items: items,
                  onChanged: viewState.isControlsLocked
                      ? null
                      : (int? value) {
                          if (value != null) {
                            controller.selectTodo(value);
                          }
                        },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButtonsRow extends ConsumerWidget {
  const _ActionButtonsRow({required this.viewState});

  final PomodoroViewState viewState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(pomodoroControllerProvider.notifier);
    final locked = viewState.isControlsLocked;
    final state = viewState.status.state;

    return switch (state) {
      PomodoroState.idle => Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                key: const Key('btn_start_focus'),
                onPressed: locked ? null : controller.startFocus,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('開始專注'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.signalFocus,
                  foregroundColor: AppColors.surface,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                key: const Key('btn_start_break'),
                onPressed: locked ? null : controller.startBreak,
                icon: const Icon(Icons.coffee_outlined, size: 18),
                label: const Text('開始休息'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.signalBreak,
                  side: const BorderSide(color: AppColors.signalBreak),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      PomodoroState.focusRunning => Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                key: const Key('btn_pause'),
                onPressed: locked ? null : controller.pause,
                icon: const Icon(Icons.pause_rounded),
                label: const Text('手動暫停'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.ink,
                  foregroundColor: AppColors.surface,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('btn_stop'),
                onPressed: locked ? null : controller.stop,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('停止'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.signalFocus,
                  side: const BorderSide(color: AppColors.signalFocus),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      PomodoroState.focusPausedUser => Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                key: const Key('btn_resume'),
                onPressed: locked ? null : controller.resume,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('繼續專注'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.signalFocus,
                  foregroundColor: AppColors.surface,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('btn_stop'),
                onPressed: locked ? null : controller.stop,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('停止'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.signalFocus,
                  side: const BorderSide(color: AppColors.signalFocus),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      // Proximity auto-pause: manual resume is forbidden by spec; only Stop.
      PomodoroState.focusPausedAway => SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('btn_stop'),
            onPressed: locked ? null : controller.stop,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('停止'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.signalFocus,
              side: const BorderSide(color: AppColors.signalFocus),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      PomodoroState.breakRunning => Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                key: const Key('btn_pause'),
                onPressed: locked ? null : controller.pause,
                icon: const Icon(Icons.pause_rounded),
                label: const Text('暫停休息'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.ink,
                  foregroundColor: AppColors.surface,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('btn_stop'),
                onPressed: locked ? null : controller.stop,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('結束休息'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.signalBreak,
                  side: const BorderSide(color: AppColors.signalBreak),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      PomodoroState.breakPausedUser => Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                key: const Key('btn_resume'),
                onPressed: locked ? null : controller.resume,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('繼續休息'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.signalBreak,
                  foregroundColor: AppColors.surface,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('btn_stop'),
                onPressed: locked ? null : controller.stop,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('結束休息'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.signalBreak,
                  side: const BorderSide(color: AppColors.signalBreak),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
    };
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({
    required this.progress,
    required this.accentColor,
    required this.trackColor,
    required this.tickColor,
  });

  final double progress;
  final Color accentColor;
  final Color trackColor;
  final Color tickColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = (math.min(size.width, size.height) / 2) - 4;
    final ringRadius = outerRadius - 14;

    // 60 subtle instrument bezel ticks around the outer perimeter.
    final tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < 60; i++) {
      final angle = -math.pi / 2 + (i * 2 * math.pi / 60);
      final isMajor = i % 5 == 0;
      final inner = outerRadius - (isMajor ? 7 : 4);
      final p1 = Offset(
        center.dx + inner * math.cos(angle),
        center.dy + inner * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + outerRadius * math.cos(angle),
        center.dy + outerRadius * math.sin(angle),
      );
      tickPaint.strokeWidth = isMajor ? 1.8 : 1.0;
      canvas.drawLine(p1, p2, tickPaint);
    }

    // Recessed base ring.
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    canvas.drawCircle(center, ringRadius, trackPaint);

    // Active progress arc.
    if (progress > 0) {
      final arcPaint = Paint()
        ..color = accentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.tickColor != tickColor;
  }
}
