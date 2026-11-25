import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/protocol/protocol_constants.dart';
import '../models/session_log.dart';
import '../models/todo_item.dart';

/// Persisted session log joined with historical To-Do title metadata.
class SessionLogRecord {
  const SessionLogRecord({
    required this.log,
    required this.rawStartEpoch,
    required this.syncedAtEpoch,
    this.cachedTodoTitle,
  });

  final SessionLog log;
  final int rawStartEpoch;
  final int syncedAtEpoch;
  final String? cachedTodoTitle;

  /// Human-readable task label preserved even if the ESP32 To-Do was deleted.
  String get displayTodoTitle {
    if (log.todoId == BleProtocolConstants.unboundTodoId) {
      return '自由專注';
    }
    final title = cachedTodoTitle?.trim();
    if (title != null && title.isNotEmpty) {
      return title;
    }
    return '待辦 #${log.todoId}';
  }
}

/// Database abstraction for Pomodoro session history and historical To-Do cache.
abstract class AppDatabase {
  /// Inserts [rawLog] idempotently using `(log_id, raw_start_epoch, duration_sec, type, result)`.
  ///
  /// When `rawLog.startEpoch == 0`, estimates start time from [nowEpochSeconds]
  /// and marks `isEstimatedTime = true`.
  /// Returns `true` if a new row was inserted, or `false` if deduplicated.
  Future<bool> insertSessionLogIdempotent(
    SessionLog rawLog, {
    required int nowEpochSeconds,
  });

  /// Stores or updates a single known To-Do title for historical stats lookup.
  Future<void> upsertKnownTodo(TodoItem todo, {int? nowEpochSeconds});

  /// Stores or updates known To-Do titles without deleting older entries.
  Future<void> upsertKnownTodos(List<TodoItem> todos, {int? nowEpochSeconds});

  /// Returns all synced session logs ordered newest-first.
  Future<List<SessionLogRecord>> fetchAllSessionLogs();

  /// Closes any open underlying database handles.
  Future<void> close();
}

/// SQLite-backed [AppDatabase] persisted to `pomodoro.db` on device storage.
class SqliteAppDatabase implements AppDatabase {
  SqliteAppDatabase._(this._db);

  static const String databaseFileName = 'pomodoro.db';
  static const int _schemaVersion = 1;

  final Database _db;

  /// Opens (and initializes if needed) the SQLite database.
  static Future<SqliteAppDatabase> open({String? databasePath}) async {
    final resolvedPath =
        databasePath ?? p.join(await getDatabasesPath(), databaseFileName);
    final db = await openDatabase(
      resolvedPath,
      version: _schemaVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE session_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            log_id INTEGER NOT NULL,
            raw_start_epoch INTEGER NOT NULL,
            start_epoch INTEGER NOT NULL,
            duration_sec INTEGER NOT NULL,
            type INTEGER NOT NULL,
            result INTEGER NOT NULL,
            todo_id INTEGER NOT NULL,
            todo_title_snapshot TEXT,
            is_estimated_time INTEGER NOT NULL DEFAULT 0,
            synced_at_epoch INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE UNIQUE INDEX idx_session_logs_unique
          ON session_logs (log_id, raw_start_epoch, duration_sec, type, result)
        ''');
        await db.execute('''
          CREATE INDEX idx_session_logs_start_epoch
          ON session_logs (start_epoch DESC)
        ''');
        await db.execute('''
          CREATE TABLE known_todos (
            todo_id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            updated_at_epoch INTEGER NOT NULL
          )
        ''');
      },
    );
    return SqliteAppDatabase._(db);
  }

  @override
  Future<bool> insertSessionLogIdempotent(
    SessionLog rawLog, {
    required int nowEpochSeconds,
  }) async {
    String? titleSnapshot;
    if (rawLog.todoId != BleProtocolConstants.unboundTodoId) {
      final knownRows = await _db.query(
        'known_todos',
        columns: ['title'],
        where: 'todo_id = ?',
        whereArgs: [rawLog.todoId],
        limit: 1,
      );
      if (knownRows.isNotEmpty) {
        titleSnapshot = knownRows.first['title'] as String?;
      }
    }

    final resolved = rawLog.resolveReceivedTimestamp(nowEpochSeconds);
    final insertedId = await _db.insert('session_logs', {
      'log_id': resolved.logId,
      'raw_start_epoch': rawLog.startEpoch,
      'start_epoch': resolved.startEpoch,
      'duration_sec': resolved.durationSeconds,
      'type': resolved.type.code,
      'result': resolved.result.code,
      'todo_id': resolved.todoId,
      'todo_title_snapshot': titleSnapshot,
      'is_estimated_time': resolved.isEstimatedTime ? 1 : 0,
      'synced_at_epoch': nowEpochSeconds,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return insertedId > 0;
  }

  @override
  Future<void> upsertKnownTodo(TodoItem todo, {int? nowEpochSeconds}) async {
    final now =
        nowEpochSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.insert('known_todos', {
      'todo_id': todo.id,
      'title': todo.title,
      'updated_at_epoch': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> upsertKnownTodos(
    List<TodoItem> todos, {
    int? nowEpochSeconds,
  }) async {
    if (todos.isEmpty) return;
    final now =
        nowEpochSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final batch = _db.batch();
    for (final todo in todos) {
      batch.insert('known_todos', {
        'todo_id': todo.id,
        'title': todo.title,
        'updated_at_epoch': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<SessionLogRecord>> fetchAllSessionLogs() async {
    final rows = await _db.rawQuery('''
      SELECT
        s.log_id,
        s.raw_start_epoch,
        s.start_epoch,
        s.duration_sec,
        s.type,
        s.result,
        s.todo_id,
        s.is_estimated_time,
        s.synced_at_epoch,
        COALESCE(NULLIF(s.todo_title_snapshot, ''), k.title) AS resolved_title
      FROM session_logs s
      LEFT JOIN known_todos k ON k.todo_id = s.todo_id
      ORDER BY s.start_epoch DESC, s.id DESC
    ''');

    return rows
        .map(
          (row) => SessionLogRecord(
            log: SessionLog(
              logId: (row['log_id'] as num).toInt(),
              startEpoch: (row['start_epoch'] as num).toInt(),
              durationSeconds: (row['duration_sec'] as num).toInt(),
              type: SessionType.fromCode((row['type'] as num).toInt()),
              result: SessionResult.fromCode((row['result'] as num).toInt()),
              todoId: (row['todo_id'] as num).toInt(),
              isEstimatedTime: (row['is_estimated_time'] as num).toInt() == 1,
            ),
            rawStartEpoch: (row['raw_start_epoch'] as num).toInt(),
            syncedAtEpoch: (row['synced_at_epoch'] as num).toInt(),
            cachedTodoTitle: row['resolved_title'] as String?,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> close() async {
    await _db.close();
  }
}

/// Ephemeral in-memory [AppDatabase] for unit and widget tests without SQLite plugins.
class InMemoryAppDatabase implements AppDatabase {
  final List<_InMemoryLogRow> _logs = [];
  final Map<int, String> _knownTodos = {};

  @override
  Future<bool> insertSessionLogIdempotent(
    SessionLog rawLog, {
    required int nowEpochSeconds,
  }) async {
    final isDuplicate = _logs.any(
      (existing) =>
          existing.log.logId == rawLog.logId &&
          existing.rawStartEpoch == rawLog.startEpoch &&
          existing.log.durationSeconds == rawLog.durationSeconds &&
          existing.log.type == rawLog.type &&
          existing.log.result == rawLog.result,
    );
    if (isDuplicate) return false;

    final snapshot = rawLog.todoId == BleProtocolConstants.unboundTodoId
        ? null
        : _knownTodos[rawLog.todoId];
    final resolved = rawLog.resolveReceivedTimestamp(nowEpochSeconds);
    _logs.add(
      _InMemoryLogRow(
        log: resolved,
        rawStartEpoch: rawLog.startEpoch,
        syncedAtEpoch: nowEpochSeconds,
        titleSnapshot: snapshot,
      ),
    );
    return true;
  }

  @override
  Future<void> upsertKnownTodo(TodoItem todo, {int? nowEpochSeconds}) async {
    _knownTodos[todo.id] = todo.title;
  }

  @override
  Future<void> upsertKnownTodos(
    List<TodoItem> todos, {
    int? nowEpochSeconds,
  }) async {
    for (final todo in todos) {
      _knownTodos[todo.id] = todo.title;
    }
  }

  @override
  Future<List<SessionLogRecord>> fetchAllSessionLogs() async {
    final indexed = _logs.asMap().entries.toList()
      ..sort((a, b) {
        final cmp = b.value.log.startEpoch.compareTo(a.value.log.startEpoch);
        if (cmp != 0) return cmp;
        return b.key.compareTo(a.key);
      });

    return indexed
        .map((entry) {
          final row = entry.value;
          final resolvedTitle =
              (row.titleSnapshot != null && row.titleSnapshot!.isNotEmpty)
              ? row.titleSnapshot
              : _knownTodos[row.log.todoId];
          return SessionLogRecord(
            log: row.log,
            rawStartEpoch: row.rawStartEpoch,
            syncedAtEpoch: row.syncedAtEpoch,
            cachedTodoTitle: resolvedTitle,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> close() async {}
}

class _InMemoryLogRow {
  const _InMemoryLogRow({
    required this.log,
    required this.rawStartEpoch,
    required this.syncedAtEpoch,
    this.titleSnapshot,
  });

  final SessionLog log;
  final int rawStartEpoch;
  final int syncedAtEpoch;
  final String? titleSnapshot;
}
