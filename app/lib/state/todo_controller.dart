import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/protocol/packet_envelope.dart';
import '../core/protocol/protocol_constants.dart';
import '../core/protocol/protocol_exceptions.dart';
import '../data/ble/ble_repository.dart';
import '../data/models/todo_item.dart';
import 'ble_providers.dart';

/// Converts Flutter [ReorderableListView] `(oldIndex, newIndex)` into the
/// final 0-based target index after moving the item.
int normalizeReorderIndex(int oldIndex, int newIndex) {
  return newIndex > oldIndex ? newIndex - 1 : newIndex;
}

/// Converts a list move from [fromIndex] to [toIndex] into sequential adjacent
/// `CMD_TODO_SWAP (205)` index pairs so the ESP32 NVS order matches
/// [ReorderableListView] insertion semantics 1-to-1.
List<(int, int)> buildAdjacentSwapSequence(int fromIndex, int toIndex) {
  if (fromIndex == toIndex) return const <(int, int)>[];
  final swaps = <(int, int)>[];
  if (fromIndex < toIndex) {
    for (var i = fromIndex; i < toIndex; i++) {
      swaps.add((i, i + 1));
    }
  } else {
    for (var i = fromIndex; i > toIndex; i--) {
      swaps.add((i, i - 1));
    }
  }
  return List<(int, int)>.unmodifiable(swaps);
}

/// Immutable state for the device-synced To-Do list (`cmd 200~205`).
class TodoListState {
  const TodoListState({
    this.items = const <TodoItem>[],
    this.maxCount = BleProtocolConstants.maxTodos,
    this.isConnected = false,
    this.isLoading = false,
    this.isMutating = false,
    this.errorMessage,
  });

  final List<TodoItem> items;
  final int maxCount;
  final bool isConnected;
  final bool isLoading;
  final bool isMutating;
  final String? errorMessage;

  bool get isLocked => !isConnected || isLoading || isMutating;

  bool get isFull => items.length >= maxCount;

  TodoListState copyWith({
    List<TodoItem>? items,
    int? maxCount,
    bool? isConnected,
    bool? isLoading,
    bool? isMutating,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TodoListState(
      items: items ?? this.items,
      maxCount: maxCount ?? this.maxCount,
      isConnected: isConnected ?? this.isConnected,
      isLoading: isLoading ?? this.isLoading,
      isMutating: isMutating ?? this.isMutating,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Manages To-Do CRUD (`cmd 200~204`) and drag-reorder swaps (`cmd 205`).
class TodoController extends Notifier<TodoListState> {
  StreamSubscription<BleConnectionSnapshot>? _connectionSub;
  bool _disposed = false;
  late bool _wasConnected;

  @override
  TodoListState build() {
    _disposed = false;
    final repo = ref.watch(bleRepositoryProvider);
    _wasConnected = repo.currentConnection.state.isConnected;

    _connectionSub?.cancel();
    _connectionSub = repo.connectionStream.listen(_onConnectionChanged);

    ref.onDispose(() {
      _disposed = true;
      _connectionSub?.cancel();
    });

    if (_wasConnected) {
      Future<void>.microtask(loadTodos);
    }

    return TodoListState(isConnected: _wasConnected);
  }

  void clearError() {
    if (state.errorMessage == null) return;
    state = state.copyWith(clearError: true);
  }

  Future<void> loadTodos() async {
    if (_disposed) return;
    final repo = ref.read(bleRepositoryProvider);
    if (!repo.currentConnection.state.isConnected) return;

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final meta = await repo.getTodoLength();
      final loaded = <TodoItem>[];
      for (var i = 0; i < meta.length; i++) {
        loaded.add(await repo.getTodoItem(i));
      }
      if (_disposed) return;
      state = state.copyWith(
        items: List<TodoItem>.unmodifiable(loaded),
        maxCount: meta.max,
        isLoading: false,
      );
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return;
      state = state.copyWith(isLoading: false, errorMessage: e.message);
    }
  }

  Future<bool> addTodo(String rawTitle) async {
    final title = rawTitle.trim();
    try {
      AsciiValidator.validateTodoTitle(title);
    } on PacketValidationException {
      state = state.copyWith(errorMessage: ErrCode.todoInvalidTitle.message);
      return false;
    }

    if (state.isFull) {
      state = state.copyWith(errorMessage: ErrCode.todoFull.message);
      return false;
    }
    if (state.isLocked) return false;

    final repo = ref.read(bleRepositoryProvider);
    state = state.copyWith(isMutating: true, clearError: true);
    try {
      final res = await repo.appendTodo(title);
      if (_disposed) return false;
      final updated = List<TodoItem>.from(state.items)
        ..add(TodoItem(index: res.index, id: res.id, title: title, done: false));
      state = state.copyWith(
        items: List<TodoItem>.unmodifiable(_reindexed(updated)),
        isMutating: false,
      );
      return true;
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return false;
      state = state.copyWith(isMutating: false, errorMessage: e.message);
      return false;
    }
  }

  Future<bool> updateTodo({
    required int index,
    String? title,
    bool? done,
  }) async {
    if (state.isLocked) return false;
    if (index < 0 || index >= state.items.length) return false;

    String? normalizedTitle;
    if (title != null) {
      normalizedTitle = title.trim();
      try {
        AsciiValidator.validateTodoTitle(normalizedTitle);
      } on PacketValidationException {
        state = state.copyWith(errorMessage: ErrCode.todoInvalidTitle.message);
        return false;
      }
    }

    final repo = ref.read(bleRepositoryProvider);
    state = state.copyWith(isMutating: true, clearError: true);
    try {
      await repo.updateTodo(index: index, title: normalizedTitle, done: done);
      if (_disposed) return false;
      final updated = List<TodoItem>.from(state.items);
      updated[index] = updated[index].copyWith(
        title: normalizedTitle,
        done: done,
      );
      state = state.copyWith(
        items: List<TodoItem>.unmodifiable(updated),
        isMutating: false,
      );
      return true;
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return false;
      state = state.copyWith(isMutating: false, errorMessage: e.message);
      return false;
    }
  }

  Future<bool> deleteTodo(int index) async {
    if (state.isLocked) return false;
    if (index < 0 || index >= state.items.length) return false;

    final repo = ref.read(bleRepositoryProvider);
    state = state.copyWith(isMutating: true, clearError: true);
    try {
      await repo.deleteTodo(index);
      if (_disposed) return false;
      final updated = List<TodoItem>.from(state.items)..removeAt(index);
      state = state.copyWith(
        items: List<TodoItem>.unmodifiable(_reindexed(updated)),
        isMutating: false,
      );
      return true;
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return false;
      state = state.copyWith(isMutating: false, errorMessage: e.message);
      return false;
    }
  }

  Future<bool> reorderTodos(int oldIndex, int newIndex) {
    return moveTodo(oldIndex, normalizeReorderIndex(oldIndex, newIndex));
  }

  Future<bool> moveTodo(int oldIndex, int targetIndex) async {
    if (state.isLocked) return false;
    if (oldIndex < 0 ||
        oldIndex >= state.items.length ||
        targetIndex < 0 ||
        targetIndex >= state.items.length ||
        oldIndex == targetIndex) {
      return true;
    }

    final swaps = buildAdjacentSwapSequence(oldIndex, targetIndex);
    final optimistic = List<TodoItem>.from(state.items);
    final moved = optimistic.removeAt(oldIndex);
    optimistic.insert(targetIndex, moved);

    state = state.copyWith(
      items: List<TodoItem>.unmodifiable(_reindexed(optimistic)),
      isMutating: true,
      clearError: true,
    );

    final repo = ref.read(bleRepositoryProvider);
    try {
      for (final step in swaps) {
        await repo.swapTodos(step.$1, step.$2);
      }
      if (_disposed) return false;
      state = state.copyWith(isMutating: false);
      return true;
    } on PomodoroProtocolException catch (e) {
      if (_disposed) return false;
      state = state.copyWith(isMutating: false, errorMessage: e.message);
      await loadTodos();
      return false;
    }
  }

  void _onConnectionChanged(BleConnectionSnapshot snapshot) {
    if (_disposed) return;
    final isNowConnected = snapshot.state.isConnected;
    final transitionedToConnected = !_wasConnected && isNowConnected;
    _wasConnected = isNowConnected;

    state = state.copyWith(isConnected: isNowConnected);
    if (transitionedToConnected) {
      unawaited(loadTodos());
    }
  }

  static List<TodoItem> _reindexed(List<TodoItem> list) {
    return <TodoItem>[
      for (var i = 0; i < list.length; i++)
        list[i].index == i ? list[i] : list[i].copyWith(index: i),
    ];
  }
}

final todoControllerProvider =
    NotifierProvider<TodoController, TodoListState>(
  TodoController.new,
);
