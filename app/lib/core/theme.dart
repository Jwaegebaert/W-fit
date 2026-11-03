import 'package:flutter/material.dart';

import '../domain/catalog.dart';

/// W-fit design system: Material 3, teal seed, generous radii, consistent spacing.
class AppTheme {
  static const seed = Color(0xFF0E9F8A);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gap.radius)),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}

class Gap {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double radius = 20;
  static const page = EdgeInsets.fromLTRB(16, 8, 16, 32);
}

extension SectionStyle on Section {
  Color color(ColorScheme s) => switch (this) {
        Section.warmup => const Color(0xFFF59E0B),
        Section.main => s.primary,
        Section.core => const Color(0xFF8B5CF6),
        Section.cooldown => const Color(0xFF3B82F6),
      };

  IconData get icon => switch (this) {
        Section.warmup => Icons.local_fire_department_rounded,
        Section.main => Icons.fitness_center_rounded,
        Section.core => Icons.adjust_rounded,
        Section.cooldown => Icons.self_improvement_rounded,
      };
}

extension DayStyle on DayType {
  IconData get icon => switch (this) {
        DayType.push => Icons.north_east_rounded,
        DayType.pull => Icons.south_west_rounded,
        DayType.legs => Icons.directions_run_rounded,
      };

  String get focus => switch (this) {
        DayType.push => 'Chest · Shoulders · Triceps',
        DayType.pull => 'Back · Rear delts · Biceps',
        DayType.legs => 'Legs · Glutes · Explosiveness',
      };

  Color color(ColorScheme s) => switch (this) {
        DayType.push => const Color(0xFFEF6C4D),
        DayType.pull => const Color(0xFF3B82F6),
        DayType.legs => const Color(0xFF10B981),
      };
}
