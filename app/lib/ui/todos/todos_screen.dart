import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/protocol/packet_envelope.dart';
import '../../core/protocol/protocol_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/todo_item.dart';
import '../../state/todo_controller.dart';

/// Enforces `docs/spec.md` §6.1 printable ASCII input (`0x20..0x7E`) at the
/// text-field layer.
final TextInputFormatter todoAsciiInputFormatter =
    FilteringTextInputFormatter.allow(RegExp(r'[\x20-\x7E]'));

/// To-Do list management screen synced with ESP32 NVS (`cmd 200~205`).
class TodosScreen extends ConsumerWidget {
  const TodosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(todoControllerProvider);
    final controller = ref.read(todoControllerProvider.notifier);
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                key: const Key('badge_todo_capacity'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: state.isFull
                        ? AppColors.signalWarn
                        : AppColors.border,
                  ),
                ),
                child: Text(
                  '${state.items.length} / ${state.maxCount} 筆',
                  style: textTheme.labelMedium?.copyWith(
                    color: state.isFull ? AppColors.signalWarn : AppColors.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('btn_refresh_todos'),
                tooltip: '重新讀取清單',
                onPressed: state.isLocked ? null : controller.loadTodos,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const Key('btn_add_todo'),
                onPressed: state.isLocked || state.isFull
                    ? null
                    : () => _openTitleDialog(
                          context: context,
                          dialogTitle: '新增待辦事項',
                          onSubmit: controller.addTodo,
                        ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(state.isFull ? '已達上限' : '新增待辦'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.ink,
                  foregroundColor: AppColors.surface,
                ),
              ),
            ],
          ),
          if (state.errorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
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
                      state.errorMessage!,
                      style: textTheme.bodyMedium?.copyWith(
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
          ],
          const SizedBox(height: 8),
          Text(
            '標題限 1~24 字元純 ASCII；拖曳右側把手可同步調整裝置顯示順序。',
            style: textTheme.bodyMedium?.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: state.items.isEmpty
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceRecessed,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        const Icon(
                          Icons.checklist_rounded,
                          size: 36,
                          color: AppColors.inkMuted,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '尚無待辦事項',
                          style: textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '點擊右上角「新增待辦」寫入裝置（最多 10 筆）。',
                          style: textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: state.items.length,
                    onReorderItem: (oldIndex, targetIndex) {
                      controller.moveTodo(oldIndex, targetIndex);
                    },
                    itemBuilder: (context, index) {
                      final item = state.items[index];
                      return _TodoRowCard(
                        key: ValueKey<int>(item.id),
                        index: index,
                        item: item,
                        locked: state.isLocked,
                        onToggleDone: (checked) {
                          controller.updateTodo(
                            index: index,
                            done: checked,
                          );
                        },
                        onEdit: () => _openTitleDialog(
                          context: context,
                          dialogTitle: '編輯待辦事項',
                          initialValue: item.title,
                          onSubmit: (title) => controller.updateTodo(
                            index: index,
                            title: title,
                          ),
                        ),
                        onDelete: () => controller.deleteTodo(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openTitleDialog({
    required BuildContext context,
    required String dialogTitle,
    String initialValue = '',
    required Future<bool> Function(String title) onSubmit,
  }) async {
    final textController = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final trimmed = textController.text.trim();
            final canSave = AsciiValidator.isValidTodoTitle(trimmed);

            return AlertDialog(
              title: Text(dialogTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    key: const Key('input_todo_title'),
                    controller: textController,
                    autofocus: true,
                    maxLength: BleProtocolConstants.maxTodoTitleLength,
                    inputFormatters: <TextInputFormatter>[
                      todoAsciiInputFormatter,
                    ],
                    decoration: const InputDecoration(
                      hintText: 'e.g. Write Report',
                      helperText: '僅限半形英數符號 (ASCII)，1~24 字元',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                    onSubmitted: (_) {
                      if (canSave) {
                        Navigator.of(dialogContext).pop(trimmed);
                      }
                    },
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  key: const Key('btn_cancel_todo_dialog'),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const Key('btn_save_todo_dialog'),
                  onPressed: canSave
                      ? () => Navigator.of(dialogContext).pop(trimmed)
                      : null,
                  child: const Text('儲存'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      await onSubmit(result);
    }
  }
}

class _TodoRowCard extends StatelessWidget {
  const _TodoRowCard({
    super.key,
    required this.index,
    required this.item,
    required this.locked,
    required this.onToggleDone,
    required this.onEdit,
    required this.onDelete,
  });

  final int index;
  final TodoItem item;
  final bool locked;
  final ValueChanged<bool> onToggleDone;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: <Widget>[
              Checkbox(
                key: Key('todo_check_${item.id}'),
                value: item.done,
                onChanged: locked ? null : (val) => onToggleDone(val ?? false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.title,
                      style: textTheme.bodyLarge?.copyWith(
                        decoration:
                            item.done ? TextDecoration.lineThrough : null,
                        color: item.done ? AppColors.inkMuted : AppColors.ink,
                      ),
                    ),
                    Text(
                      '#${item.id}',
                      style: textTheme.labelMedium?.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('todo_edit_${item.id}'),
                tooltip: '編輯',
                onPressed: locked ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 19),
              ),
              IconButton(
                key: Key('todo_delete_${item.id}'),
                tooltip: '刪除',
                onPressed: locked ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
              ),
              ReorderableDragStartListener(
                index: index,
                enabled: !locked,
                child: Semantics(
                  label: '拖曳排序 ${item.title}',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      key: Key('todo_drag_${item.id}'),
                      color: locked ? AppColors.border : AppColors.inkMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
