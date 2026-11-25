import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

enum DayType {
  push('Push'),
  pull('Pull'),
  legs('Legs');

  const DayType(this.label);
  final String label;

  DayType get next => DayType.values[(index + 1) % DayType.values.length];

  static DayType parse(String value) =>
      DayType.values.firstWhere((d) => d.name == value, orElse: () => DayType.push);
}

enum Section {
  warmup('Warm-up'),
  main('Workout'),
  core('Core'),
  cooldown('Cool-down');

  const Section(this.label);
  final String label;

  static Section parse(String value) =>
      Section.values.firstWhere((s) => s.name == value, orElse: () => Section.main);

  /// Warm-up and cool-down are ticked off as a list, without rest or weights.
  bool get isChecklist => this == warmup || this == cooldown;

  /// Catalog categories that may fill this section.
  Set<String> get categories => switch (this) {
        Section.warmup => {'warmup'},
        Section.main => {'strength', 'power'},
        Section.core => {'core'},
        Section.cooldown => {'cooldown'},
      };
}

class Equipment {
  const Equipment({
    required this.id,
    required this.name,
    required this.group,
    required this.alwaysAvailable,
    this.description,
    this.barWeightKg,
  });

  factory Equipment.fromJson(Map<String, dynamic> j) => Equipment(
        id: j['id'] as String,
        name: j['name'] as String,
        group: j['group'] as String,
        alwaysAvailable: j['alwaysAvailable'] as bool? ?? false,
        description: j['description'] as String?,
        barWeightKg: (j['barWeightKg'] as num?)?.toDouble(),
      );

  final String id;
  final String name;
  final String group;
  final bool alwaysAvailable;

  /// Default weight of the empty bar for bar equipment (barbell, EZ bar, trap bar, Smith machine); null otherwise.
  /// 0 means "differs per gym" (Smith machine) until the user sets it.
  final double? barWeightKg;

  bool get hasBar => barWeightKg != null;

  /// Machine whose weight stack may be numbered instead of marked in kg (see [LoadModel.plates]).
  bool get hasStack => group == 'machines';

  /// One sentence on what it looks like / how to recognise it in a gym.
  final String? description;
}

class Exercise {
  const Exercise({
    required this.id,
    required this.name,
    required this.category,
    required this.splits,
    required this.primary,
    required this.secondary,
    required this.pattern,
    required this.equipment,
    required this.difficulty,
    required this.compound,
    required this.unilateral,
    required this.isTimed,
    required this.sets,
    this.repMin,
    this.repMax,
    this.durationSeconds,
    required this.rest,
    required this.incrementKg,
    this.badminton,
    required this.instructions,
    this.tip,
    this.mistakes = const [],
    this.stress = const [],
    LoadType? load,
    this.bar,
    this.plateKg,
  }) : load = load ?? (incrementKg > 0 ? LoadType.weight : LoadType.none);

  factory Exercise.fromJson(Map<String, dynamic> j) => Exercise(
        id: j['id'] as String,
        name: j['name'] as String,
        category: j['category'] as String,
        splits: (j['splits'] as List).cast<String>(),
        primary: (j['primary'] as List).cast<String>(),
        secondary: (j['secondary'] as List).cast<String>(),
        pattern: j['pattern'] as String,
        equipment: (j['equipment'] as List).cast<String>(),
        difficulty: j['difficulty'] as int,
        compound: j['compound'] as bool,
        unilateral: j['unilateral'] as bool,
        isTimed: j['measure'] == 'time',
        sets: j['sets'] as int,
        repMin: j['repMin'] as int?,
        repMax: j['repMax'] as int?,
        durationSeconds: j['durationSeconds'] as int?,
        rest: j['rest'] as int,
        incrementKg: (j['incrementKg'] as num).toDouble(),
        badminton: j['badminton'] as String?,
        instructions: (j['instructions'] as List).cast<String>(),
        tip: j['tip'] as String?,
        mistakes: (j['mistakes'] as List?)?.cast<String>() ?? const [],
        stress: (j['stress'] as List?)?.cast<String>() ?? const [],
        load: LoadType.parse(j['load'] as String?),
        bar: j['bar'] as String?,
      );

  /// This exercise on a machine with a numbered stack of [kg] plates: progress goes plate by plate.
  Exercise withPlate(double kg) => Exercise(
        id: id,
        name: name,
        category: category,
        splits: splits,
        primary: primary,
        secondary: secondary,
        pattern: pattern,
        equipment: equipment,
        difficulty: difficulty,
        compound: compound,
        unilateral: unilateral,
        isTimed: isTimed,
        sets: sets,
        repMin: repMin,
        repMax: repMax,
        durationSeconds: durationSeconds,
        rest: rest,
        incrementKg: kg,
        badminton: badminton,
        instructions: instructions,
        tip: tip,
        mistakes: mistakes,
        stress: stress,
        load: load,
        bar: bar,
        plateKg: kg,
      );

  /// Equipment id that marks floor work (lying, kneeling or sitting on a mat / the floor).
  static const floorEquipmentId = 'mat';

  final String id;
  final String name;

  /// warmup | strength | power | core | cooldown
  final String category;
  final List<String> splits;
  final List<String> primary;
  final List<String> secondary;
  final String pattern;
  final List<String> equipment;
  final int difficulty;
  final bool compound;
  final bool unilateral;
  final bool isTimed;
  final int sets;
  final int? repMin;
  final int? repMax;
  final int? durationSeconds;
  final int rest;
  final double incrementKg;
  final String? badminton;
  final List<String> instructions;
  final String? tip;

  /// Common beginner mistakes (2–3 short sentences).
  final List<String> mistakes;

  /// Body regions (see `BodyRegion` in muscles.dart) placed under meaningful load or strain; used to avoid
  /// aggravating reported pain.
  final List<String> stress;

  /// How weight is logged for this exercise (see [LoadType]).
  final LoadType load;

  /// Equipment id whose empty bar is part of the load (e.g. 'barbell'); null when no bar applies. The athlete logs
  /// only the plates; statistics add the bar weight.
  final String? bar;

  /// Weight of one plate when this gym's machine has a numbered stack: the athlete sees and logs plate numbers, all
  /// weights stay in kg. Null for kg. Set by [Catalog.withPlates].
  final double? plateKg;

  /// [kg] as a whole number of plates (at least one, unless the plates assist); unchanged without a numbered stack.
  double snapKg(double kg) {
    final plate = plateKg;
    return plate == null ? kg : math.max(isAssisted ? 0 : 1, (kg / plate).round()) * plate;
  }

  bool get isWeighted => incrementKg > 0;
  bool get isAssisted => load == LoadType.assist;

  /// Whether the set rows show a kg field at all.
  bool get logsWeight => load != LoadType.none;
  bool get isFloor => equipment.contains(floorEquipmentId);
  bool fitsDay(DayType day) => splits.contains(day.name);

  /// "/ side" suffix for exercises done one side at a time.
  String get sideSuffix => unilateral ? ' / side' : '';
}

/// How load is logged for an exercise.
enum LoadType {
  /// External weight (dumbbells, machine stack, plates). For bar exercises: the plates only.
  weight,

  /// Bodyweight exercise where extra weight is possible but rare (pull-ups, dips); kg field on request.
  optional,

  /// Machine assistance (assisted pull-up / dip): more kg makes it easier, progress by lowering it.
  assist,

  /// Bodyweight, timed or mobility work: no kg field.
  none;

  static LoadType? parse(String? v) => v == null ? null : LoadType.values.where((t) => t.name == v).firstOrNull;
}

/// "7" or, for a weight logged before the stack was numbered, "6.5".
String formatPlate(double number) {
  final n = (number * 10).round() / 10;
  return n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(1);
}

/// Turns logged kg into the real load: logged plates + the empty bar, and no load for assisted machines. Also knows the
/// machines with a numbered stack, where the athlete works with plate numbers instead of kg.
class LoadModel {
  const LoadModel(this.catalog, [this.barOverrides = const {}, this.plates = const {}]);

  final Catalog catalog;

  /// equipmentId → bar weight set by the user (Equipment screen); falls back to the catalog default.
  final Map<String, double> barOverrides;

  /// equipmentId → kg of one plate, for machines with a numbered stack.
  final Map<String, double> plates;

  /// Kg of one plate when [exerciseId] is done on a numbered stack; null when it is logged in kg.
  double? plateKg(String exerciseId) {
    final e = plates.isEmpty ? null : catalog.exercise(exerciseId);
    return e == null ? null : plates[catalog.stackOf(e)];
  }

  /// Empty-bar weight for a bar equipment id.
  double barWeight(String equipmentId) =>
      barOverrides[equipmentId] ?? catalog.equipmentById(equipmentId)?.barWeightKg ?? 0;

  /// Empty-bar weight included in [exerciseId]'s load (0 without a bar).
  double barKgFor(String exerciseId) {
    final bar = catalog.exercise(exerciseId)?.bar;
    return bar == null ? 0 : barWeight(bar);
  }

  bool isAssisted(String exerciseId) => catalog.exercise(exerciseId)?.isAssisted ?? false;

  /// Prescribed weight for display: "40 kg", "40 kg plates (+20 bar)", "25 kg assist" or "plate 7 (35 kg)".
  String weightLabel(Exercise? e, double kg) {
    String fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    if (e == null ? null : plateKg(e.id) case final plate?) {
      return 'plate ${formatPlate(kg / plate)} (${fmt(kg)} kg${e!.isAssisted ? ' assist' : ''})';
    }
    if (e?.isAssisted ?? false) return '${fmt(kg)} kg assist';
    final bar = e?.bar == null ? 0.0 : barWeight(e!.bar!);
    return bar > 0 ? '${fmt(kg)} kg plates (+${fmt(bar)} bar)' : '${fmt(kg)} kg';
  }

  /// Real load for a logged weight: plates + bar; null for assisted machines or when nothing was logged.
  double? totalKg(String exerciseId, double? loggedKg) {
    if (loggedKg == null || isAssisted(exerciseId)) return null;
    return loggedKg + barKgFor(exerciseId);
  }

  /// Parses the profile's `barWeightsJson` ({"barbell": 20, ...}); invalid input gives an empty map.
  static Map<String, double> parseOverrides(String? json) {
    if (json == null || json.trim().isEmpty) return const {};
    try {
      final v = jsonDecode(json);
      if (v is! Map) return const {};
      return {
        for (final e in v.entries)
          if (e.key is String && e.value is num && (e.value as num) >= 0) e.key as String: (e.value as num).toDouble(),
      };
    } on FormatException {
      return const {};
    }
  }

  /// Parses the profile's `stackPlatesJson` ({"seated_row_machine": 5, ...}).
  static Map<String, double> parsePlates(String? json) =>
      {for (final e in parseOverrides(json).entries) if (e.value > 0) e.key: e.value};
}

class Catalog {
  Catalog({required this.version, required this.equipment, required this.exercises})
      : _exerciseById = {for (final e in exercises) e.id: e},
        _equipmentById = {for (final e in equipment) e.id: e};

  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog(
        version: j['version'] as int,
        equipment: (j['equipment'] as List)
            .map((e) => Equipment.fromJson(e as Map<String, dynamic>))
            .toList(),
        exercises: (j['exercises'] as List)
            .map((e) => Exercise.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static Future<Catalog> load() async {
    final raw = await rootBundle.loadString('assets/data/catalog.json');
    return Catalog.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  final int version;
  final List<Equipment> equipment;
  final List<Exercise> exercises;
  final Map<String, Exercise> _exerciseById;
  final Map<String, Equipment> _equipmentById;

  Exercise? exercise(String id) => _exerciseById[id];
  Equipment? equipmentById(String id) => _equipmentById[id];

  /// Machine whose stack [e] is loaded with; null for free weights, bars and bodyweight work.
  String? stackOf(Exercise e) => !e.isWeighted || e.isTimed || e.bar != null
      ? null
      : e.equipment.where((id) => _equipmentById[id]?.hasStack ?? false).firstOrNull;

  /// This catalog for a gym where the machines in [plates] have numbered stacks (see [LoadModel.plates]).
  Catalog withPlates(Map<String, double> plates) => plates.isEmpty
      ? this
      : Catalog(
          version: version,
          equipment: equipment,
          exercises: [
            for (final e in exercises) if (plates[stackOf(e)] case final kg?) e.withPlate(kg) else e,
          ],
        );

  String exerciseName(String id) => _exerciseById[id]?.name ?? id;
}

String prettyMuscle(String m) => switch (m) {
      'front_delts' => 'Front delts',
      'side_delts' => 'Side delts',
      'rear_delts' => 'Rear delts',
      'upper_back' => 'Upper back',
      'lower_back' => 'Lower back',
      'hip_flexors' => 'Hip flexors',
      'rotator_cuff' => 'Rotator cuff',
      'full_body' => 'Full body',
      'thoracic_spine' => 'Thoracic spine',
      _ => m[0].toUpperCase() + m.substring(1),
    };
