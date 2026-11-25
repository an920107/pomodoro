import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/protocol/protocol_constants.dart';
import '../data/local/app_database.dart';
import 'ble_providers.dart';

/// Focus total aggregated for a single local calendar day.
class DailyFocusBucket {
  const DailyFocusBucket({
    required this.day,
    required this.label,
    required this.isToday,
    required this.focusSeconds,
    required this.focusSessions,
  });

  final DateTime day;
  final String label;
  final bool isToday;
  final int focusSeconds;
  final int focusSessions;

  double get focusMinutes => focusSeconds / 60.0;
}

/// Focus breakdown entry grouped by preserved To-Do title.
class TodoFocusShare {
  const TodoFocusShare({
    required this.title,
    required this.totalSeconds,
    required this.sessions,
    required this.fraction,
  });

  final String title;
  final int totalSeconds;
  final int sessions;
  final double fraction;
}

/// Immutable state rendered by [StatsScreen].
class HistoryState {
  const HistoryState({
    this.records = const [],
    this.weeklyBuckets = const [],
    this.todoShares = const [],
    this.todayFocusCount = 0,
    this.todayFocusSeconds = 0,
    this.isLoading = false,
    this.isSyncing = false,
    this.errorMessage,
  });

  final List<SessionLogRecord> records;
  final List<DailyFocusBucket> weeklyBuckets;
  final List<TodoFocusShare> todoShares;
  final int todayFocusCount;
  final int todayFocusSeconds;
  final bool isLoading;
  final bool isSyncing;
  final String? errorMessage;

  HistoryState copyWith({
    List<SessionLogRecord>? records,
    List<DailyFocusBucket>? weeklyBuckets,
    List<TodoFocusShare>? todoShares,
    int? todayFocusCount,
    int? todayFocusSeconds,
    bool? isLoading,
    bool? isSyncing,
    String? errorMessage,
    bool clearError = false,
  }) {
    return HistoryState(
      records: records ?? this.records,
      weeklyBuckets: weeklyBuckets ?? this.weeklyBuckets,
      todoShares: todoShares ?? this.todoShares,
      todayFocusCount: todayFocusCount ?? this.todayFocusCount,
      todayFocusSeconds: todayFocusSeconds ?? this.todayFocusSeconds,
      isLoading: isLoading ?? this.isLoading,
      isSyncing: isSyncing ?? this.isSyncing,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Formats [seconds] into compact Traditional Chinese duration text.
String formatDurationCompact(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  if (safe == 0) return '0 分鐘';
  if (safe < 60) return '$safe 秒';
  final totalMinutes = safe ~/ 60;
  final hours = totalMinutes ~/ 60;
  final mins = totalMinutes % 60;
  if (hours == 0) return '$mins 分鐘';
  if (mins == 0) return '$hours 小時';
  return '$hours 小時 $mins 分';
}

/// Loads local SQLite session history and aggregates weekly charts & task shares.
class HistoryController extends Notifier<HistoryState> {
  bool _disposed = false;

  @override
  HistoryState build() {
    _disposed = false;
    ref.watch(appDatabaseProvider);
    ref.onDispose(() {
      _disposed = true;
    });

    final now = DateTime.now();
    Future<void>.microtask(refresh);

    return HistoryState(
      weeklyBuckets: _buildBuckets(const [], now),
      isLoading: true,
    );
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final db = ref.read(appDatabaseProvider);
    final records = await db.fetchAllSessionLogs();
    if (_disposed) return;

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final tomorrowStart = todayStart.add(const Duration(days: 1));

    var todayCount = 0;
    var todaySeconds = 0;
    final shareSeconds = <String, int>{};
    final shareCounts = <String, int>{};
    var totalFocusSeconds = 0;

    for (final record in records) {
      final log = record.log;
      if (log.type != SessionType.focus) continue;

      final localStart = DateTime.fromMillisecondsSinceEpoch(
        log.startEpoch * 1000,
      );
      if (!localStart.isBefore(todayStart) &&
          localStart.isBefore(tomorrowStart)) {
        todaySeconds += log.durationSeconds;
        if (log.result == SessionResult.completed) {
          todayCount++;
        }
      }

      if (log.durationSeconds > 0) {
        final key = record.displayTodoTitle;
        shareSeconds[key] = (shareSeconds[key] ?? 0) + log.durationSeconds;
        shareCounts[key] = (shareCounts[key] ?? 0) + 1;
        totalFocusSeconds += log.durationSeconds;
      }
    }

    final shares =
        shareSeconds.entries
            .map(
              (entry) => TodoFocusShare(
                title: entry.key,
                totalSeconds: entry.value,
                sessions: shareCounts[entry.key] ?? 1,
                fraction: totalFocusSeconds == 0
                    ? 0.0
                    : entry.value / totalFocusSeconds,
              ),
            )
            .toList()
          ..sort((a, b) => b.totalSeconds.compareTo(a.totalSeconds));

    state = state.copyWith(
      records: records,
      weeklyBuckets: _buildBuckets(records, now),
      todoShares: List<TodoFocusShare>.unmodifiable(shares),
      todayFocusCount: todayCount,
      todayFocusSeconds: todaySeconds,
      isLoading: false,
      clearError: true,
    );
  }

  /// Manually triggers Step 5 history sync through [HandshakeCoordinator].
  Future<void> syncNow() async {
    if (_disposed || state.isSyncing) return;
    state = state.copyWith(isSyncing: true, clearError: true);
    try {
      await ref.read(handshakeCoordinatorProvider).syncPendingHistory();
      await refresh();
    } finally {
      if (!_disposed) {
        state = state.copyWith(isSyncing: false);
      }
    }
  }

  List<DailyFocusBucket> _buildBuckets(
    List<SessionLogRecord> records,
    DateTime now,
  ) {
    final today = DateTime(now.year, now.month, now.day);
    final buckets = <DailyFocusBucket>[];

    for (var offset = 6; offset >= 0; offset--) {
      final day = today.subtract(Duration(days: offset));
      final nextDay = day.add(const Duration(days: 1));
      var secs = 0;
      var sessions = 0;

      for (final record in records) {
        if (record.log.type != SessionType.focus) continue;
        final dt = DateTime.fromMillisecondsSinceEpoch(
          record.log.startEpoch * 1000,
        );
        if (!dt.isBefore(day) && dt.isBefore(nextDay)) {
          secs += record.log.durationSeconds;
          if (record.log.result == SessionResult.completed) {
            sessions++;
          }
        }
      }

      final isToday = offset == 0;
      final label = isToday ? '今日' : '${day.month}/${day.day}';
      buckets.add(
        DailyFocusBucket(
          day: day,
          label: label,
          isToday: isToday,
          focusSeconds: secs,
          focusSessions: sessions,
        ),
      );
    }

    return List<DailyFocusBucket>.unmodifiable(buckets);
  }
}

final historyControllerProvider =
    NotifierProvider<HistoryController, HistoryState>(HistoryController.new);
