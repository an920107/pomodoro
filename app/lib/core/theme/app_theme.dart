import 'package:material_ui/material_ui.dart';

/// Color tokens for the "Matte Desk Instrument" visual system.
abstract final class AppColors {
  static const Color canvas = Color(0xFFF5F6F7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceRecessed = Color(0xFFEBEEF2);
  static const Color border = Color(0xFFD8DEE6);
  static const Color ink = Color(0xFF14191F);
  static const Color inkMuted = Color(0xFF5A6572);

  static const Color signalFocus = Color(0xFFE03E2D);
  static const Color signalBreak = Color(0xFF1F7A5C);
  static const Color signalWarn = Color(0xFFC87A19);
}

/// Application-wide Material theme configured for clean contrast and
/// tabular numerals on physical timer displays.
abstract final class AppTheme {
  static ThemeData light() {
    const tabular = <FontFeature>[FontFeature.tabularFigures()];

    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.signalFocus,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
    ).copyWith(
      primary: AppColors.signalFocus,
      onPrimary: AppColors.surface,
      secondary: AppColors.signalBreak,
      onSecondary: AppColors.surface,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      outline: AppColors.border,
    );

    const baseTextTheme = TextTheme(
      displayLarge: TextStyle(
        fontSize: 52,
        fontWeight: FontWeight.w600,
        letterSpacing: -1.5,
        color: AppColors.ink,
        fontFeatures: tabular,
      ),
      displayMedium: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.8,
        color: AppColors.ink,
        fontFeatures: tabular,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: AppColors.ink,
        fontFeatures: tabular,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
        fontFeatures: tabular,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        height: 1.45,
        color: AppColors.ink,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.45,
        color: AppColors.inkMuted,
        fontFeatures: tabular,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.inkMuted,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.canvas,
      textTheme: baseTextTheme,
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.ink,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.ink,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        elevation: 0,
        height: 68,
        indicatorColor: AppColors.surfaceRecessed,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? AppColors.ink : AppColors.inkMuted,
            size: 22,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? AppColors.ink : AppColors.inkMuted,
          );
        }),
      ),
    );
  }
}
