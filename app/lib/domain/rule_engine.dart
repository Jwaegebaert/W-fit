import 'catalog.dart';
import 'plan.dart';

/// Everything the rule engine needs to know about the user and their gym.
class TrainingContext {
  const TrainingContext({
    required this.catalog,
    this.equipmentAvailability = const {},
    this.occupiedEquipment = const {},
    this.preferences = const {},
    this.experience = 'beginner',
    this.recentExerciseIds = const {},
  });

  final Catalog catalog;

  /// equipmentId → available. Missing entries are treated as available.
  final Map<String, bool> equipmentAvailability;

  /// Equipment that is temporarily busy (this session only).
  final Set<String> occupiedEquipment;

  /// exerciseId → liked | neutral | disliked | banned
  final Map<String, String> preferences;
  final String experience;

  /// Exercises used recently for the same day type (keeps programmes consistent for progression).
  final Set<String> recentExerciseIds;

  int get maxDifficulty => experience == 'intermediate' ? 3 : 2;

  bool isEquipmentUsable(String equipmentId) {
    if (equipmentId == 'bodyweight') return true;
    if (occupiedEquipment.contains(equipmentId)) return false;
    return equipmentAvailability[equipmentId] ?? true;
  }

  bool isEligible(Exercise e) =>
      e.equipment.every(isEquipmentUsable) &&
      preferences[e.id] != 'banned' &&
      e.difficulty <= maxDifficulty;

  TrainingContext copyWith({
    Set<String>? occupiedEquipment,
    Map<String, bool>? equipmentAvailability,
    Set<String>? recentExerciseIds,
  }) =>
      TrainingContext(
        catalog: catalog,
        equipmentAvailability: equipmentAvailability ?? this.equipmentAvailability,
        occupiedEquipment: occupiedEquipment ?? this.occupiedEquipment,
        preferences: preferences,
        experience: experience,
        recentExerciseIds: recentExerciseIds ?? this.recentExerciseIds,
      );
}

class GeneratedWorkout {
  const GeneratedWorkout({
    required this.title,
    required this.coachNote,
    required this.blocks,
    required this.estimatedMinutes,
  });

  final String title;
  final String coachNote;
  final List<PlanBlock> blocks;
  final int estimatedMinutes;
}

class SwapCandidate {
  const SwapCandidate(this.exercise, this.score, this.why);
  final Exercise exercise;
  final int score;
  final String why;
}

/// Deterministic Push/Pull/Legs generator that works fully offline.
class RuleEngine {
  RuleEngine(this.ctx);

  final TrainingContext ctx;

  static const Map<DayType, List<String>> mainSlots = {
    DayType.push: [
      'plyo_upper',
      'horizontal_push',
      'vertical_push',
      'incline_push',
      'lateral_raise',
      'triceps',
      'chest_fly',
    ],
    DayType.pull: [
      'vertical_pull',
      'horizontal_pull',
      'plyo_upper',
      'rear_delt',
      'biceps',
      'horizontal_pull',
    ],
    DayType.legs: [
      'plyo_lower',
      'squat',
      'hinge',
      'lunge',
      'knee_flexion',
      'calf',
      'hip_abduction',
    ],
  };

  static const String beginnerNote =
      'Leave 2–3 reps in reserve on every working set. When you hit the top of the rep range '
      'on all sets, add the smallest weight step next time.';

  /// Number of stretches / mobility drills in the cool-down.
  static const int cooldownSize = 3;

  /// Score boost for exercises used recently on this day type (keeps progression stable).
  static const int recentBonus = 5;

  /// Mild preference for machines, cables and the Smith machine in the main block.
  /// Must stay below [recentBonus] so an established programme is never reshuffled by it.
  static const int machineBonus = 1;

  /// Penalty for floor exercises (equipment 'mat') in warm-up, core and cool-down, so standing /
  /// station alternatives win when they are otherwise comparable (floor space is limited).
  static const int floorPenalty = 3;

  /// Maximum floor exercises per warm-up, core block and cool-down. More are only used when no
  /// standing / station option is left for that pick (a floor drill beats an empty slot).
  static const int maxFloorPerBlock = 1;

  /// Floor penalty when ranking warm-up / core / cool-down swaps (swap scores use a smaller scale).
  static const int swapFloorPenalty = 2;

  GeneratedWorkout generate({
    required DayType day,
    int sessionMinutes = 60,
    bool includeCore = true,
    double? Function(Exercise exercise)? suggestWeight,
  }) {
    final used = <String>{};
    final warmup = _warmup(day, used);
    final core = includeCore ? _core(used) : <PlanItem>[];
    final cooldown = _cooldown(day, used);

    final fixedSeconds = [...warmup, ...core, ...cooldown]
        .fold<int>(0, (s, i) => s + i.estimateSeconds());
    final mainBudget = sessionMinutes * 60 - fixedSeconds;

    final main = <PlanItem>[];
    var spent = 0;
    for (final pattern in mainSlots[day]!) {
      final pick = _bestFor(
        (e) => e.pattern == pattern && e.fitsDay(day) && Section.main.categories.contains(e.category),
        used,
        bonus: (e) => isMachine(e) ? machineBonus : 0,
      );
      if (pick == null) continue;
      final item = PlanItem.fromExercise(pick, targetWeightKg: suggestWeight?.call(pick));
      final cost = item.estimateSeconds();
      if (main.length >= 3 && spent + cost > mainBudget + 120) continue;
      used.add(pick.id);
      main.add(item);
      spent += cost;
    }

    final blocks = [
      PlanBlock(section: Section.warmup, items: warmup),
      PlanBlock(section: Section.main, items: main),
      if (core.isNotEmpty) PlanBlock(section: Section.core, items: core),
      PlanBlock(section: Section.cooldown, items: cooldown),
    ];
    return GeneratedWorkout(
      title: '${day.label} day',
      coachNote: beginnerNote,
      blocks: blocks,
      estimatedMinutes: estimateMinutes(blocks),
    );
  }

  List<PlanItem> _warmup(DayType day, Set<String> used) {
    final items = <PlanItem>[];
    final picked = <Exercise>[];
    final cardio = _warmupCardio(day, used);
    if (cardio != null) {
      used.add(cardio.id);
      items.add(PlanItem.fromExercise(cardio));
    }
    for (var i = 0; i < 3; i++) {
      final pick = _bestForBlock(
        (e) => e.category == 'warmup' && e.pattern != 'cardio' && e.fitsDay(day),
        used,
        picked,
        bonus: (e) => (e.splits.length == 1 ? 2 : 0) + (e.badminton != null ? 1 : 0),
      );
      if (pick == null) break;
      used.add(pick.id);
      picked.add(pick);
      items.add(PlanItem.fromExercise(pick));
    }
    return items;
  }

  /// Machine cardio rotates deterministically by day type (e.g. bike / treadmill / elliptical) among the
  /// usable machines with the best preference; falls back to bodyweight cardio when no machine is usable.
  Exercise? _warmupCardio(DayType day, Set<String> used) {
    final machines = ctx.catalog.exercises
        .where((e) =>
            e.category == 'warmup' &&
            e.pattern == 'cardio' &&
            e.equipment.isNotEmpty &&
            !used.contains(e.id) &&
            ctx.isEligible(e))
        .toList();
    if (machines.isEmpty) {
      return _bestFor((e) => e.category == 'warmup' && e.pattern == 'cardio', used);
    }
    int rank(Exercise e) => switch (ctx.preferences[e.id]) { 'liked' => 2, 'disliked' => 0, _ => 1 };
    final top = machines.map(rank).reduce((a, b) => a > b ? a : b);
    final pool = machines.where((e) => rank(e) == top).toList();
    return pool[day.index % pool.length];
  }

  List<PlanItem> _core(Set<String> used) {
    final items = <PlanItem>[];
    final picked = <Exercise>[];
    const groups = [
      {'anti_extension', 'anti_rotation'},
      {'rotation', 'anti_lateral_flexion', 'hip_flexion'},
    ];
    for (final patterns in groups) {
      final pick = _bestForBlock(
        (e) => e.category == 'core' && patterns.contains(e.pattern),
        used,
        picked,
        bonus: (e) => e.badminton != null ? 1 : 0,
      );
      if (pick == null) continue;
      used.add(pick.id);
      picked.add(pick);
      items.add(PlanItem.fromExercise(pick));
    }
    return items;
  }

  List<PlanItem> _cooldown(DayType day, Set<String> used) {
    final items = <PlanItem>[];
    final picked = <Exercise>[];
    for (var i = 0; i < cooldownSize; i++) {
      final pick = _bestForBlock(
        (e) => e.category == 'cooldown' && e.fitsDay(day),
        used,
        picked,
        bonus: (e) => (e.splits.length == 1 ? 2 : 0) + (e.badminton != null ? 1 : 0),
      );
      if (pick == null) break;
      used.add(pick.id);
      picked.add(pick);
      items.add(PlanItem.fromExercise(pick));
    }
    return items;
  }

  /// [_bestFor] for warm-up, core and cool-down: floor exercises get [floorPenalty], and once the block
  /// holds [maxFloorPerBlock] of them only standing / station exercises qualify — unless none is left.
  Exercise? _bestForBlock(
    bool Function(Exercise) filter,
    Set<String> used,
    List<Exercise> block, {
    int Function(Exercise)? bonus,
  }) {
    int score(Exercise e) => (bonus?.call(e) ?? 0) - (e.isFloor ? floorPenalty : 0);
    final floorFull = block.where((e) => e.isFloor).length >= maxFloorPerBlock;
    return (floorFull ? _bestFor((e) => !e.isFloor && filter(e), used, bonus: score) : null) ??
        _bestFor(filter, used, bonus: score);
  }

  /// Machines, cable stations and the Smith machine (stable, easy to load, little floor space).
  bool isMachine(Exercise e) => e.equipment.any(
      (id) => id == 'smith_machine' || ctx.catalog.equipmentById(id)?.group == 'machines');

  Exercise? _bestFor(
    bool Function(Exercise) filter,
    Set<String> used, {
    int Function(Exercise)? bonus,
  }) {
    Exercise? best;
    var bestScore = -1 << 30;
    for (final e in ctx.catalog.exercises) {
      if (used.contains(e.id) || !filter(e) || !ctx.isEligible(e)) continue;
      final score = _baseScore(e) + (bonus?.call(e) ?? 0);
      if (score > bestScore) {
        best = e;
        bestScore = score;
      }
    }
    return best;
  }

  int _baseScore(Exercise e) {
    var s = 0;
    if (ctx.recentExerciseIds.contains(e.id)) s += recentBonus;
    final pref = ctx.preferences[e.id];
    if (pref == 'liked') s += 2;
    if (pref == 'disliked') s -= 3;
    if (ctx.experience == 'beginner' && e.difficulty == 1) s += 1;
    if (e.compound) s += 1;
    return s;
  }

  /// Ranks replacement exercises for [original]. Strength and power are interchangeable.
  List<SwapCandidate> rankSwaps(
    Exercise original, {
    Set<String> exclude = const {},
    DayType? day,
    int limit = 6,
  }) {
    final isMainSwap = Section.main.categories.contains(original.category);
    final cats = isMainSwap ? Section.main.categories : {original.category};
    final results = <SwapCandidate>[];
    for (final e in ctx.catalog.exercises) {
      if (e.id == original.id || exclude.contains(e.id)) continue;
      if (!cats.contains(e.category) || !ctx.isEligible(e)) continue;
      var score = 0;
      final reasons = <String>[];
      if (e.pattern == original.pattern) {
        score += 3;
        reasons.add('same movement');
      }
      final primaryOverlap = e.primary.where(original.primary.contains).toList();
      score += 2 * primaryOverlap.length;
      if (primaryOverlap.isNotEmpty) {
        reasons.add('trains ${primaryOverlap.map(prettyMuscle).join(' & ').toLowerCase()}');
      }
      score += e.secondary.where(original.secondary.contains).length;
      if (day != null && e.fitsDay(day)) score += 1;
      final pref = ctx.preferences[e.id];
      if (pref == 'liked') score += 1;
      if (pref == 'disliked') score -= 2;
      if (e.difficulty > (ctx.experience == 'beginner' ? 1 : 2)) score -= 2;
      // Same floor-space rule as warm-up / core / cool-down generation.
      if (!isMainSwap && e.isFloor) score -= swapFloorPenalty;
      if (score <= 1) continue;
      final equipment = e.equipment.isEmpty
          ? 'no equipment'
          : e.equipment.map((id) => ctx.catalog.equipmentById(id)?.name ?? id).join(' + ');
      reasons.add(equipment);
      results.add(SwapCandidate(e, score, _capitalize(reasons.join(' · '))));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(limit).toList();
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
