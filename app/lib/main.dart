import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'core/logging/app_logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.instance.app('Smart Pomodoro shell initialized');
  runApp(const ProviderScope(child: PomodoroApp()));
}
