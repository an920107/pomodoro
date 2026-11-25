import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/protocol/protocol_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/local/app_database.dart';
import '../../state/ble_providers.dart';
import '../../state/history_controller.dart';

/// Displays local SQLite Pomodoro focus analytics, 7-day trend chart,
/// per-task time breakdown, and synced session logs.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  static final DateFormat _logDateFormat = DateFormat('MM/dd HH:mm');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyControllerProvider);
    final connectionAsync = ref.watch(bleConnectionProvider);
    final statusAsync = ref.watch(deviceStatusProvider);
    final isConnected =
        connectionAsync.asData?.value.state.isConnected ?? false;
    final unsyncedCount = statusAsync.asData?.value.unsyncedCount ?? 0;
    final textTheme = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: () => ref.read(historyControllerProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '專注歷史與報表',
                      style: textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '離線與連線專注紀錄自動去重並保存於本機資料庫',
                      style: textTheme.bodySmall?.copyWith(
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                key: const Key('btn_sync_history'),
                onPressed: (!isConnected || history.isSyncing)
                    ? null
                    : () =>
                          ref.read(historyControllerProvider.notifier).syncNow(),
                icon: history.isSyncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(
                  unsyncedCount > 0 ? '同步紀錄 ($unsyncedCount)' : '同步紀錄',
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _SummaryMetricCard(
                  label: '今日完成番茄',
                  valueKey: const Key('txt_stats_today_count'),
                  value: '${history.todayFocusCount} 顆',
                  accentColor: AppColors.signalFocus,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryMetricCard(
                  label: '今日專注時長',
                  valueKey: const Key('txt_stats_today_duration'),
                  value: formatDurationCompact(history.todayFocusSeconds),
                  accentColor: AppColors.signalBreak,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '近 7 日專注分佈',
            trailing: Text(
              '單位：分鐘',
              style: textTheme.labelMedium?.copyWith(
                color: AppColors.inkMuted,
              ),
            ),
            child: SizedBox(
              height: 180,
              width: double.infinity,
              child: CustomPaint(
                key: const Key('chart_weekly_focus'),
                painter: _WeeklyFocusChartPainter(
                  buckets: history.weeklyBuckets,
                  labelColor: AppColors.inkMuted,
                  todayLabelColor: AppColors.ink,
                  barColor: AppColors.signalFocus,
                  emptyBarColor: AppColors.surfaceRecessed,
                  gridColor: AppColors.border,
                ),
              ),
            ),
          ),
          if (history.todoShares.isNotEmpty) ...[
            const SizedBox(height: 16),
            _SectionCard(
              title: '任務時間佔比',
              trailing: Text(
                '${history.todoShares.length} 項分類',
                style: textTheme.labelMedium?.copyWith(
                  color: AppColors.inkMuted,
                ),
              ),
              child: Column(
                children: history.todoShares
                    .map(
                      (share) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _TodoShareRow(share: share),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _SectionCard(
            title: '歷史紀錄',
            trailing: Text(
              '共 ${history.records.length} 筆',
              style: textTheme.labelMedium?.copyWith(
                color: AppColors.inkMuted,
              ),
            ),
            child: history.records.isEmpty
                ? Container(
                    key: const Key('empty_stats_logs'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 24,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceRecessed,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.history_toggle_off_rounded,
                          size: 28,
                          color: AppColors.inkMuted,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '尚無已同步的專注紀錄',
                          style: textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '完成一輪專注或在計時頁注入離線紀錄並重連即可顯示',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < history.records.length; i++) ...[
                        _SessionLogTile(
                          record: history.records[i],
                          dateFormat: _logDateFormat,
                        ),
                        if (i < history.records.length - 1)
                          const Divider(height: 16, color: AppColors.border),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SummaryMetricCard extends StatelessWidget {
  const _SummaryMetricCard({
    required this.label,
    required this.valueKey,
    required this.value,
    required this.accentColor,
  });

  final String label;
  final Key valueKey;
  final String value;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: textTheme.labelLarge?.copyWith(
                  color: AppColors.inkMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            key: valueKey,
            style: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _TodoShareRow extends StatelessWidget {
  const _TodoShareRow({required this.share});

  final TodoFocusShare share;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final pct = (share.fraction * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                share.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${formatDurationCompact(share.totalSeconds)} · $pct%',
              style: textTheme.labelMedium?.copyWith(
                color: AppColors.inkMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: share.fraction.clamp(0.0, 1.0),
            minHeight: 7,
            backgroundColor: AppColors.surfaceRecessed,
            valueColor: const AlwaysStoppedAnimation<Color>(
              AppColors.signalFocus,
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionLogTile extends StatelessWidget {
  const _SessionLogTile({
    required this.record,
    required this.dateFormat,
  });

  final SessionLogRecord record;
  final DateFormat dateFormat;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final log = record.log;
    final isFocus = log.type == SessionType.focus;
    final isCompleted = log.result == SessionResult.completed;
    final timestampText = log.startEpoch > 0
        ? dateFormat.format(
            DateTime.fromMillisecondsSinceEpoch(log.startEpoch * 1000),
          )
        : '時間未知';

    final statusColor = isFocus
        ? (isCompleted ? AppColors.signalFocus : AppColors.signalWarn)
        : AppColors.signalBreak;

    return Row(
      key: Key('log_item_${log.logId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4),
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                record.displayTodoTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '$timestampText · ${formatDurationCompact(log.durationSeconds)} · ${isFocus ? '專注' : '休息'}',
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.inkMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.end,
          children: [
            if (log.isEstimatedTime)
              Container(
                key: Key('badge_estimated_${log.logId}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppColors.signalWarn.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: AppColors.signalWarn.withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  '估算時間',
                  style: textTheme.labelSmall?.copyWith(
                    color: AppColors.signalWarn,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                isCompleted ? '完成' : '中斷',
                style: textTheme.labelSmall?.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _WeeklyFocusChartPainter extends CustomPainter {
  const _WeeklyFocusChartPainter({
    required this.buckets,
    required this.labelColor,
    required this.todayLabelColor,
    required this.barColor,
    required this.emptyBarColor,
    required this.gridColor,
  });

  final List<DailyFocusBucket> buckets;
  final Color labelColor;
  final Color todayLabelColor;
  final Color barColor;
  final Color emptyBarColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (buckets.isEmpty) return;

    const topMargin = 22.0;
    const bottomMargin = 24.0;
    final chartHeight = math.max(24.0, size.height - topMargin - bottomMargin);
    final baselineY = topMargin + chartHeight;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final ratio in [0.0, 0.5, 1.0]) {
      final y = topMargin + chartHeight * ratio;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final maxMinutes = buckets.fold<double>(
      30.0,
      (best, b) => math.max(best, b.focusMinutes),
    );
    final slotWidth = size.width / buckets.length;
    final barWidth = math.min(28.0, slotWidth * 0.48);

    for (var i = 0; i < buckets.length; i++) {
      final bucket = buckets[i];
      final centerX = slotWidth * (i + 0.5);
      final left = centerX - barWidth / 2;

      final mins = bucket.focusMinutes;
      final normalized = (mins / maxMinutes).clamp(0.0, 1.0);
      final barHeight = mins > 0
          ? math.max(6.0, chartHeight * normalized)
          : 4.0;

      final barRect = RRect.fromRectAndCorners(
        Rect.fromLTWH(left, baselineY - barHeight, barWidth, barHeight),
        topLeft: const Radius.circular(6),
        topRight: const Radius.circular(6),
      );
      final paint = Paint()
        ..color = mins > 0
            ? (bucket.isToday ? barColor : barColor.withValues(alpha: 0.68))
            : emptyBarColor;
      canvas.drawRRect(barRect, paint);

      if (mins >= 1) {
        final valueText = mins.round().toString();
        final valuePainter = TextPainter(
          text: TextSpan(
            text: valueText,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: todayLabelColor,
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        valuePainter.paint(
          canvas,
          Offset(
            centerX - valuePainter.width / 2,
            baselineY - barHeight - valuePainter.height - 3,
          ),
        );
      }

      final labelPainter = TextPainter(
        text: TextSpan(
          text: bucket.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: bucket.isToday ? FontWeight.w700 : FontWeight.w500,
            color: bucket.isToday ? todayLabelColor : labelColor,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      labelPainter.paint(
        canvas,
        Offset(centerX - labelPainter.width / 2, baselineY + 6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WeeklyFocusChartPainter oldDelegate) {
    return oldDelegate.buckets != buckets;
  }
}
