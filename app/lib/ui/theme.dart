import 'package:flutter/material.dart';

/// TIM-POS colours: teal as the main colour, navy for text and dark surfaces, amber for attention.
class Brand {
  static const teal = Color(0xFF0B8577);
  static const navy = Color(0xFF12263F);
  static const amber = Color(0xFFF5A524);
  static const green = Color(0xFF2FB86E);
  static const orange = Color(0xFFF08A24);
  static const coral = Color(0xFFE5484D);
  static const background = Color(0xFFF6F8FA);
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.teal,
    brightness: brightness,
    primary: brightness == Brightness.light ? Brand.teal : null,
    error: Brand.coral,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: brightness == Brightness.light ? Brand.background : null,
    appBarTheme: const AppBarTheme(backgroundColor: Brand.navy, foregroundColor: Colors.white, centerTitle: false),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
      fillColor: brightness == Brightness.light ? Colors.white : null,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
  );
}

/// The TIM-POS logo (a receipt with a T). Used on the loading and sign-in screens.
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 88});
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset('assets/brand/logo.png', width: size, height: size);
}
