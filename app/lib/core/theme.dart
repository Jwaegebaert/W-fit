import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/catalog.dart';

/// W-fit brand palette: refined teal/emerald, deep ink surfaces and one warm gold accent for highlights/PRs.
class BrandColors {
  /// Core brand teal (logo, launcher icon background, theme seed).
  static const teal = Color(0xFF0E9F8A);
  /// Deeper teal: first stroke of the mark, light-mode primary (5.8:1 with white).
  static const tealDeep = Color(0xFF0A7363);
  /// Brighter emerald: second (rising) stroke of the mark.
  static const tealBright = Color(0xFF14B89F);
  /// Light teal used as primary on dark surfaces.
  static const mint = Color(0xFF5FD6BF);
  /// Deep graphite with a hint of green for dark surfaces.
  static const ink = Color(0xFF0E1513);
  /// Off-white light surface.
  static const mist = Color(0xFFF6FAF8);
  /// Background of the Today card, dark enough for white text in both themes (≥ 4.5:1 for all its text).
  static const hero = Color(0xFF075A4E);

  /// Restrained accent for highlights / personal records.
  static const gold = Color(0xFFE8A93A);
}

/// W-fit design system: Material 3, teal brand palette, generous radii, consistent spacing.
class AppTheme {
  static const seed = BrandColors.teal;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ColorScheme _scheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    if (brightness == Brightness.light) {
      return base.copyWith(
        primary: BrandColors.tealDeep,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xFFC2EFE5),
        onPrimaryContainer: const Color(0xFF00382F),
        tertiary: const Color(0xFF8A5A00),
        onTertiary: Colors.white,
        tertiaryContainer: const Color(0xFFFFE2B0),
        onTertiaryContainer: const Color(0xFF2C1A00),
        surface: BrandColors.mist,
        onSurface: const Color(0xFF141D1B),
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFEFF5F3),
        surfaceContainer: const Color(0xFFE9F0EE),
        surfaceContainerHigh: const Color(0xFFE3EBE8),
        surfaceContainerHighest: const Color(0xFFDDE5E2),
      );
    }
    return base.copyWith(
      primary: BrandColors.mint,
      onPrimary: const Color(0xFF00382F),
      primaryContainer: const Color(0xFF0A5148),
      onPrimaryContainer: const Color(0xFFC2EFE5),
      tertiary: const Color(0xFFF2BE5C),
      onTertiary: const Color(0xFF422C00),
      tertiaryContainer: const Color(0xFF5E4100),
      onTertiaryContainer: const Color(0xFFFFDDA6),
      surface: BrandColors.ink,
      onSurface: const Color(0xFFDCE5E2),
      surfaceContainerLowest: const Color(0xFF09100E),
      surfaceContainerLow: const Color(0xFF151E1B),
      surfaceContainer: const Color(0xFF19231F),
      surfaceContainerHigh: const Color(0xFF232E2A),
      surfaceContainerHighest: const Color(0xFF2E3935),
    );
  }

  static TextTheme _text(TextTheme t) => t.copyWith(
        displaySmall: t.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        headlineLarge: t.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.25),
        titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
        titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
      );

  static ThemeData _build(Brightness brightness) {
    final scheme = _scheme(brightness);
    final isDark = brightness == Brightness.dark;
    final raw = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
    final base = raw.copyWith(textTheme: _text(raw.textTheme), primaryTextTheme: _text(raw.primaryTextTheme));
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        // Sizes are only filled in by Theme.of, so styles built here must state theirs.
        titleTextStyle: base.textTheme.titleLarge?.copyWith(color: scheme.onSurface, fontSize: 20),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: brightness,
        ),
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
          textStyle: base.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 16),
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
        labelTextStyle: WidgetStatePropertyAll(base.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 12)),
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
  static const double radiusSm = 12;
  static const double radiusMd = 16;
  static const double tap = 48;
  static const double item = 10;
  static const double fabClearance = 88;
  static const sheet = EdgeInsets.fromLTRB(20, 0, 20, 24);
  static const bar = EdgeInsets.fromLTRB(16, 10, 16, 10);
}

/// Status colours that stay readable as text on cards and tinted pills in both themes.
extension StatusColors on ColorScheme {
  /// Needs a look: behind target, sets left open, a running work timer.
  Color get attention => _tone(this, const Color(0xFF9A4300), const Color(0xFFF5A65B));

  /// Records, streaks and the coach.
  Color get gold => tertiary;
}

/// Core in the push / pull / legs / core chart.
Color coreColor(ColorScheme s) => _tone(s, const Color(0xFF7559D9), const Color(0xFFB3A1F7));

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
        DayType.push => _tone(s, const Color(0xFFD9573A), const Color(0xFFF28B6E)),
        DayType.pull => _tone(s, const Color(0xFF3770D6), const Color(0xFF86AEF5)),
        DayType.legs => _tone(s, const Color(0xFF3F9447), const Color(0xFF8FD47E)),
      };
}

Color _tone(ColorScheme s, Color light, Color dark) => s.brightness == Brightness.dark ? dark : light;
