import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pomodoro/core/logging/app_logger.dart';
import 'package:pomodoro/data/ble/mock_ble_repository.dart';
import 'package:pomodoro/data/ble/mock_nvs_store.dart';
import 'package:pomodoro/data/local/preferences_store.dart';
import 'package:pomodoro/state/ble_providers.dart';
import 'package:pomodoro/state/todo_controller.dart';

void main() {
  group('Adjacent swap conversion for CMD_TODO_SWAP (205)', () {
    test('normalizes ReorderableListView indices and builds adjacent pairs', () {
      expect(normalizeReorderIndex(0, 4), 3);
      expect(normalizeReorderIndex(3, 1), 1);

      expect(buildAdjacentSwapSequence(0, 3), <(int, int)>[
        (0, 1),
        (1, 2),
        (2, 3),
      ]);
      expect(buildAdjacentSwapSequence(3, 0), <(int, int)>[
        (3, 2),
        (2, 1),
        (1, 0),
      ]);
      expect(buildAdjacentSwapSequence(2, 2), isEmpty);
    });

    test('matches List.removeAt/insert semantics for every move on 6 items', () {
      const seed = <String>['A', 'B', 'C', 'D', 'E', 'F'];

      for (var oldIndex = 0; oldIndex < seed.length; oldIndex++) {
        for (var newIndex = 0; newIndex <= seed.length; newIndex++) {
          final targetIndex = normalizeReorderIndex(oldIndex, newIndex);
          final expected = List<String>.from(seed);
          final item = expected.removeAt(oldIndex);
          expected.insert(targetIndex, item);

          final actual = List<String>.from(seed);
          for (final step in buildAdjacentSwapSequence(oldIndex, targetIndex)) {
            final tmp = actual[step.$1];
            actual[step.$1] = actual[step.$2];
            actual[step.$2] = tmp;
          }

          expect(
            actual,
            expected,
            reason: 'Failed for oldIndex=$oldIndex newIndex=$newIndex',
          );
        }
      }
    });

    test('TodoController emits sequential cmd 205 swaps matching Mock NVS',
        () async {
      final logger = AppLogger(printer: (_) {});
      final mockRepo = MockBleRepository(
        nvsStore: InMemoryMockNvsStore(),
        logger: logger,
      );
      final container = ProviderContainer(
        overrides: [
          preferencesStoreProvider.overrideWithValue(
            InMemoryPreferencesStore(isDebugMode: true, isMockBleMode: true),
          ),
          mockBleRepositoryProvider.overrideWithValue(mockRepo),
        ],
      );
      addTearDown(() {
        container.dispose();
        mockRepo.dispose();
        logger.dispose();
      });

      final controller = container.read(todoControllerProvider.notifier);
      await controller.loadTodos();
      await controller.addTodo('Task Three');
      await controller.addTodo('Task Four');

      logger.clear();
      // Move index 0 ('Read Embedded Spec') to the end (newIndex=4 -> target=3).
      final ok = await controller.reorderTodos(0, 4);
      expect(ok, isTrue);

      final txLines = logger.entries
          .where((e) => e.category == LogCategory.bleTx)
          .map((e) => e.message)
          .toList();
      expect(txLines, <String>[
        '{"cmd":205,"data":{"i":0,"j":1}}',
        '{"cmd":205,"data":{"i":1,"j":2}}',
        '{"cmd":205,"data":{"i":2,"j":3}}',
      ]);

      final state = container.read(todoControllerProvider);
      expect(state.items.map((t) => t.title).toList(), <String>[
        'Verify BLE Protocol',
        'Task Three',
        'Task Four',
        'Read Embedded Spec',
      ]);

      // Confirm ESP32 mock side matches element-for-element.
      for (var i = 0; i < 4; i++) {
        final deviceItem = await mockRepo.getTodoItem(i);
        expect(deviceItem.title, state.items[i].title);
        expect(deviceItem.id, state.items[i].id);
      }
    });
  });
}
