import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const maroonDeep = Color(0xFF2A0A14);
  static const maroonDark = Color(0xFF3A0F1A);
  static const maroon = Color(0xFF5C1A2A);
  static const burgundy = Color(0xFF7B2D3F);
  static const gold = Color(0xFFD4AF37);
  static const goldLight = Color(0xFFE8D48B);
  static const goldDark = Color(0xFFA8882C);
  static const ivory = Color(0xFFF5F0E1);
  static const silver = Color(0xFFC0C0C0);
  static const cream = Color(0xFFFFF8E7);
  static const cardWhite = Color(0xFFFFFDF5);
  static const suitRed = Color(0xFFC62828);
  static const suitBlack = Color(0xFF1A1A1A);
  static const success = Color(0xFF2E7D32);
  static const error = Color(0xFFB71C1C);
  static const teamA = gold;
  static const teamB = silver;
}

ThemeData buildAppTheme() {
  final textTheme = GoogleFonts.cinzelTextTheme().copyWith(
    headlineLarge: GoogleFonts.cinzel(
      fontSize: 28,
      fontWeight: FontWeight.bold,
      color: AppColors.gold,
    ),
    headlineMedium: GoogleFonts.cinzel(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      color: AppColors.gold,
    ),
    headlineSmall: GoogleFonts.cinzel(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: AppColors.ivory,
    ),
    titleLarge: GoogleFonts.cinzel(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: AppColors.ivory,
    ),
    bodyLarge: const TextStyle(fontSize: 16, color: AppColors.ivory),
    bodyMedium: const TextStyle(fontSize: 14, color: AppColors.ivory),
    bodySmall: const TextStyle(fontSize: 12, color: AppColors.silver),
    labelLarge: GoogleFonts.cinzel(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: AppColors.maroonDeep,
    ),
  );

  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.maroonDeep,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.gold,
      onPrimary: AppColors.maroonDeep,
      secondary: AppColors.burgundy,
      onSecondary: AppColors.ivory,
      surface: AppColors.maroonDark,
      onSurface: AppColors.ivory,
      error: AppColors.error,
    ),
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.maroonDark,
      foregroundColor: AppColors.gold,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: GoogleFonts.cinzel(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: AppColors.gold,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.gold,
        foregroundColor: AppColors.maroonDeep,
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: GoogleFonts.cinzel(
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.gold,
        side: const BorderSide(color: AppColors.gold),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.maroonDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.burgundy),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.burgundy),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.gold, width: 2),
      ),
      labelStyle: const TextStyle(color: AppColors.silver),
      hintStyle: TextStyle(color: AppColors.silver.withValues(alpha: 0.6)),
    ),
    cardTheme: CardThemeData(
      color: AppColors.maroonDark,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.burgundy),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.burgundy,
      contentTextStyle: TextStyle(color: AppColors.ivory),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.maroonDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
