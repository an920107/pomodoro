import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/logging/app_logger.dart';
import 'data/ble/mock_nvs_store.dart';
import 'state/ble_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  AppLogger.instance.app('Smart Pomodoro shell initialized');
  runApp(
    ProviderScope(
      overrides: [
        mockNvsStoreProvider.overrideWith(
          (_) => SharedPreferencesMockNvsStore(prefs),
        ),
      ],
      child: const PomodoroApp(),
    ),
  );
}
