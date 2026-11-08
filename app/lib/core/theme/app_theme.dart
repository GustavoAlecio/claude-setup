import 'package:flutter/material.dart';

import 'app_colors.dart';

const monoFamily = 'Menlo';

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.accent,
      brightness: brightness,
      surface: c.surface,
      primary: c.accent,
    ),
    scaffoldBackgroundColor: c.canvas,
    dividerColor: c.border,
    splashFactory: NoSplash.splashFactory,
    extensions: [c],
  );
  final buttonShape = WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)));
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(shape: buttonShape)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: ButtonStyle(shape: buttonShape)),
    textButtonTheme: TextButtonThemeData(style: ButtonStyle(shape: buttonShape)),
    textTheme: base.textTheme
        .copyWith(
          titleLarge: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
          titleMedium: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          bodyMedium: const TextStyle(fontSize: 13),
          bodySmall: const TextStyle(fontSize: 11),
          labelMedium: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        )
        .apply(bodyColor: c.textPrimary, displayColor: c.textPrimary),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.borderStrong),
      ),
      textStyle: TextStyle(color: c.textPrimary, fontSize: 11),
    ),
  );
}
