import 'package:flutter/material.dart';

import '../../data/models.dart';

@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.canvas,
    required this.sidebar,
    required this.surface,
    required this.elevated,
    required this.hover,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.haiku,
    required this.sonnet,
    required this.opus,
    required this.fable,
    required this.pass,
    required this.fail,
    required this.warn,
    required this.running,
    required this.idle,
  });

  final Color canvas;
  final Color sidebar;
  final Color surface;
  final Color elevated;
  final Color hover;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color haiku;
  final Color sonnet;
  final Color opus;
  final Color fable;
  final Color pass;
  final Color fail;
  final Color warn;
  final Color running;
  final Color idle;

  static const dark = AppColors(
    canvas: Color(0xFF0E0F12),
    sidebar: Color(0xFF121418),
    surface: Color(0xFF16181D),
    elevated: Color(0xFF1D2027),
    hover: Color(0xFF232731),
    border: Color(0xFF2A2E37),
    borderStrong: Color(0xFF3A3F4B),
    textPrimary: Color(0xFFE8EAF0),
    textSecondary: Color(0xFFA3A9B7),
    textMuted: Color(0xFF6B7280),
    accent: Color(0xFFD97757),
    haiku: Color(0xFF5EC4B6),
    sonnet: Color(0xFF7AA2F7),
    opus: Color(0xFFBB9AF7),
    fable: Color(0xFFE0AF68),
    pass: Color(0xFF4FBF7F),
    fail: Color(0xFFF7768E),
    warn: Color(0xFFE0AF68),
    running: Color(0xFF7AA2F7),
    idle: Color(0xFF9AA0AA),
  );

  static const light = AppColors(
    canvas: Color(0xFFF6F6F8),
    sidebar: Color(0xFFEDEDF0),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    hover: Color(0xFFE9EAEE),
    border: Color(0xFFE2E3E8),
    borderStrong: Color(0xFFC9CBD3),
    textPrimary: Color(0xFF16181D),
    textSecondary: Color(0xFF4B5160),
    textMuted: Color(0xFF8A909C),
    accent: Color(0xFFC2603F),
    haiku: Color(0xFF1F9C8C),
    sonnet: Color(0xFF3B6FD9),
    opus: Color(0xFF8456D6),
    fable: Color(0xFFB7811F),
    pass: Color(0xFF2E9A5E),
    fail: Color(0xFFD8435E),
    warn: Color(0xFFB7811F),
    running: Color(0xFF3B6FD9),
    idle: Color(0xFF7A808A),
  );

  Color tier(Tier tier) => switch (tier) {
    Tier.haiku => haiku,
    Tier.sonnet => sonnet,
    Tier.opus => opus,
    Tier.fable => fable,
  };

  Color verdict(Verdict verdict) => switch (verdict) {
    Verdict.pass => pass,
    Verdict.fail || Verdict.blocked => fail,
    Verdict.running => running,
    Verdict.inconclusive => warn,
    Verdict.pending => idle,
  };

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension AppColorsContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}
