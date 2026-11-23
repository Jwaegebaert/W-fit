/// Muscle and body-region vocabulary shared by the catalog, the training-load analytics, the rule engine,
/// the AI coach brief and the UI. The backend mirrors these lists in `WFit.Api.Domain.Anatomy`.
library;

import 'dart:convert';

/// Weight of a set for a secondary muscle when counting effective (fractional) sets.
/// Fractional counting follows Pelland et al. 2024 (indirect work counts roughly half a set).
const double secondarySetWeight = 0.5;

/// Display / programming group of a tracked muscle.
enum MuscleGroup {
  push('Push'),
  pull('Pull'),
  legs('Legs'),
  core('Core');

  const MuscleGroup(this.label);
  final String label;
}

/// Weekly effective-set band for one muscle (primary set = 1, secondary set = [secondarySetWeight]).
///
/// [min] ≈ minimum effective volume for a beginner on a 3×/week Push/Pull/Legs programme; [max] is the point
/// above which extra volume mostly adds fatigue in this programme (not a hard physiological limit).
/// Sources: Schoenfeld, Ogborn & Krieger 2017 (dose–response), Pelland et al. 2024 (fractional volume,
/// diminishing returns), ACSM 2009 progression models (beginners progress on modest volume).
class MuscleTarget {
  const MuscleTarget(this.min, this.max);
  final double min;
  final double max;

  double get mid => (min + max) / 2;

  /// Planning goal: the lower quarter of the band. The engine aims here (not at [min]) so that deload weeks and
  /// normal week-to-week variation still keep multi-week averages at or above [min].
  double get goal => min + 0.25 * (max - min);
}

class MuscleInfo {
  const MuscleInfo(this.id, this.label, this.group, this.target);
  final String id;
  final String label;
  final MuscleGroup group;
  final MuscleTarget target;
}

/// Muscles whose weekly volume is tracked and balanced (order = display order).
const List<MuscleInfo> trackedMuscleInfo = [
  MuscleInfo('chest', 'Chest', MuscleGroup.push, MuscleTarget(6, 12)),
  MuscleInfo('front_delts', 'Front delts', MuscleGroup.push, MuscleTarget(3, 10)),
  MuscleInfo('side_delts', 'Side delts', MuscleGroup.push, MuscleTarget(5, 10)),
  MuscleInfo('triceps', 'Triceps', MuscleGroup.push, MuscleTarget(4, 10)),
  MuscleInfo('lats', 'Lats', MuscleGroup.pull, MuscleTarget(6, 12)),
  MuscleInfo('upper_back', 'Upper back', MuscleGroup.pull, MuscleTarget(6, 12)),
  MuscleInfo('rear_delts', 'Rear delts', MuscleGroup.pull, MuscleTarget(4, 10)),
  MuscleInfo('traps', 'Traps', MuscleGroup.pull, MuscleTarget(2, 6)),
  MuscleInfo('biceps', 'Biceps', MuscleGroup.pull, MuscleTarget(4, 10)),
  MuscleInfo('forearms', 'Forearms', MuscleGroup.pull, MuscleTarget(1, 6)),
  MuscleInfo('quads', 'Quads', MuscleGroup.legs, MuscleTarget(6, 12)),
  MuscleInfo('glutes', 'Glutes', MuscleGroup.legs, MuscleTarget(6, 12)),
  MuscleInfo('hamstrings', 'Hamstrings', MuscleGroup.legs, MuscleTarget(5, 10)),
  MuscleInfo('adductors', 'Adductors', MuscleGroup.legs, MuscleTarget(2, 6)),
  MuscleInfo('abductors', 'Abductors', MuscleGroup.legs, MuscleTarget(2, 6)),
  MuscleInfo('calves', 'Calves', MuscleGroup.legs, MuscleTarget(3, 8)),
  MuscleInfo('abs', 'Abs', MuscleGroup.core, MuscleTarget(4, 10)),
  MuscleInfo('obliques', 'Obliques', MuscleGroup.core, MuscleTarget(2, 8)),
  MuscleInfo('lower_back', 'Lower back', MuscleGroup.core, MuscleTarget(1, 6)),
];

final Map<String, MuscleInfo> trackedMuscles = {for (final m in trackedMuscleInfo) m.id: m};

/// How much attention a muscle gets, chosen by the athlete (Settings → Muscle focus) or proposed by the coach.
enum FocusLevel {
  less('Less'),
  normal('Normal'),
  more('More');

  const FocusLevel(this.label);
  final String label;

  static FocusLevel parse(String? v) => values.where((l) => l.name == v).firstOrNull ?? FocusLevel.normal;
}

/// The athlete's muscle focus: [levels] scale a muscle's weekly band (less ≈ 60–70 %, more ≈ 115–125 %); [light]
/// muscles avoid heavy loading (higher reps, machines and cables rather than barbell lifts).
///
/// Stored as `{"less":[...],"more":[...],"light":[...]}` in the profile (`muscleFocusJson`) and sent in the brief.
class MuscleFocus {
  const MuscleFocus({this.levels = const {}, this.light = const {}});

  factory MuscleFocus.fromJson(Map<String, dynamic> j) {
    List<String> ids(String key) =>
        (j[key] as List? ?? const []).whereType<String>().where(trackedMuscles.containsKey).toList();
    return MuscleFocus(
      levels: {
        for (final m in ids('less')) m: FocusLevel.less,
        for (final m in ids('more')) m: FocusLevel.more, // "more" wins when both are listed
      },
      light: ids('light').toSet(),
    );
  }

  static MuscleFocus decode(String? json) {
    if (json == null || json.trim().isEmpty) return none;
    try {
      final v = jsonDecode(json);
      return v is Map ? MuscleFocus.fromJson(v.cast<String, dynamic>()) : none;
    } on FormatException {
      return none;
    }
  }

  static const none = MuscleFocus();

  final Map<String, FocusLevel> levels;
  final Set<String> light;

  bool get isEmpty => levels.values.every((l) => l == FocusLevel.normal) && light.isEmpty;

  FocusLevel levelOf(String muscle) => levels[muscle] ?? FocusLevel.normal;
  bool isLight(String muscle) => light.contains(muscle);

  /// Weekly band for [muscle] after the focus setting.
  MuscleTarget targetFor(String muscle) {
    final base = trackedMuscles[muscle]?.target ?? const MuscleTarget(0, 0);
    return switch (levelOf(muscle)) {
      FocusLevel.less => MuscleTarget(base.min * 0.6, base.max * 0.7),
      FocusLevel.more => MuscleTarget(base.min * 1.25, base.max * 1.15),
      FocusLevel.normal => base,
    };
  }

  MuscleFocus withLevel(String muscle, FocusLevel level) =>
      MuscleFocus(levels: {...levels, muscle: level}..removeWhere((_, l) => l == FocusLevel.normal), light: light);

  MuscleFocus withLight(String muscle, bool on) =>
      MuscleFocus(levels: levels, light: on ? {...light, muscle} : ({...light}..remove(muscle)));

  List<String> _with(FocusLevel l) => [for (final m in trackedMuscleInfo) if (levelOf(m.id) == l) m.id];

  Map<String, dynamic> toJson() => {
        'less': _with(FocusLevel.less),
        'more': _with(FocusLevel.more),
        'light': [for (final m in trackedMuscleInfo) if (light.contains(m.id)) m.id],
      };

  String encode() => jsonEncode(toJson());
}

/// Valid values for catalog `primary` / `secondary`: the tracked muscles plus mobility / prehab targets that are
/// shown on exercise screens but not volume-balanced.
final Set<String> muscleVocabulary = {
  ...trackedMuscles.keys,
  'hip_flexors',
  'rotator_cuff',
  'thoracic_spine',
  'full_body',
};

/// Body regions a user can report pain or discomfort for, and that catalog exercises declare in `stress`
/// (regions placed under meaningful load or strain by the exercise).
enum BodyRegion {
  neck('neck', 'Neck'),
  shoulder('shoulder', 'Shoulder'),
  elbow('elbow', 'Elbow'),
  wrist('wrist', 'Wrist / hand'),
  upperBack('upper_back', 'Upper back'),
  lowerBack('lower_back', 'Lower back'),
  hip('hip', 'Hip'),
  knee('knee', 'Knee'),
  ankle('ankle', 'Ankle / foot');

  const BodyRegion(this.id, this.label);
  final String id;
  final String label;

  static BodyRegion? parse(String? id) {
    for (final r in values) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Muscles whose direct training is also avoided when pain in this region is severe.
  Set<String> get relatedMuscles => switch (this) {
        BodyRegion.neck => const {'traps'},
        BodyRegion.shoulder => const {'front_delts', 'side_delts', 'rear_delts', 'rotator_cuff'},
        BodyRegion.elbow => const {'biceps', 'triceps', 'forearms'},
        BodyRegion.wrist => const {'forearms'},
        BodyRegion.upperBack => const {'upper_back', 'traps', 'thoracic_spine'},
        BodyRegion.lowerBack => const {'lower_back'},
        BodyRegion.hip => const {'adductors', 'abductors', 'hip_flexors'},
        BodyRegion.knee => const {'quads'},
        BodyRegion.ankle => const {'calves'},
      };
}

final Set<String> regionVocabulary = {for (final r in BodyRegion.values) r.id};

String prettyRegion(String id) => BodyRegion.parse(id)?.label ?? id;
