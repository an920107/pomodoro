import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/logging/app_logger.dart';
import 'data/ble/mock_nvs_store.dart';
import 'data/local/app_database.dart';
import 'data/local/preferences_store.dart';
import 'state/ble_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final database = await SqliteAppDatabase.open();
  AppLogger.instance.app('Smart Pomodoro shell initialized');
  runApp(
    ProviderScope(
      overrides: [
        mockNvsStoreProvider.overrideWith(
          (_) => SharedPreferencesMockNvsStore(prefs),
        ),
        preferencesStoreProvider.overrideWithValue(
          SharedPreferencesStore(prefs),
        ),
        appDatabaseProvider.overrideWithValue(database),
      ],
      child: const PomodoroApp(),
    ),
  );
}
