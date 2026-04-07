import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

ThemeData buildAppTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  const lightBase = Color(0xFF123B72);
  const lightAccent = Color(0xFF2F6FDE);
  const lightPaper = Color(0xFFF4F8FD);
  const darkBase = Color(0xFF8AB4FF);
  const darkAccent = Color(0xFF4E8DFF);
  const darkPaper = Color(0xFF08111D);
  final base = isDark ? darkBase : lightBase;
  final accent = isDark ? darkAccent : lightAccent;
  final paper = isDark ? darkPaper : lightPaper;
  final card = isDark ? const Color(0xFF101B2A) : Colors.white;
  final inputFill = isDark ? const Color(0xFF132033) : Colors.white;
  final chipBackground = isDark
      ? const Color(0xFF182840)
      : const Color(0xFFE8F0FF);
  final chipSelected = isDark
      ? const Color(0xFF22395A)
      : const Color(0xFFD7E6FF);
  final colorScheme = ColorScheme.fromSeed(
    seedColor: base,
    secondary: accent,
    surface: paper,
    brightness: brightness,
  );
  final textTheme =
      GoogleFonts.dmSansTextTheme(
        ThemeData(brightness: brightness).textTheme,
      ).apply(
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: paper,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: paper,
      foregroundColor: colorScheme.onSurface,
      elevation: 0,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: colorScheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      margin: const EdgeInsets.all(0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputFill,
      labelStyle: TextStyle(color: colorScheme.onSurfaceVariant),
      hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
      prefixIconColor: colorScheme.onSurfaceVariant,
      suffixIconColor: colorScheme.onSurfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accent, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: isDark ? lightBase : base,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: chipBackground,
      selectedColor: chipSelected,
      deleteIconColor: base,
      labelStyle: textTheme.bodyMedium?.copyWith(
        color: base,
        fontWeight: FontWeight.w700,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
  );
}
