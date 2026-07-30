import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static const fabBackground = Color(0xAA000000);
  static const dialogBackground = Color(0xFF2A2A2A);

  static const textPrimary = Colors.white;
  static const textSecondary = Colors.white70;
  static const textMuted = Colors.white54;
  static const textDisabled = Colors.white38;
  static const textFaint = Colors.white24;

  static const success = Colors.greenAccent;
  static const danger = Colors.redAccent;
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: Brightness.dark,
      surface: const Color(0xFF121212),
      error: AppColors.danger,
    ),
    scaffoldBackgroundColor: const Color(0xFF121212),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1E1E1E),
      foregroundColor: Colors.white,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.dialogBackground,
    ),
  );
}
