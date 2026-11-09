/// Data-driven A/B session templates for the Push / Pull / Legs rotation (docs/IMPROVEMENT-PLAN.md §4.7).
///
/// Each template is an ordered list of slots. A slot names a role and the catalog movement patterns that may fill
/// it (in preference order). The rule engine skips a slot gracefully when the catalog / gym has no candidate.
library;

import 'dart:math' as math;

import 'catalog.dart';
import 'muscles.dart';

/// Role of a main-block slot; drives selection rules, rep scheme and progression.
enum SlotRole {
  /// Optional explosive work (≤ 1 per session, ≤ 2 per week; skipped in deloads and first under time pressure).
  power('Power'),

  /// Heavy compound lift kept for the whole block (progressive overload), 6–10 reps.
  anchor('Anchor'),

  /// Second compound, 8–12 reps; rotates between blocks.
  secondary('Secondary'),

  /// Isolation / small-muscle work, 10–15 reps; constant within a block, new exercises each block.
  accessory('Accessory'),

  /// One slot for the top-priority under-trained muscle that is not today's main target.
  flex('Flex');

  const SlotRole(this.label);
  final String label;
}

class SlotSpec {
  const SlotSpec(this.role, this.patterns, this.label, {this.compound, this.sets});

  final SlotRole role;

  /// Catalog patterns that may fill the slot, most preferred first (empty for [SlotRole.flex]).
  final List<String> patterns;
  final String label;

  /// true = compound exercises only; null = any.
  final bool? compound;

  /// Base working sets overriding the role default (e.g. 4 for lateral raises, the only direct side-delt work).
  final int? sets;
}

class DayTemplate {
  const DayTemplate({
    required this.day,
    required this.variant,
    required this.title,
    required this.focus,
    required this.slots,
  });

  final DayType day;

  /// "A" or "B".
  final String variant;

  /// Short session title, e.g. "Chest strength".
  final String title;

  /// One-line emphasis used in the brief (`variantFocus`).
  final String focus;
  final List<SlotSpec> slots;
}

const _flex = SlotSpec(SlotRole.flex, [], 'Flex');

/// The six session templates. Variants alternate per exposure of a day type (A, B, A, …) and reset to A at the
/// start of each block. Power slots sit in Legs A (jumps) and Pull B (smash-like upper-body power), so a normal
/// week has exactly one power exercise; the engine caps power at 1 per session and 2 per week.
const List<DayTemplate> dayTemplates = [
  DayTemplate(
    day: DayType.push,
    variant: 'A',
    title: 'Chest strength',
    focus: 'horizontal press heavy, shoulder press second',
    slots: [
      SlotSpec(SlotRole.anchor, ['horizontal_push'], 'Heavy horizontal press', compound: true),
      SlotSpec(SlotRole.secondary, ['vertical_push', 'incline_push'], 'Shoulder press', compound: true),
      SlotSpec(SlotRole.accessory, ['lateral_raise'], 'Side delts', sets: 4),
      SlotSpec(SlotRole.accessory, ['chest_fly'], 'Chest isolation'),
      SlotSpec(SlotRole.accessory, ['triceps'], 'Triceps'),
      _flex,
    ],
  ),
  DayTemplate(
    day: DayType.push,
    variant: 'B',
    title: 'Shoulders & upper chest',
    focus: 'vertical & incline press emphasis',
    slots: [
      SlotSpec(SlotRole.anchor, ['vertical_push'], 'Heavy shoulder press', compound: true),
      SlotSpec(SlotRole.secondary, ['incline_push', 'horizontal_push'], 'Incline press', compound: true),
      SlotSpec(SlotRole.accessory, ['lateral_raise'], 'Side delts', sets: 4),
      SlotSpec(SlotRole.accessory, ['chest_fly'], 'Chest isolation'),
      SlotSpec(SlotRole.accessory, ['triceps'], 'Triceps'),
      _flex,
    ],
  ),
  DayTemplate(
    day: DayType.pull,
    variant: 'A',
    title: 'Vertical pull',
    focus: 'vertical pull heavy, rows second',
    slots: [
      SlotSpec(SlotRole.anchor, ['vertical_pull'], 'Heavy vertical pull', compound: true),
      SlotSpec(SlotRole.secondary, ['horizontal_pull'], 'Row', compound: true),
      SlotSpec(SlotRole.accessory, ['rear_delt'], 'Rear delts'),
      SlotSpec(SlotRole.accessory, ['biceps'], 'Biceps'),
      SlotSpec(SlotRole.accessory, ['pullover', 'forearm'], 'Lats / forearms'),
      _flex,
    ],
  ),
  DayTemplate(
    day: DayType.pull,
    variant: 'B',
    title: 'Rows & traps',
    focus: 'row heavy, traps and rear delts',
    slots: [
      SlotSpec(SlotRole.power, ['plyo_upper'], 'Upper-body power'),
      SlotSpec(SlotRole.anchor, ['horizontal_pull'], 'Heavy row', compound: true),
      SlotSpec(SlotRole.secondary, ['vertical_pull'], 'Pulldown', compound: true),
      SlotSpec(SlotRole.accessory, ['shrug', 'carry'], 'Traps'),
      SlotSpec(SlotRole.accessory, ['rear_delt'], 'Rear delts'),
      SlotSpec(SlotRole.accessory, ['biceps'], 'Biceps'),
      _flex,
    ],
  ),
  DayTemplate(
    day: DayType.legs,
    variant: 'A',
    title: 'Squat focus',
    focus: 'squat pattern heavy, hinge second',
    slots: [
      SlotSpec(SlotRole.power, ['plyo_lower'], 'Lower-body power'),
      SlotSpec(SlotRole.anchor, ['squat'], 'Heavy squat pattern', compound: true),
      SlotSpec(SlotRole.secondary, ['hinge', 'hip_extension'], 'Hinge', compound: true),
      SlotSpec(SlotRole.accessory, ['knee_extension', 'lunge'], 'Quads'),
      SlotSpec(SlotRole.accessory, ['knee_flexion'], 'Hamstrings'),
      SlotSpec(SlotRole.accessory, ['hip_abduction', 'hip_adduction', 'glute_isolation'], 'Outer / inner hip'),
      SlotSpec(SlotRole.accessory, ['calf'], 'Calves'),
      _flex,
    ],
  ),
  DayTemplate(
    day: DayType.legs,
    variant: 'B',
    title: 'Hinge & hips',
    focus: 'hinge / hip heavy, squat or lunge second',
    slots: [
      SlotSpec(SlotRole.anchor, ['hinge'], 'Heavy hinge', compound: true),
      SlotSpec(SlotRole.secondary, ['squat', 'lunge'], 'Squat / lunge', compound: true),
      SlotSpec(SlotRole.accessory, ['knee_flexion'], 'Hamstrings'),
      SlotSpec(SlotRole.accessory, ['knee_extension', 'lunge'], 'Quads'),
      SlotSpec(SlotRole.accessory, ['hip_adduction', 'glute_isolation', 'back_extension', 'hip_abduction'],
          'Inner hip / glutes / lower back'),
      SlotSpec(SlotRole.accessory, ['calf'], 'Calves'),
      _flex,
    ],
  ),
];

DayTemplate templateFor(DayType day, String variant) =>
    dayTemplates.firstWhere((t) => t.day == day && t.variant == variant,
        orElse: () => dayTemplates.firstWhere((t) => t.day == day));

/// Muscle group a day type trains.
MuscleGroup groupForDay(DayType day) => switch (day) {
      DayType.push => MuscleGroup.push,
      DayType.pull => MuscleGroup.pull,
      DayType.legs => MuscleGroup.legs,
    };

/// Every main-block pattern referenced by the templates.
Set<String> get templatePatterns => {
      for (final t in dayTemplates)
        for (final s in t.slots) ...s.patterns,
    };

/// Rep range, sets and rest for a role in a given block week.
class RoleScheme {
  const RoleScheme({required this.repMin, required this.repMax, required this.minRest, required this.maxRest});

  final int repMin;
  final int repMax;
  final int minRest;
  final int maxRest;

  static const anchor = RoleScheme(repMin: 6, repMax: 10, minRest: 120, maxRest: 180);
  static const secondary = RoleScheme(repMin: 8, repMax: 12, minRest: 90, maxRest: 120);
  static const accessory = RoleScheme(repMin: 10, repMax: 15, minRest: 45, maxRest: 75);
  static const power = RoleScheme(repMin: 3, repMax: 6, minRest: 60, maxRest: 90);

  static RoleScheme of(SlotRole role) => switch (role) {
        SlotRole.anchor => anchor,
        SlotRole.secondary => secondary,
        SlotRole.power => power,
        SlotRole.accessory || SlotRole.flex => accessory,
      };

  /// Working sets before balance adjustments: anchors ramp 3 → 4 sets in weeks 4–5; deload = −1 set (min 2).
  /// [override] is the slot's own base (`SlotSpec.sets`).
  static int baseSets(SlotRole role, {required int blockWeek, required bool deload, int? override}) {
    final normal = override ??
        switch (role) {
          SlotRole.anchor => blockWeek >= 4 ? 4 : 3,
          SlotRole.flex => 2,
          _ => 3,
        };
    if (!deload) return normal;
    return role == SlotRole.anchor ? 2 : math.max(2, normal - 1);
  }

  /// Rep range for [e]: the role range, nudged toward the exercise's own catalog range when they overlap well.
  (int, int) repsFor(Exercise e) {
    final cMin = e.repMin;
    final cMax = e.repMax;
    if (cMin == null || cMax == null) return (repMin, repMax);
    final lo = repMin > cMin - 2 ? repMin : cMin - 2;
    final hi = repMax < cMax + 3 ? repMax : cMax + 3;
    return hi - lo >= 2 ? (lo, hi) : (repMin, repMax);
  }

  int restFor(Exercise e) => e.rest.clamp(minRest, maxRest);
}
