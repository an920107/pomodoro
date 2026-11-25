import '../../core/protocol/protocol_exceptions.dart';

/// Single To-Do entry stored on ESP32 (`CMD_TODO_GET 201`).
class TodoItem {
  const TodoItem({
    required this.index,
    required this.id,
    required this.title,
    required this.done,
  });

  factory TodoItem.fromData(Map<String, dynamic> data) {
    final index = data['i'];
    final id = data['id'];
    final title = data['t'];
    final done = data['d'];

    if (index is! int || id is! int || title is! String || done is! bool) {
      throw const PacketValidationException('Invalid CMD_TODO_GET payload');
    }

    return TodoItem(
      index: index,
      id: id,
      title: title,
      done: done,
    );
  }

  final int index;
  final int id;
  final String title;
  final bool done;

  Map<String, dynamic> toData() => <String, dynamic>{
        'i': index,
        'id': id,
        't': title,
        'd': done,
      };

  TodoItem copyWith({
    int? index,
    int? id,
    String? title,
    bool? done,
  }) {
    return TodoItem(
      index: index ?? this.index,
      id: id ?? this.id,
      title: title ?? this.title,
      done: done ?? this.done,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TodoItem &&
        other.index == index &&
        other.id == id &&
        other.title == title &&
        other.done == done;
  }

  @override
  int get hashCode => Object.hash(index, id, title, done);

  @override
  String toString() =>
      'TodoItem(i: $index, id: $id, t: "$title", d: $done)';
}

/// Response metadata for `CMD_TODO_GET_LEN (200)`.
class TodoListMeta {
  const TodoListMeta({
    required this.length,
    required this.max,
  });

  factory TodoListMeta.fromData(Map<String, dynamic> data) {
    final len = data['len'];
    final max = data['max'];
    if (len is! int || max is! int) {
      throw const PacketValidationException(
        'Invalid CMD_TODO_GET_LEN payload',
      );
    }
    return TodoListMeta(length: len, max: max);
  }

  final int length;
  final int max;

  Map<String, dynamic> toData() => <String, dynamic>{
        'len': length,
        'max': max,
      };
}

/// Response metadata for `CMD_TODO_APPEND (202)`.
class TodoAppendResult {
  const TodoAppendResult({
    required this.index,
    required this.id,
    required this.length,
  });

  factory TodoAppendResult.fromData(Map<String, dynamic> data) {
    final index = data['i'];
    final id = data['id'];
    final len = data['len'];
    if (index is! int || id is! int || len is! int) {
      throw const PacketValidationException(
        'Invalid CMD_TODO_APPEND payload',
      );
    }
    return TodoAppendResult(index: index, id: id, length: len);
  }

  final int index;
  final int id;
  final int length;

  Map<String, dynamic> toData() => <String, dynamic>{
        'i': index,
        'id': id,
        'len': length,
      };
}
