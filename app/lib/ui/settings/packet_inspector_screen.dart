import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../state/ble_providers.dart';

/// Live in-app inspector for structured BLE TX/RX packets, handshake sync steps,
/// and FocusGuard lifecycle logs stored in [AppLogger].
class PacketInspectorScreen extends ConsumerStatefulWidget {
  const PacketInspectorScreen({super.key});

  @override
  ConsumerState<PacketInspectorScreen> createState() =>
      _PacketInspectorScreenState();
}

class _PacketInspectorScreenState extends ConsumerState<PacketInspectorScreen> {
  final Set<LogCategory> _selectedCategories = <LogCategory>{};
  bool _newestFirst = true;

  AppLogger? _subscribedLogger;
  StreamSubscription<List<LogEntry>>? _logSub;
  List<LogEntry> _entries = const <LogEntry>[];

  @override
  void dispose() {
    _logSub?.cancel();
    super.dispose();
  }

  void _ensureSubscription(AppLogger logger) {
    if (identical(_subscribedLogger, logger)) return;
    _logSub?.cancel();
    _subscribedLogger = logger;
    _entries = logger.entries;
    _logSub = logger.stream.listen((List<LogEntry> next) {
      if (!mounted) return;
      setState(() {
        _entries = next;
      });
    });
  }

  List<LogEntry> get _filteredEntries {
    final Iterable<LogEntry> base = _selectedCategories.isEmpty
        ? _entries
        : _entries.where((entry) => _selectedCategories.contains(entry.category));
    final list = base.toList(growable: false);
    return _newestFirst ? list.reversed.toList(growable: false) : list;
  }

  Future<void> _copyFilteredLogs() async {
    final visible = _filteredEntries;
    if (visible.isEmpty) {
      _showSnackBar('目前無可複製的日誌');
      return;
    }
    final payload = visible.map((entry) => entry.format()).join('\n');
    await Clipboard.setData(ClipboardData(text: payload));
    if (!mounted) return;
    _showSnackBar('已複製 ${visible.length} 筆日誌');
  }

  void _clearLogs(AppLogger logger) {
    logger.clear();
    _showSnackBar('已清除日誌緩衝區');
  }

  void _showSnackBar(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final logger = ref.watch(appLoggerProvider);
    _ensureSubscription(logger);

    final filtered = _filteredEntries;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE 封包即時監看器'),
        actions: <Widget>[
          IconButton(
            key: const Key('btn_toggle_log_order'),
            tooltip: _newestFirst ? '最新置頂' : '依時間正序',
            onPressed: () {
              setState(() {
                _newestFirst = !_newestFirst;
              });
            },
            icon: Icon(
              _newestFirst
                  ? Icons.vertical_align_top_rounded
                  : Icons.vertical_align_bottom_rounded,
            ),
          ),
          IconButton(
            key: const Key('btn_copy_logs'),
            tooltip: '複製日誌',
            onPressed: _copyFilteredLogs,
            icon: const Icon(Icons.copy_all_rounded),
          ),
          IconButton(
            key: const Key('btn_clear_logs'),
            tooltip: '清除畫面',
            onPressed: () => _clearLogs(logger),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              color: AppColors.surface,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        FilterChip(
                          key: const Key('chip_log_filter_all'),
                          label: const Text('全部'),
                          selected: _selectedCategories.isEmpty,
                          onSelected: (_) {
                            setState(() {
                              _selectedCategories.clear();
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        for (final category in LogCategory.values) ...<Widget>[
                          FilterChip(
                            key: Key('chip_log_filter_${category.name}'),
                            label: Text(category.tag),
                            selected: _selectedCategories.contains(category),
                            onSelected: (bool selected) {
                              setState(() {
                                if (selected) {
                                  _selectedCategories.add(category);
                                } else {
                                  _selectedCategories.remove(category);
                                }
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '顯示 ${filtered.length} / ${_entries.length} 筆（上限 ${logger.maxEntries} 筆）',
                    key: const Key('txt_log_summary'),
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '目前尚無符合篩選條件的封包或系統日誌',
                          key: const Key('txt_logs_empty'),
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (BuildContext context, int index) {
                        final entry = filtered[index];
                        return _LogEntryTile(entry: entry);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogEntryTile extends StatelessWidget {
  const _LogEntryTile({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final accent = _accentForCategory(entry.category);
    final timeStr = _formatTime(entry.timestamp);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  entry.tag,
                  style: textTheme.labelSmall?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const Spacer(),
              Text(
                timeStr,
                style: textTheme.labelSmall?.copyWith(
                  color: AppColors.inkMuted,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            entry.message,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              height: 1.35,
              color: AppColors.ink,
            ),
          ),
        ],
      ),
    );
  }

  static Color _accentForCategory(LogCategory category) {
    return switch (category) {
      LogCategory.bleTx => AppColors.signalFocus,
      LogCategory.bleRx => AppColors.signalBreak,
      LogCategory.sync => AppColors.signalWarn,
      LogCategory.guard => AppColors.ink,
      LogCategory.app => AppColors.inkMuted,
    };
  }

  static String _formatTime(DateTime ts) {
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final ss = ts.second.toString().padLeft(2, '0');
    final ms = ts.millisecond.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$ms';
  }
}
