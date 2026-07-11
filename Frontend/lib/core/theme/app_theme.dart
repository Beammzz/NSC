import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  // Design Tokens from App_Design / SignMind Scanner.dc.html
  static const Color darkNavy = Color(0xFF0B1220);
  static const Color cardDark = Color(0xFF17222F);
  static const Color cardDarkAlt = Color(0xFF101A26);
  static const Color lightSurface = Color(0xFFF4F7FB);
  static const Color primaryAccent = Color(0xFF1E6FD9);
  static const Color primaryAccentHover = Color(0xFF0F2F5C);
  static const Color successGreen = Color(0xFF1FA971);
  static const Color liveDotGreen = Color(0xFF35D491);
  static const Color warningOrange = Color(0xFFE09B2D);
  static const Color textLight = Color(0xFFF4F7FB);
  static const Color textDark = Color(0xFF0F2F5C);
  static const Color textMutedDark = Color(0xFF8FB8EC);
  static const Color textMutedLight = Color(0xFF5A7AA6);
  static const Color borderDark = Color(0x2E8FB8EC); // rgba(143,184,236,.18)
  static const Color borderLight = Color(0xFFDBE5F2);

  static ThemeData get darkTheme {
    final baseTheme = ThemeData.dark();
    final textTheme = GoogleFonts.kanitTextTheme(baseTheme.textTheme).apply(
      bodyColor: textLight,
      displayColor: textLight,
    );

    return baseTheme.copyWith(
      scaffoldBackgroundColor: darkNavy,
      colorScheme: const ColorScheme.dark(
        primary: primaryAccent,
        secondary: successGreen,
        surface: cardDark,
        error: Color(0xFFCF6679),
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textLight,
      ),
      textTheme: textTheme,
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: borderDark),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryAccent,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: GoogleFonts.kanit(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  static ThemeData get lightTheme {
    final baseTheme = ThemeData.light();
    final textTheme = GoogleFonts.kanitTextTheme(baseTheme.textTheme).apply(
      bodyColor: textDark,
      displayColor: textDark,
    );

    return baseTheme.copyWith(
      scaffoldBackgroundColor: lightSurface,
      colorScheme: const ColorScheme.light(
        primary: primaryAccent,
        secondary: successGreen,
        surface: Colors.white,
        error: Color(0xFFB00020),
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textDark,
      ),
      textTheme: textTheme,
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: borderLight),
        ),
      ),
    );
  }
}
