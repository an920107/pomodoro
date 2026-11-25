import 'package:material_ui/material_ui.dart';

import 'core/theme/app_theme.dart';
import 'ui/shell/main_shell_screen.dart';

/// Root widget for Smart Pomodoro (Phase 1).
class PomodoroApp extends StatelessWidget {
  const PomodoroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Pomodoro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const MainShellScreen(),
    );
  }
}
