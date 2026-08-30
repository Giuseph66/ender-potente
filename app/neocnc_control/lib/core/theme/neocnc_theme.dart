import 'package:flutter/material.dart';

abstract final class NeoCncColors {
  static const canvas = Color(0xFF0B1015);
  static const surface = Color(0xFF121A21);
  static const panel = Color(0xFF17222B);
  static const line = Color(0xFF2C3A45);
  static const amber = Color(0xFFFFB703);
  static const cyan = Color(0xFF67D8CC);
  static const ink = Color(0xFFE6EDF3);
  static const muted = Color(0xFF91A4B3);
  static const danger = Color(0xFFFF5C5C);
}

abstract final class NeoCncTheme {
  static ThemeData dark() {
    const colorScheme = ColorScheme.dark(
      primary: NeoCncColors.amber,
      secondary: NeoCncColors.cyan,
      surface: NeoCncColors.surface,
      error: NeoCncColors.danger,
      onPrimary: Color(0xFF201800),
      onSecondary: Color(0xFF00201C),
      onSurface: NeoCncColors.ink,
      onError: Color(0xFF300000),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: NeoCncColors.canvas,
      fontFamily: 'monospace',
      dividerColor: NeoCncColors.line,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: NeoCncColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: NeoCncColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: NeoCncColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: NeoCncColors.amber, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: NeoCncColors.ink,
          side: const BorderSide(color: NeoCncColors.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        ),
      ),
    );
  }
}
