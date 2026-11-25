import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_config.dart';
import '../models/session_log.dart';
import '../models/todo_item.dart';

/// Persisted snapshot of the virtual ESP32 NVS storage used by
/// [MockBleRepository].
class MockNvsSnapshot {
  MockNvsSnapshot({
    required this.config,
    List<TodoItem> todos = const <TodoItem>[],
    List<SessionLog> historyQueue = const <SessionLog>[],
    this.nextTodoId = 1,
    this.nextLogId = 1,
  })  : todos = List<TodoItem>.unmodifiable(todos),
        historyQueue = List<SessionLog>.unmodifiable(historyQueue);

  factory MockNvsSnapshot.initial() {
    return MockNvsSnapshot(
      config: const DeviceConfig.defaults(),
      todos: const <TodoItem>[
        TodoItem(index: 0, id: 1, title: 'Read Embedded Spec', done: false),
        TodoItem(index: 1, id: 2, title: 'Verify BLE Protocol', done: false),
      ],
      historyQueue: const <SessionLog>[],
      nextTodoId: 3,
      nextLogId: 1,
    );
  }

  factory MockNvsSnapshot.fromJson(Map<String, dynamic> json) {
    final rawConfig = json['config'];
    final config = rawConfig is Map
        ? DeviceConfig.fromData(Map<String, dynamic>.from(rawConfig))
        : const DeviceConfig.defaults();

    final rawTodos = json['todos'];
    final todos = <TodoItem>[];
    if (rawTodos is List) {
      for (var i = 0; i < rawTodos.length; i++) {
        final item = rawTodos[i];
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          map['i'] = i;
          todos.add(TodoItem.fromData(map));
        }
      }
    }

    final rawHistory = json['history'];
    final history = <SessionLog>[];
    if (rawHistory is List) {
      for (final item in rawHistory) {
        if (item is Map) {
          history.add(
            SessionLog.fromPeekData(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    final nextTodoId = json['next_todo_id'] is int
        ? json['next_todo_id'] as int
        : (todos.length + 1);
    final nextLogId =
        json['next_log_id'] is int ? json['next_log_id'] as int : 1;

    return MockNvsSnapshot(
      config: config,
      todos: todos,
      historyQueue: history,
      nextTodoId: nextTodoId,
      nextLogId: nextLogId,
    );
  }

  final DeviceConfig config;
  final List<TodoItem> todos;
  final List<SessionLog> historyQueue;
  final int nextTodoId;
  final int nextLogId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'config': config.toData(),
        'todos': todos.map((t) => t.toData()).toList(),
        'history': historyQueue.map((h) => h.toPeekData()).toList(),
        'next_todo_id': nextTodoId,
        'next_log_id': nextLogId,
      };
}

/// Storage abstraction for simulated ESP32 NVS persistence.
abstract interface class MockNvsStore {
  MockNvsSnapshot load();

  Future<void> save(MockNvsSnapshot snapshot);

  Future<void> clear();
}

/// In-memory NVS store suited for deterministic unit and widget tests.
class InMemoryMockNvsStore implements MockNvsStore {
  InMemoryMockNvsStore([MockNvsSnapshot? initial])
      : _snapshot = initial ?? MockNvsSnapshot.initial();

  MockNvsSnapshot _snapshot;

  @override
  MockNvsSnapshot load() => _snapshot;

  @override
  Future<void> save(MockNvsSnapshot snapshot) async {
    _snapshot = snapshot;
  }

  @override
  Future<void> clear() async {
    _snapshot = MockNvsSnapshot.initial();
  }
}

/// SharedPreferences-backed NVS store so simulated device settings, To-Do order,
/// and unsynced offline logs persist across simulated power cycles and app cold restarts.
class SharedPreferencesMockNvsStore implements MockNvsStore {
  SharedPreferencesMockNvsStore(
    this._prefs, {
    this.storageKey = defaultStorageKey,
  });

  static const String defaultStorageKey = 'mock_nvs_state_v1';

  final SharedPreferences _prefs;
  final String storageKey;

  @override
  MockNvsSnapshot load() {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) {
      return MockNvsSnapshot.initial();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return MockNvsSnapshot.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // Corrupt mock snapshot falls back cleanly to defaults.
    }
    return MockNvsSnapshot.initial();
  }

  @override
  Future<void> save(MockNvsSnapshot snapshot) async {
    await _prefs.setString(storageKey, jsonEncode(snapshot.toJson()));
  }

  @override
  Future<void> clear() async {
    await _prefs.remove(storageKey);
  }
}
