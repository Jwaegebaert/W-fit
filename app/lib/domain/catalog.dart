import 'dart:convert';

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
  });

  factory Equipment.fromJson(Map<String, dynamic> j) => Equipment(
        id: j['id'] as String,
        name: j['name'] as String,
        group: j['group'] as String,
        alwaysAvailable: j['alwaysAvailable'] as bool? ?? false,
        description: j['description'] as String?,
      );

  final String id;
  final String name;
  final String group;
  final bool alwaysAvailable;

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
  });

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

  bool get isWeighted => incrementKg > 0;
  bool get isFloor => equipment.contains(floorEquipmentId);
  bool fitsDay(DayType day) => splits.contains(day.name);
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
