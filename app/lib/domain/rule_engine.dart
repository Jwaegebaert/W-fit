import 'dart:math' as math;

import 'catalog.dart';
import 'limitations.dart';
import 'muscles.dart';
import 'plan.dart';
import 'program.dart';
import 'progression.dart';
import 'stats.dart';
import 'templates.dart';
import 'training_load.dart';

export 'templates.dart' show SlotRole;

/// Everything the rule engine needs to know about the user, their gym and their training so far.
///
/// v3 inputs (all optional, plain data; see docs/IMPROVEMENT-PLAN.md §4.6):
/// * [limitations] – active pain / discomfort / exercise feedback (`LimitationPolicy.fromFeedback`).
/// * [feedback] – too_hard / too_easy per exercise; defaults to `limitations.exerciseFeedback`.
/// * [program] – block / week / variant / deload and the annotated session history (`computeProgramState`).
///   Without it the engine runs in legacy mode (block 1, variant A, [recentExerciseIds] as continuity hint).
/// * [balance] – multi-week muscle balance (`analyzeBalance`).
/// * [trends] – progression trend per exercise (`exerciseTrends`).
/// * [history] – completed sets per exercise grouped per session, most recent first (`groupHistory`); used for
///   target weights. Without it `generate(suggestWeight: …)` provides base weights.
class TrainingContext {
  const TrainingContext({
    required this.catalog,
    this.equipmentAvailability = const {},
    this.occupiedEquipment = const {},
    this.preferences = const {},
    this.experience = 'beginner',
    this.restScale = 1.0,
    this.cooldownStretches = RuleEngine.cooldownSize,
    this.focus = MuscleFocus.none,
    this.recentExerciseIds = const {},
    this.limitations = const LimitationPolicy.empty(),
    this.feedback = const {},
    this.program,
    this.balance,
    this.trends = const {},
    this.history = const {},
  });

  final Catalog catalog;

  /// equipmentId → available. Missing entries are treated as available.
  final Map<String, bool> equipmentAvailability;

  /// Equipment that is temporarily busy (this session only).
  final Set<String> occupiedEquipment;

  /// exerciseId → liked | neutral | disliked | banned
  final Map<String, String> preferences;
  final String experience;

  /// Multiplier for every rest period (profile "Rest between sets", see [restScaleFor]).
  final double restScale;

  /// Stretches in the cool-down (0 = no cool-down block), capped at [RuleEngine.cooldownSize].
  final int cooldownStretches;

  /// The athlete's muscle focus (less / more / light per muscle).
  final MuscleFocus focus;

  /// [e] trains a muscle marked "light" as a primary mover.
  bool trainsLight(Exercise e) => e.primary.any(focus.isLight);

  /// A barbell / Smith lift for a "light" muscle: only used when nothing else fits.
  bool lightMisfit(Exercise e) => e.bar != null && trainsLight(e);

  /// "Go light on quads and glutes" for the muscles of [e] marked light.
  String lightReason(Exercise e) =>
      'Go light on ${e.primary.where(focus.isLight).map((m) => prettyMuscle(m).toLowerCase()).join(' and ')}';

  /// [seconds] of rest scaled by [restScale], rounded to 5 s. Zero stays zero.
  int scaleRest(int seconds) => seconds <= 0 || restScale == 1.0 ? seconds : math.max(5, (seconds * restScale / 5).round() * 5);

  /// Legacy continuity hint (exercises used recently for the same day type). Ignored when [program] is given,
  /// because the program history then drives continuity and rotation.
  final Set<String> recentExerciseIds;

  final LimitationPolicy limitations;
  final Map<String, ExerciseFeedbackSummary> feedback;
  final ProgramState? program;
  final BalanceReport? balance;
  final Map<String, ExerciseTrend> trends;
  final Map<String, List<List<LoggedSet>>> history;

  int get maxDifficulty => experience == 'intermediate' ? 3 : 2;

  Map<String, ExerciseFeedbackSummary> get effectiveFeedback =>
      feedback.isNotEmpty ? feedback : limitations.exerciseFeedback;

  bool isEquipmentUsable(String equipmentId) {
    if (equipmentId == 'bodyweight') return true;
    if (occupiedEquipment.contains(equipmentId)) return false;
    return equipmentAvailability[equipmentId] ?? true;
  }

  /// Equipment usable, not banned, difficulty allowed and not excluded by a limitation.
  bool isEligible(Exercise e) =>
      e.equipment.every(isEquipmentUsable) &&
      preferences[e.id] != 'banned' &&
      e.difficulty <= maxDifficulty &&
      !limitations.excludes(e);

  TrainingContext copyWith({
    Set<String>? occupiedEquipment,
    Map<String, bool>? equipmentAvailability,
    Map<String, String>? preferences,
    Set<String>? recentExerciseIds,
    LimitationPolicy? limitations,
    Map<String, ExerciseFeedbackSummary>? feedback,
    ProgramState? program,
    BalanceReport? balance,
    Map<String, ExerciseTrend>? trends,
    Map<String, List<List<LoggedSet>>>? history,
  }) =>
      TrainingContext(
        catalog: catalog,
        equipmentAvailability: equipmentAvailability ?? this.equipmentAvailability,
        occupiedEquipment: occupiedEquipment ?? this.occupiedEquipment,
        preferences: preferences ?? this.preferences,
        experience: experience,
        restScale: restScale,
        cooldownStretches: cooldownStretches,
        focus: focus,
        recentExerciseIds: recentExerciseIds ?? this.recentExerciseIds,
        limitations: limitations ?? this.limitations,
        feedback: feedback ?? this.feedback,
        program: program ?? this.program,
        balance: balance ?? this.balance,
        trends: trends ?? this.trends,
        history: history ?? this.history,
      );
}

class GeneratedWorkout {
  const GeneratedWorkout({
    required this.title,
    required this.coachNote,
    required this.blocks,
    required this.estimatedMinutes,
    this.rationale = const [],
    this.focusMuscles = const [],
    this.meta = const PlanMeta(),
    this.roles = const {},
  });

  final String title;
  final String coachNote;
  final List<PlanBlock> blocks;
  final int estimatedMinutes;

  /// ≤ 6 short, data-referencing reasons (also in [meta]).
  final List<String> rationale;

  /// Muscles given extra sets or the flex slot.
  final List<String> focusMuscles;

  /// Metadata to store as `PlannedWorkout.metaJson`.
  final PlanMeta meta;

  /// Main-block exercise id → slot role.
  final Map<String, SlotRole> roles;
}

class SwapCandidate {
  const SwapCandidate(this.exercise, this.score, this.why);
  final Exercise exercise;
  final int score;
  final String why;
}

/// Result of `RuleEngine.adjustForLimitations`.
class PlanAdjustment {
  const PlanAdjustment({required this.blocks, required this.changes});

  final List<PlanBlock> blocks;
  final List<PlanChange> changes;

  bool get changed => changes.isNotEmpty;
  int get estimatedMinutes => estimateMinutes(blocks);
}

/// Deterministic Push/Pull/Legs generator that works fully offline (docs/IMPROVEMENT-PLAN.md §4.7).
class RuleEngine {
  RuleEngine(this.ctx);

  final TrainingContext ctx;

  static const String beginnerNote =
      'Leave 2–3 reps in reserve on every working set. When you hit the top of the rep range '
      'on all sets, add the smallest weight step next time.';

  /// Number of stretches / mobility drills in the cool-down.
  static const int cooldownSize = 3;

  /// Warm-up drills after the cardio; the last one is only kept when the session has time left.
  static const int warmupDrills = 3;

  /// Legacy continuity bonus for [TrainingContext.recentExerciseIds] (only without a program state).
  static const int recentBonus = 5;

  /// Mild preference for machines, cables and the Smith machine in the main block.
  static const int machineBonus = 1;

  /// Penalty for floor exercises (equipment 'mat') in warm-up, core and cool-down, so standing /
  /// station alternatives win when they are otherwise comparable (floor space is limited).
  static const int floorPenalty = 3;

  /// Maximum floor exercises per warm-up, core block and cool-down. More are only used when no
  /// standing / station option is left for that pick (a floor drill beats an empty slot).
  static const int maxFloorPerBlock = 1;

  /// Floor penalty when ranking warm-up / core / cool-down swaps (swap scores use a smaller scale).
  static const int swapFloorPenalty = 2;

  /// Power exercises allowed per ISO week (badminton support stays secondary).
  static const int maxPowerPerWeek = 2;

  /// Maximum balance-driven extra sets per session (flex slot not included).
  static const int maxExtraSetsPerSession = 3;

  /// Plans may exceed the requested session length by at most this much (estimate).
  static const int timeToleranceSeconds = 180;

  /// Time left under the session length from which the plan is filled (extra exercise first, then sets).
  static const int fillThresholdSeconds = 8 * 60;

  /// At most this many exercises / extra sets are added to fill time.
  static const int maxFillExercises = 3;
  static const int maxFillSets = 4;

  /// Set caps when filling time (balance and template sets may already sit higher; those are left alone).
  static const int maxSetsCompound = 4;
  static const int maxSetsIsolation = 3;

  /// Novelty penalties (block-to-block variation without randomness).
  static const double accessoryRepeatPenalty = 5;
  static const double secondaryRepeatPenalty = 3;
  static const double otherVariantPenalty = 3;
  static const double anchorRecentPenalty = 4;

  /// Builds a session for [day].
  ///
  /// [date] is the planned day (defaults to the program / balance date or today); [program], [balance] and
  /// [trends] override the corresponding [TrainingContext] fields. [suggestWeight] supplies a base weight for
  /// exercises without [TrainingContext.history] (deload and feedback adjustments are still applied).
  GeneratedWorkout generate({
    required DayType day,
    int sessionMinutes = 60,
    bool includeCore = true,
    DateTime? date,
    ProgramState? program,
    BalanceReport? balance,
    Map<String, ExerciseTrend>? trends,
    double? Function(Exercise exercise)? suggestWeight,
  }) {
    final p = program ?? ctx.program;
    final bal = balance ?? ctx.balance;
    final planDate = dateOnly(date ?? p?.date ?? bal?.asOf ?? DateTime.now());
    final state = p?.forDay(day) ?? ProgramState.initial(day, planDate);
    return _PlanBuilder(
      engine: this,
      day: day,
      date: planDate,
      sessionMinutes: sessionMinutes,
      includeCore: includeCore,
      state: state,
      legacy: p == null,
      balance: bal,
      trends: trends ?? ctx.trends,
      suggestWeight: suggestWeight,
    ).build();
  }

  /// Machines, cable stations and the Smith machine (stable, easy to load, little floor space).
  bool isMachine(Exercise e) => e.equipment.any(
      (id) => id == 'smith_machine' || ctx.catalog.equipmentById(id)?.group == 'machines');

  /// Ranks replacement exercises for [original]. Strength and power are interchangeable.
  /// Exercises excluded by limitations are never suggested; penalised ones rank lower.
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
      final penalty = ctx.limitations.penalty(e);
      if (penalty > 0) {
        score -= penalty;
        final why = ctx.limitations.reason(e);
        if (why != null) reasons.add(why.toLowerCase());
      } else if (ctx.limitations.reason(original) != null && original.stress.isNotEmpty) {
        final spared = original.stress.where((r) => !e.stress.contains(r)).map(prettyRegion).toList();
        if (spared.isNotEmpty) reasons.add('no ${spared.join(' / ').toLowerCase()} load');
      }
      final equipment = e.equipment.isEmpty
          ? 'no equipment'
          : e.equipment.map((id) => ctx.catalog.equipmentById(id)?.name ?? id).join(' + ');
      reasons.add(equipment);
      results.add(SwapCandidate(e, score, _capitalize(reasons.join(' · '))));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(limit).toList();
  }

  /// Instant re-evaluation of an existing plan after a pain report (or equipment change): every exercise that is
  /// now excluded – or stresses a mildly painful region while a cleaner alternative exists – is replaced by the
  /// best swap (keeping sets, reps and rest) or removed. Returns the new blocks and the list of changes.
  PlanAdjustment adjustForLimitations(List<PlanBlock> blocks, DayType day) {
    final used = {for (final b in blocks) ...b.items.map((i) => i.exerciseId)};
    final changes = <PlanChange>[];
    final out = <PlanBlock>[];
    final program = ctx.program;
    for (final block in blocks) {
      final items = <PlanItem>[];
      for (final item in block.items) {
        final e = ctx.catalog.exercise(item.exerciseId);
        if (e == null) {
          items.add(item);
          continue;
        }
        final excluded = !ctx.isEligible(e);
        final penalty = ctx.limitations.penalty(e);
        if (!excluded && penalty < LimitationPolicy.mildRegionPenalty) {
          items.add(item);
          continue;
        }
        final reason = ctx.limitations.reason(e) ?? _ineligibleReason(e);
        final options = rankSwaps(e, exclude: used, day: day, limit: 40)
            .where((c) => ctx.limitations.penalty(c.exercise) < math.max(penalty, 1))
            .toList();
        options.sort((a, b) {
          int rank(SwapCandidate c) =>
              (block.section == Section.main && !c.exercise.fitsDay(day) ? 1 : 0) +
              (c.exercise.category != e.category ? 1 : 0);
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : b.score.compareTo(a.score);
        });
        if (options.isEmpty) {
          if (excluded) {
            changes.add(PlanChange(from: e.id, reason: reason));
          } else {
            items.add(item);
          }
          continue;
        }
        final c = options.first.exercise;
        used.add(c.id);
        final history = _historyFor(c.id, program);
        final timed = c.isTimed;
        final lo = timed ? null : (item.repMin ?? c.repMin);
        final hi = timed ? null : (item.repMax ?? c.repMax);
        double? weight;
        if (c.isWeighted && history.isNotEmpty) {
          weight = adviseProgression(c, history, repMin: lo, repMax: hi, deload: program?.deload ?? false).weightKg;
        }
        items.add(PlanItem(
          exerciseId: c.id,
          sets: item.sets,
          repMin: lo,
          repMax: hi,
          durationSeconds: timed ? c.durationSeconds : null,
          restSeconds: item.restSeconds,
          targetWeightKg: weight,
          notes: item.notes,
          perSide: c.unilateral,
        ));
        changes.add(PlanChange(from: e.id, to: c.id, reason: reason));
      }
      if (items.isNotEmpty || block.section == Section.main) out.add(PlanBlock(section: block.section, items: items));
    }
    return PlanAdjustment(blocks: out, changes: changes);
  }

  /// Applies the "go light" setting to an existing plan (one the coach wrote, or a missed plan that moves to a new
  /// date): barbell / Smith lifts for light muscles are replaced where possible and heavy rep ranges become 10–15.
  /// Everything else stays as it is. Safe to apply more than once.
  PlanAdjustment applyLight(List<PlanBlock> blocks, DayType day) {
    if (ctx.focus.light.isEmpty) return PlanAdjustment(blocks: blocks, changes: const []);
    final used = {for (final b in blocks) ...b.items.map((i) => i.exerciseId)};
    final changes = <PlanChange>[];
    PlanItem lighten(PlanItem item, Exercise e, {required bool swapped}) {
      final heavy = (item.repMin ?? 10) < 10;
      if (!swapped && !heavy) return item;
      final lo = math.max(item.repMin ?? 10, 10);
      final hi = math.max(item.repMax ?? 15, heavy ? 15 : lo);
      final history = _historyFor(e.id, ctx.program);
      final weight = e.isWeighted && history.isNotEmpty
          ? adviseProgression(e, history, repMin: lo, repMax: hi, deload: ctx.program?.deload ?? false, light: true).weightKg
          : null;
      return item.copyWith(repMin: lo, repMax: hi, targetWeightKg: weight, clearWeight: weight == null);
    }

    final out = [
      for (final block in blocks)
        if (block.section != Section.main)
          block
        else
          PlanBlock(
            section: block.section,
            items: [
              for (final item in block.items)
                () {
                  final e = ctx.catalog.exercise(item.exerciseId);
                  if (e == null || e.category != 'strength' || item.isTimed || !ctx.trainsLight(e)) return item;
                  if (!ctx.lightMisfit(e)) return lighten(item, e, swapped: false);
                  final c = rankSwaps(e, exclude: used, day: day, limit: 40)
                      .map((s) => s.exercise)
                      .where((x) =>
                          x.category == 'strength' &&
                          x.bar == null &&
                          !x.isTimed &&
                          x.fitsDay(day) &&
                          x.primary.any(e.primary.contains) &&
                          ctx.limitations.penalty(x) < LimitationPolicy.mildRegionPenalty)
                      .firstOrNull;
                  if (c == null) return lighten(item, e, swapped: false);
                  used.add(c.id);
                  changes.add(PlanChange(from: e.id, to: c.id, reason: ctx.lightReason(e)));
                  return lighten(
                    item.copyWith(exerciseId: c.id, perSide: c.unilateral, notes: '', clearWeight: true),
                    c,
                    swapped: true,
                  );
                }(),
            ],
          ),
    ];
    return PlanAdjustment(blocks: out, changes: changes);
  }

  /// Follows a changed Less / Normal / More level in an existing plan: one set fewer (min 2) on exercises for a muscle
  /// that got less focus, one set more (within the caps) on the first exercise for a muscle that got more.
  List<PlanBlock> applyFocusLevels(List<PlanBlock> blocks, {required MuscleFocus before, required MuscleFocus after}) {
    int delta(String m) => after.levelOf(m).index - before.levelOf(m).index;
    final boosted = <String>{};
    return [
      for (final block in blocks)
        if (block.section != Section.main)
          block
        else
          PlanBlock(
            section: block.section,
            items: [
              for (final item in block.items)
                () {
                  final e = ctx.catalog.exercise(item.exerciseId);
                  if (e == null || e.category != 'strength') return item;
                  if (e.primary.any((m) => delta(m) < 0)) {
                    return item.copyWith(sets: item.sets > 2 ? item.sets - 1 : item.sets);
                  }
                  final up = e.primary.where((m) => delta(m) > 0 && !boosted.contains(m)).toList();
                  final cap = e.compound ? maxSetsCompound : maxSetsIsolation;
                  if (up.isEmpty || item.sets >= cap) return item;
                  boosted.addAll(up);
                  return item.copyWith(sets: item.sets + 1);
                }(),
            ],
          ),
    ];
  }

  String _ineligibleReason(Exercise e) {
    if (ctx.preferences[e.id] == 'banned') return 'Banned exercise';
    final missing = e.equipment.where((id) => !ctx.isEquipmentUsable(id)).toList();
    if (missing.isNotEmpty) {
      return '${missing.map((id) => ctx.catalog.equipmentById(id)?.name ?? id).join(', ')} not available';
    }
    return 'Not suitable right now';
  }

  /// Progression history for [id] without deload sessions (unless only deload sessions exist).
  List<List<LoggedSet>> _historyFor(String id, ProgramState? program) {
    final all = ctx.history[id] ?? const [];
    final deloads = program?.deloadSessionIds ?? const <String>{};
    if (deloads.isEmpty) return all;
    final filtered = all.where((s) => s.isEmpty || !deloads.contains(s.first.sessionId)).toList();
    return filtered.isEmpty ? all : filtered;
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// A main-block slot filled with an exercise.
class _Pick {
  _Pick(this.slot, this.exercise);

  final SlotSpec slot;
  final Exercise exercise;
  int sets = 0;
  int extra = 0;
  int? repMin;
  int? repMax;
  int? duration;
  int rest = 60;
  double? weight;
  String notes = '';

  /// The muscle a flex pick serves.
  String? flexMuscle;

  SlotRole get role => slot.role;
  int get totalSets => math.max(1, sets + extra);

  PlanItem toItem() => PlanItem(
        exerciseId: exercise.id,
        sets: totalSets,
        repMin: repMin,
        repMax: repMax,
        durationSeconds: duration,
        restSeconds: rest,
        targetWeightKg: weight,
        notes: notes,
        perSide: exercise.unilateral,
      );
}

class _PlanBuilder {
  _PlanBuilder({
    required this.engine,
    required this.day,
    required this.date,
    required this.sessionMinutes,
    required this.includeCore,
    required this.state,
    required this.legacy,
    required this.balance,
    required this.trends,
    required this.suggestWeight,
  })  : ctx = engine.ctx,
        template = templateFor(day, state.variant);

  final RuleEngine engine;
  final TrainingContext ctx;
  final DayType day;
  final DateTime date;
  final int sessionMinutes;
  final bool includeCore;
  final ProgramState state;
  final bool legacy;
  final BalanceReport? balance;
  final Map<String, ExerciseTrend> trends;
  final double? Function(Exercise exercise)? suggestWeight;
  final DayTemplate template;

  final used = <String>{};
  final picks = <_Pick>[];
  final focus = <String>[];
  final _balanceLines = <String>[];
  final _anchorLines = <String>[];
  final _limitLines = <String>[];
  final _feedbackLines = <String>[];
  final _otherLines = <String>[];

  Catalog get catalog => ctx.catalog;
  bool get deload => state.deload;

  // ------------------------------------------------------------------ history helpers
  late final List<ProgramSession> _sameVariant = state.sessionsIn(day: day, variant: state.variant);
  late final List<ProgramSession> _otherVariant =
      state.sessionsIn(day: day, variant: state.variant == 'A' ? 'B' : 'A');
  late final List<ProgramSession> _prevBlockSameVariant =
      state.sessionsIn(block: state.blockNumber - 1, day: day, variant: state.variant);
  late final Set<String> _prevBlockIds = {
    for (final s in state.sessionsIn(block: state.blockNumber - 1, day: day)) ...s.mainExerciseIds,
  };
  late final Set<String> _otherVariantIds = {for (final s in _otherVariant) ...s.mainExerciseIds};
  final _reconstructed = <String, Map<int, String>>{};

  bool _matches(Exercise e, SlotSpec slot) {
    if (slot.role == SlotRole.power) return e.category == 'power' && slot.patterns.contains(e.pattern);
    return e.category == 'strength' &&
        slot.patterns.contains(e.pattern) &&
        (slot.compound == null || e.compound == slot.compound);
  }

  /// Which exercise filled each slot of [s] (greedy match of its main exercises against the template).
  Map<int, String> _reconstruct(ProgramSession s) => _reconstructed.putIfAbsent(s.id, () {
        final t = templateFor(s.day, s.variant);
        final out = <int, String>{};
        final taken = <String>{};
        for (var i = 0; i < t.slots.length; i++) {
          final slot = t.slots[i];
          if (slot.role == SlotRole.flex) continue;
          for (final id in s.mainExerciseIds) {
            final e = catalog.exercise(id);
            if (e == null || taken.contains(id) || !_matches(e, slot)) continue;
            out[i] = id;
            taken.add(id);
            break;
          }
        }
        return out;
      });

  /// Most frequent exercise in slot [index] over [sessions] (ties → most recent).
  String? _slotHistory(int index, List<ProgramSession> sessions) {
    final counts = <String, int>{};
    final firstSeen = <String, int>{};
    for (var k = 0; k < sessions.length; k++) {
      final id = _reconstruct(sessions[k])[index];
      if (id == null) continue;
      counts[id] = (counts[id] ?? 0) + 1;
      firstSeen.putIfAbsent(id, () => k);
    }
    String? best;
    for (final id in counts.keys) {
      if (best == null ||
          counts[id]! > counts[best]! ||
          (counts[id] == counts[best] && firstSeen[id]! < firstSeen[best]!)) {
        best = id;
      }
    }
    return best;
  }

  /// Consecutive blocks (ending with the previous one) in which [id] was the anchor of this day / variant.
  int _anchorBlocks(String id, int index) {
    var n = 0;
    for (var b = state.blockNumber - 1; b >= 1; b--) {
      final sessions = state.sessionsIn(block: b, day: day, variant: state.variant);
      if (sessions.isEmpty || _slotHistory(index, sessions) != id) break;
      n++;
    }
    return n;
  }

  /// Anchors of any day / variant in the last two blocks.
  late final Set<String> _recentAnchors = {
    for (final s in state.history.where((s) => s.block >= state.blockNumber - 2 && s.block < state.blockNumber))
      for (final entry in _reconstruct(s).entries)
        if (templateFor(s.day, s.variant).slots[entry.key].role == SlotRole.anchor) entry.value,
  };

  // ------------------------------------------------------------------ scoring
  double _baseScore(Exercise e) {
    var s = 0.0;
    final pref = ctx.preferences[e.id];
    if (pref == 'liked') s += 2;
    if (pref == 'disliked') s -= 3;
    if (ctx.experience == 'beginner' && e.difficulty == 1) s += 1;
    // After `too_hard`, harder variations lose to easier ones.
    if (ctx.effectiveFeedback[e.id]?.kind == FeedbackKind.tooHard && e.difficulty > 1) s -= 1.5;
    s -= ctx.limitations.penalty(e);
    return s;
  }

  double _slotScore(Exercise e, SlotSpec slot) {
    var s = _baseScore(e);
    final idx = slot.patterns.indexOf(e.pattern);
    if (idx >= 0) s += 3.0 * (slot.patterns.length - 1 - idx);
    if (engine.isMachine(e)) s += RuleEngine.machineBonus;
    if (e.isFloor) s -= 1;
    switch (slot.role) {
      case SlotRole.anchor:
        s += e.isWeighted ? 1 : -2;
        if (e.unilateral) s -= 1;
        if (_recentAnchors.contains(e.id)) s -= RuleEngine.anchorRecentPenalty;
        if (_otherVariantIds.contains(e.id)) s -= 2;
      case SlotRole.secondary:
        s += e.isWeighted ? 0.5 : -1;
        if (e.unilateral) s -= 0.5;
        if (_prevBlockIds.contains(e.id)) s -= RuleEngine.secondaryRepeatPenalty;
        if (_otherVariantIds.contains(e.id)) s -= 2;
      case SlotRole.accessory || SlotRole.power:
        if (!e.compound) s += 1;
        if (_prevBlockIds.contains(e.id)) s -= RuleEngine.accessoryRepeatPenalty;
        if (_otherVariantIds.contains(e.id)) s -= RuleEngine.otherVariantPenalty;
      case SlotRole.flex:
        break;
    }
    final bal = balance;
    if (bal != null && !deload) {
      for (final m in e.primary) {
        s += 1.5 * (bal.priority(m)?.score ?? 0);
        if (bal.isHigh(m)) s -= 0.5;
      }
    }
    // Muscle focus: "more" muscles are preferred, "less" ones avoided where the slot allows; "light" muscles avoid
    // barbell lifts and favour machines / cables.
    for (final m in e.primary) {
      switch (ctx.focus.levelOf(m)) {
        case FocusLevel.more:
          s += 1;
        case FocusLevel.less:
          s -= 1.5;
        case FocusLevel.normal:
          break;
      }
    }
    if (ctx.trainsLight(e)) {
      if (e.bar != null) s -= 3;
      if (engine.isMachine(e)) s += 1;
    }
    if (legacy && ctx.recentExerciseIds.contains(e.id)) s += RuleEngine.recentBonus;
    return s;
  }

  Exercise? _best(Iterable<Exercise> candidates, double Function(Exercise) score) {
    // "Go light": barbell / Smith lifts for a light muscle only when nothing else is left.
    final fitting = candidates.where((e) => !ctx.lightMisfit(e));
    if (ctx.focus.light.isNotEmpty && fitting.isNotEmpty) candidates = fitting;
    Exercise? best;
    var bestScore = double.negativeInfinity;
    for (final e in candidates) {
      final s = score(e);
      if (s > bestScore + 1e-9) {
        best = e;
        bestScore = s;
      }
    }
    return best;
  }

  bool _usable(Exercise e) => !used.contains(e.id) && ctx.isEligible(e);
  bool _clean(Exercise e) => ctx.limitations.penalty(e) < LimitationPolicy.mildRegionPenalty;

  /// Prefer an easier variation after `too_hard` feedback when one exists.
  bool _wantsEasier(Exercise e, List<Exercise> candidates) =>
      ctx.effectiveFeedback[e.id]?.kind == FeedbackKind.tooHard &&
      e.difficulty > 1 &&
      candidates.any((c) => c.difficulty < e.difficulty && _clean(c));

  // ------------------------------------------------------------------ main block
  _Pick? _pickSlot(int index, SlotSpec slot) {
    final candidates = catalog.exercises.where((e) => _usable(e) && e.fitsDay(day) && _matches(e, slot)).toList();
    if (candidates.isEmpty) return null;
    final label = slot.role == SlotRole.anchor ? 'Anchor' : slot.label;
    // A running lift gives way to "go light" as soon as the slot has an alternative.
    bool misfit(Exercise e) => ctx.lightMisfit(e) && candidates.any((c) => !ctx.lightMisfit(c) && _clean(c));

    // Continuity within the block (same day type and variant).
    final cont = _slotHistory(index, _sameVariant);
    if (cont != null) {
      final e = catalog.exercise(cont)!;
      if (candidates.contains(e) && _clean(e) && !_wantsEasier(e, candidates) && !misfit(e)) {
        return _Pick(slot, e);
      }
      final pick = _best(candidates.where((c) => c.id != cont), (c) => _slotScore(c, slot));
      if (pick != null) {
        final why = ctx.limitations.reason(e) ??
            (misfit(e)
                ? ctx.lightReason(e)
                : _wantsEasier(e, candidates)
                    ? 'felt too hard'
                    : _ineligibleWhy(e));
        _limitLines.add('$label: ${pick.name} instead of ${e.name} – ${why[0].toLowerCase()}${why.substring(1)}');
        return _Pick(slot, pick);
      }
      return null;
    }

    if (slot.role == SlotRole.anchor) {
      final prev = _slotHistory(index, _prevBlockSameVariant);
      if (prev != null) {
        final e = catalog.exercise(prev)!;
        final trend = trends[prev];
        final stalled = trend == ExerciseTrend.stalled || trend == ExerciseTrend.regressing;
        final blocks = _anchorBlocks(prev, index);
        if (candidates.contains(e) && _clean(e) && !stalled && blocks < 2 && !misfit(e)) {
          _anchorLines.add('Anchor ${e.name} kept for block ${state.blockNumber}: still progressing');
          return _Pick(slot, e);
        }
        final alternatives = candidates.where((c) => c.id != prev).toList();
        final pick = _best(alternatives.isEmpty ? candidates : alternatives, (c) => _slotScore(c, slot) + _similarity(c, e));
        if (pick != null && pick.id != prev) {
          final why = misfit(e)
              ? ctx.lightReason(e).toLowerCase()
              : stalled
              ? '${trend!.id} on ${e.name}'
              : blocks >= 2
                  ? '${e.name} done for $blocks blocks'
                  : (ctx.limitations.reason(e) ?? _ineligibleWhy(e));
          _anchorLines.add('New anchor: ${pick.name} replaces ${e.name} ($why)');
        }
        return pick == null ? null : _Pick(slot, pick);
      }
    }
    final pick = _best(candidates, (c) => _slotScore(c, slot));
    if (pick != null && slot.role == SlotRole.anchor && state.history.isNotEmpty) {
      _anchorLines.add('Anchor for this block: ${pick.name}');
    }
    return pick == null ? null : _Pick(slot, pick);
  }

  /// Equivalent-variation bonus: same pattern and primary muscles as [original].
  double _similarity(Exercise c, Exercise original) =>
      (c.pattern == original.pattern ? 1.0 : 0.0) + 0.5 * c.primary.where(original.primary.contains).length;

  String _ineligibleWhy(Exercise e) => engine._ineligibleReason(e).toLowerCase();

  int _powerThisWeek() {
    final week = startOfWeek(date);
    var n = 0;
    for (final s in state.history) {
      if (s.weekStart != week || !dateOnly(s.date).isBefore(date)) continue;
      n += s.mainExerciseIds.where((id) => catalog.exercise(id)?.category == 'power').length;
    }
    return n;
  }

  void _prescribe(_Pick p) {
    final e = p.exercise;
    final scheme = RoleScheme.of(p.role);
    p.sets = RoleScheme.baseSets(p.role, blockWeek: state.blockWeek, deload: deload, override: p.slot.sets);
    if (p.role == SlotRole.flex && (balance?.priority(p.flexMuscle ?? '')?.extraSets ?? 0) >= 2) p.sets = 3;
    if (e.isTimed) {
      p.duration = e.durationSeconds;
    } else {
      final (lo, hi) = scheme.repsFor(e);
      // "Light" muscles: no heavy sets – at least 10 reps, up to 15.
      final light = ctx.trainsLight(e) && lo < 10;
      p.repMin = light ? 10 : lo;
      p.repMax = light ? math.max(hi, 15) : hi;
    }
    p.rest = ctx.scaleRest(scheme.restFor(e));
    p.notes = switch (p.role) {
      SlotRole.anchor when ctx.trainsLight(e) => 'Anchor · go-light setting: higher reps, no grinding',
      SlotRole.anchor => deload ? 'Anchor · deload: lighter, crisp reps' : 'Anchor · progress this lift all block',
      SlotRole.flex => 'Extra ${prettyMuscle(p.flexMuscle ?? '').toLowerCase()} work',
      SlotRole.power => 'Explosive, full rest – stop before speed drops',
      _ => '',
    };
  }

  void _assignWeight(_Pick p) {
    final e = p.exercise;
    if (!e.isWeighted) return;
    final history = engine._historyFor(e.id, state);
    final fb = ctx.effectiveFeedback[e.id];
    var steps = fb?.incrementSteps ?? 0;
    if (steps != 0 && (ctx.history[e.id] ?? const []).any((s) => s.isNotEmpty && dateOnly(s.first.date).isAfter(dateOnly(fb!.date)))) {
      steps = 0; // already performed since the feedback
    }
    if (steps != 0) {
      _feedbackLines.add('${e.name} felt ${fb!.kind == FeedbackKind.tooHard ? 'too hard → one step lighter' : 'too easy → one step heavier'}');
    }
    if (history.isNotEmpty) {
      p.weight = adviseProgression(
        e,
        history,
        repMin: p.repMin,
        repMax: p.repMax,
        deload: deload,
        incrementSteps: steps,
        holdOnStruggle: p.role == SlotRole.anchor,
        light: ctx.trainsLight(e),
      ).weightKg;
      return;
    }
    final base = suggestWeight?.call(e);
    if (base == null) return;
    var w = base + steps * e.incrementKg;
    if (deload) w *= 0.9;
    p.weight = w > 0 ? roundToStep(w, e.incrementKg) : base;
  }

  void _buildMain() {
    final slots = template.slots;
    final powerAllowed = !deload && _powerThisWeek() < RuleEngine.maxPowerPerWeek;
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      if (slot.role == SlotRole.flex) continue;
      if (slot.role == SlotRole.power && !powerAllowed) continue;
      final pick = _pickSlot(i, slot);
      if (pick == null) continue;
      used.add(pick.exercise.id);
      picks.add(pick);
    }
    // Thin catalog / equipment: fill up with the best remaining exercises for the day.
    while (picks.where((p) => p.role != SlotRole.power).length < 3) {
      final filler = const SlotSpec(SlotRole.accessory, [], 'Extra');
      final e = _best(
        catalog.exercises.where((e) => _usable(e) && e.fitsDay(day) && e.category == 'strength'),
        (e) => _slotScore(e, filler) + (e.compound ? 1 : 0),
      );
      if (e == null) break;
      used.add(e.id);
      picks.add(_Pick(filler, e));
    }
    for (final p in picks) {
      _prescribe(p);
    }
  }

  void _applyBalance() {
    final bal = balance;
    if (bal == null || deload) return;
    var budget = RuleEngine.maxExtraSetsPerSession;
    const order = {SlotRole.accessory: 0, SlotRole.secondary: 1, SlotRole.anchor: 2};
    final trainable = picks.where((p) => order.containsKey(p.role)).toList()
      ..sort((a, b) => order[a.role]!.compareTo(order[b.role]!));
    for (final pr in bal.priorities) {
      if (budget == 0) break;
      var n = pr.extraSets;
      for (final p in trainable) {
        if (n == 0 || budget == 0) break;
        if (p.extra > 0 || !p.exercise.primary.contains(pr.muscle)) continue;
        p.extra = 1;
        n--;
        budget--;
        if (!focus.contains(pr.muscle)) focus.add(pr.muscle);
        _balanceLines.add('${pr.label} ${_volumeText(pr.muscle)} → +1 set on ${p.exercise.name}');
      }
    }
    final priority = {for (final pr in bal.priorities) pr.muscle};
    for (final p in trainable) {
      if (p.role == SlotRole.anchor || p.extra != 0 || p.sets <= 2) continue;
      // Only trim exercises whose every tracked primary muscle is above target (don't starve a co-target).
      final tracked = p.exercise.primary.where(trackedMuscles.containsKey).toList();
      if (tracked.isEmpty || !tracked.every(bal.isHigh) || tracked.any(priority.contains)) continue;
      p.extra = -1;
      final m = tracked.first;
      _otherLines.add('${prettyMuscle(m)} ${_volumeText(m)} (max ${_fmt(ctx.focus.targetFor(m).max)}) → '
          '−1 set on ${p.exercise.name}');
    }
  }

  String _volumeText(String muscle) {
    final st = balance?.status(muscle);
    if (st == null) return '';
    final min = _fmt(st.targetMin);
    final last = st.lastActiveWeek;
    if (last == null) return '${_fmt(st.thisWeek)}/$min sets';
    if (last < st.targetMin) return '${_fmt(last)}/$min sets last week';
    final goal = trackedMuscles.containsKey(muscle) ? ctx.focus.targetFor(muscle).goal : null;
    return goal != null && last < goal
        ? '${_fmt(last)} sets last week (goal ${_fmt(goal)})'
        : '${_fmt(last)} sets last week';
  }

  /// Minimum priority score for the flex slot (≈ a quarter below the goal, or any deficit below the minimum).
  static const double minFlexScore = 0.025;

  /// Flex candidates: balance priorities plus in-week shortfalls (a muscle whose home day type was already trained
  /// this week but is still below its minimum), highest score first. Muscles that already reached their minimum this
  /// week (e.g. through an earlier flex slot) are skipped.
  List<(String, double, String)> _flexCandidates(BalanceReport bal) {
    final out = <String, (String, double, String)>{
      for (final pr in bal.priorities)
        if (pr.score >= minFlexScore) pr.muscle: (pr.muscle, pr.score, pr.reason),
    };
    final week = startOfWeek(date);
    final trainedDays = {
      for (final s in state.history)
        if (s.weekStart == week && dateOnly(s.date).isBefore(date)) s.day,
    };
    for (final st in bal.muscles) {
      final home = switch (trackedMuscles[st.muscle]?.group) {
        MuscleGroup.push => DayType.push,
        MuscleGroup.pull => DayType.pull,
        MuscleGroup.legs => DayType.legs,
        _ => null,
      };
      if (home == null || !trainedDays.contains(home) || st.thisWeek >= st.targetMin) continue;
      final score = 0.2 + 0.3 * (st.targetMin - st.thisWeek) / st.targetMin;
      final prev = out[st.muscle];
      if (prev == null || prev.$2 < score) {
        out[st.muscle] = (st.muscle, score, '${_fmt(st.thisWeek)}/${_fmt(st.targetMin)} sets so far this week');
      }
    }
    return out.values.where((c) => (bal.status(c.$1)?.thisWeek ?? 0) < (bal.status(c.$1)?.targetMin ?? 1)).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
  }

  void _addFlex() {
    final bal = balance;
    if (bal == null || deload || !template.slots.any((s) => s.role == SlotRole.flex)) return;
    final targets = {for (final p in picks) ...p.exercise.primary};
    for (final (m, _, reason) in _flexCandidates(bal)) {
      final info = trackedMuscles[m];
      if (info == null || targets.contains(m)) continue;
      if (info.group == MuscleGroup.core && includeCore) continue;
      final days = bal.daysSinceTrainedOn(m, date);
      if (days != null && days < 2) continue;
      const slot = SlotSpec(SlotRole.flex, [], 'Flex');
      final e = _best(
        catalog.exercises.where((e) => _usable(e) && e.category == 'strength' && e.primary.contains(m)),
        (e) =>
            _slotScore(e, slot) +
            (e.compound ? 0 : 2) +
            (e.primary.first == m ? 1 : 0) +
            (e.primary.length == 1 ? 1 : 0) +
            (e.fitsDay(day) ? 0.5 : 0) +
            (ctx.history.containsKey(e.id) ? 0.5 : 0),
      );
      if (e == null) continue;
      final pick = _Pick(slot, e)..flexMuscle = m;
      _prescribe(pick);
      used.add(e.id);
      picks.add(pick);
      if (!focus.contains(m)) focus.add(m);
      _balanceLines.insert(math.min(1, _balanceLines.length), 'Flex: ${e.name} for ${info.label.toLowerCase()} ($reason)');
      return;
    }
  }

  // ------------------------------------------------------------------ warm-up / core / cool-down
  List<Exercise> _warmup() {
    final items = <Exercise>[];
    final cardio = _warmupCardio();
    if (cardio != null) {
      used.add(cardio.id);
      items.add(cardio);
    }
    final picked = <Exercise>[];
    for (var i = 0; i < RuleEngine.warmupDrills; i++) {
      final pick = _bestForBlock(
        (e) => e.category == 'warmup' && e.pattern != 'cardio' && e.fitsDay(day),
        picked,
        bonus: (e) => (e.splits.length == 1 ? 2.0 : 0.0) + (e.badminton != null ? 0.1 : 0.0),
      );
      if (pick == null) break;
      used.add(pick.id);
      picked.add(pick);
      items.add(pick);
    }
    _warmupDrills = picked.length;
    return items;
  }

  var _warmupDrills = 0;

  /// Machine cardio rotates deterministically by day type (and variant) among the usable machines with the best
  /// preference; falls back to bodyweight cardio when no machine is usable.
  Exercise? _warmupCardio() {
    final machines = catalog.exercises
        .where((e) =>
            e.category == 'warmup' &&
            e.pattern == 'cardio' &&
            e.equipment.isNotEmpty &&
            !used.contains(e.id) &&
            ctx.isEligible(e))
        .toList();
    if (machines.isEmpty) {
      return _bestOf((e) => e.category == 'warmup' && e.pattern == 'cardio');
    }
    int rank(Exercise e) => switch (ctx.preferences[e.id]) { 'liked' => 2, 'disliked' => 0, _ => 1 };
    final top = machines.map(rank).reduce(math.max);
    final pool = machines.where((e) => rank(e) == top).toList();
    final shift = state.variant == 'B' ? 1 : 0;
    return pool[(day.index + shift) % pool.length];
  }

  List<Exercise> _core() {
    final items = <Exercise>[];
    final picked = <Exercise>[];
    final corePatterns = {for (final e in catalog.exercises) if (e.category == 'core') e.pattern}.toList()..sort();
    const group1 = {'anti_extension', 'anti_rotation', 'back_extension'};
    final groups = [
      corePatterns.where(group1.contains).toList(),
      corePatterns.where((p) => !group1.contains(p)).toList(),
    ];
    final rotation = state.history.where((s) => s.day == day).length;
    for (var g = 0; g < groups.length; g++) {
      final patterns = groups[g];
      if (patterns.isEmpty) continue;
      // Pattern emphasis rotates with each exposure of this day type (group 1 every second exposure, so it does
      // not lock onto the A/B variant); the day offset keeps the three sessions of a week different.
      final preferred = patterns[((g == 0 ? rotation ~/ 2 : rotation) + day.index) % patterns.length];
      final pick = _bestForBlock(
        (e) => e.category == 'core' && patterns.contains(e.pattern),
        picked,
        bonus: (e) {
          var b = (e.badminton != null ? 0.1 : 0.0) + (legacy ? 0 : (e.pattern == preferred ? 1.5 : 0));
          final bal = balance;
          if (bal != null && !deload) {
            for (final m in e.primary) {
              b += 2 * (bal.priority(m)?.score ?? 0);
              if (bal.isHigh(m)) b -= 2;
            }
          }
          return b;
        },
      );
      if (pick == null) continue;
      used.add(pick.id);
      picked.add(pick);
      items.add(pick);
    }
    return items;
  }

  List<Exercise> _cooldown() {
    final items = <Exercise>[];
    for (var i = 0; i < ctx.cooldownStretches.clamp(0, RuleEngine.cooldownSize); i++) {
      final pick = _bestForBlock(
        (e) => e.category == 'cooldown' && e.fitsDay(day),
        items,
        bonus: (e) => (e.splits.length == 1 ? 2.0 : 0.0) + (e.badminton != null ? 0.1 : 0.0),
      );
      if (pick == null) break;
      used.add(pick.id);
      items.add(pick);
    }
    return items;
  }

  /// Best exercise for warm-up, core and cool-down: floor exercises get [RuleEngine.floorPenalty], and once the
  /// block holds [RuleEngine.maxFloorPerBlock] of them only standing / station exercises qualify – unless none is
  /// left. Badminton relevance is only a tie-breaker.
  Exercise? _bestForBlock(bool Function(Exercise) filter, List<Exercise> block, {double Function(Exercise)? bonus}) {
    double score(Exercise e) => (bonus?.call(e) ?? 0) - (e.isFloor ? RuleEngine.floorPenalty : 0);
    final floorFull = block.where((e) => e.isFloor).length >= RuleEngine.maxFloorPerBlock;
    return (floorFull ? _bestOf((e) => !e.isFloor && filter(e), bonus: score) : null) ?? _bestOf(filter, bonus: score);
  }

  Exercise? _bestOf(bool Function(Exercise) filter, {double Function(Exercise)? bonus}) => _best(
        catalog.exercises.where((e) => _usable(e) && filter(e)),
        (e) =>
            _baseScore(e) +
            (e.compound ? 1 : 0) +
            (bonus?.call(e) ?? 0) +
            (legacy && ctx.recentExerciseIds.contains(e.id) ? RuleEngine.recentBonus : 0),
      );

  /// How saturated the primary muscles of [p] are: lowest (last training week ÷ goal) over its tracked primary
  /// muscles; ≥ 1 = at or above goal (cut first when time is short), 1 without balance data.
  double _saturation(_Pick p) {
    final bal = balance;
    if (bal == null) return 1;
    var s = double.infinity;
    for (final m in p.exercise.primary) {
      final st = bal.status(m);
      final goal = trackedMuscles.containsKey(m) ? ctx.focus.targetFor(m).goal : null;
      if (st == null || goal == null || goal <= 0) continue;
      s = math.min(s, (st.lastActiveWeek ?? st.recentAvg) / goal);
    }
    return s.isFinite ? s : 1;
  }

  // ------------------------------------------------------------------ spare time
  /// Effective sets planned today for [muscle] (primary 1, secondary ½).
  double _plannedSets(String muscle) => picks.fold(
      0.0,
      (s, p) =>
          s +
          (p.exercise.primary.contains(muscle)
              ? p.totalSets
              : p.exercise.secondary.contains(muscle)
                  ? secondarySetWeight * p.totalSets
                  : 0));

  /// How far [muscle] is from the middle of its weekly band (0 = there, 1 = nothing done). Spare time aims at the
  /// band's middle – more than the planning goal, still well under the maximum. With balance data the last training
  /// week plus today's plan counts; without it, today's plan (the muscle's home day comes once a week).
  double _deficit(String muscle) {
    final mid = trackedMuscles.containsKey(muscle) ? ctx.focus.targetFor(muscle).mid : 0.0;
    if (mid <= 0) return 0;
    final st = balance?.status(muscle);
    final planned = _plannedSets(muscle);
    final done = st == null ? planned : math.max(st.lastActiveWeek ?? st.recentAvg, planned);
    return math.max(0, 1 - done / mid);
  }

  /// Muscles of today's split worth extra work, most under-trained first; never muscles already above their band.
  /// (No 48 h check: these are today's own target muscles, which the template trains today anyway.)
  List<String> _fillMuscles() {
    final group = switch (day) { DayType.push => MuscleGroup.push, DayType.pull => MuscleGroup.pull, DayType.legs => MuscleGroup.legs };
    final out = <(String, double)>[];
    for (final m in trackedMuscleInfo.where((m) => m.group == group)) {
      if ((balance?.isHigh(m.id) ?? false) || ctx.focus.levelOf(m.id) == FocusLevel.less) continue;
      final need = _deficit(m.id);
      // "More" muscles go first, but only while they are under their (raised) target.
      final more = need > 0 && ctx.focus.levelOf(m.id) == FocusLevel.more ? 1.0 : 0.0;
      out.add((m.id, need + more + 2 * (balance?.priority(m.id)?.score ?? 0)));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (m, score) in out) if (score > 0) m];
  }

  /// Uses time left under the session length: first up to [RuleEngine.maxFillExercises] extra accessories for the
  /// least-trained muscles of the day, then +1 set on a few exercises (within [RuleEngine.maxSetsCompound] /
  /// [RuleEngine.maxSetsIsolation]). Rep ranges never grow to fill time. Not in deload weeks.
  void _fillSpareTime(int Function() total) {
    if (deload) return;
    final target = sessionMinutes * 60;
    final limit = target + RuleEngine.timeToleranceSeconds;
    final added = <String>[];
    const slot = SlotSpec(SlotRole.accessory, [], 'Extra time');
    for (final m in _fillMuscles()) {
      if (added.length >= RuleEngine.maxFillExercises || target - total() < RuleEngine.fillThresholdSeconds) break;
      final e = _best(
        catalog.exercises.where((e) => _usable(e) && e.category == 'strength' && e.fitsDay(day) && e.primary.contains(m)),
        (e) =>
            _slotScore(e, slot) +
            (e.compound ? 0 : 2) +
            (e.primary.first == m ? 1 : 0) +
            (ctx.history.containsKey(e.id) ? 0.5 : 0),
      );
      if (e == null) continue;
      final pick = _Pick(slot, e);
      _prescribe(pick);
      pick.notes = 'Extra time · ${prettyMuscle(m).toLowerCase()}';
      _assignWeight(pick);
      if (total() + pick.toItem().estimateSeconds() > limit) continue;
      used.add(e.id);
      picks.add(pick);
      added.add(e.name);
      if (!focus.contains(m)) focus.add(m);
    }

    // Then a set here and there, only where a primary muscle still needs volume: neediest first, accessories before
    // compounds; never past the caps.
    double need(_Pick p) => p.exercise.primary.where(trackedMuscles.containsKey).map(_deficit).fold(0.0, math.max);
    final plusOne = <String>[];
    final candidates = picks.where((p) => p.role != SlotRole.power && need(p) > 0).toList()
      ..sort((a, b) {
        final c = need(b).compareTo(need(a));
        return c != 0 ? c : (a.exercise.compound ? 1 : 0).compareTo(b.exercise.compound ? 1 : 0);
      });
    for (final p in candidates) {
      if (plusOne.length >= RuleEngine.maxFillSets || target - total() < RuleEngine.fillThresholdSeconds ~/ 2) break;
      final cap = p.exercise.compound ? RuleEngine.maxSetsCompound : RuleEngine.maxSetsIsolation;
      final perSet = p.toItem().estimateSeconds() ~/ math.max(1, p.totalSets);
      if (p.totalSets >= cap || total() + perSet > limit) continue;
      p.sets++;
      plusOne.add(p.exercise.name);
    }
    final what = [if (added.isNotEmpty) 'added ${added.join(', ')}', if (plusOne.isNotEmpty) '+1 set on ${plusOne.join(', ')}'];
    if (what.isNotEmpty) _otherLines.add('Extra time ($sessionMinutes min): ${what.join('; ')}');
    final left = ((target - total()) / 60).round();
    if (left >= RuleEngine.fillThresholdSeconds ~/ 60) {
      final under = _fillMuscles().where((m) => _deficit(m) > 0).map((m) => prettyMuscle(m).toLowerCase()).toList();
      final limited = added.length >= RuleEngine.maxFillExercises || plusOne.length >= RuleEngine.maxFillSets;
      _otherLines.add(under.isEmpty
          ? 'About $left min to spare: today\'s muscles are already at their weekly target, so more sets would mostly '
              'add fatigue. Finish early or add mobility work.'
          : limited
              ? 'About $left min to spare: the limit for extra work in one session is reached. '
                  '${_capitalizeList(under)} can still use more.'
              : 'About $left min to spare: ${under.take(3).join(', ')} can use more, but nothing suitable is left today.');
    }
  }

  static String _capitalizeList(List<String> names) => RuleEngine._capitalize(names.take(3).join(', '));

  /// Catalog prescription for warm-up / core / cool-down items, with the athlete's rest preference applied.
  PlanItem _item(Exercise e) {
    final item = PlanItem.fromExercise(e);
    return item.copyWith(restSeconds: ctx.scaleRest(item.restSeconds));
  }

  // ------------------------------------------------------------------ assembly
  GeneratedWorkout build() {
    _buildMain();
    _applyBalance();
    _addFlex();
    for (final p in picks) {
      _assignWeight(p);
    }
    final warmup = _warmup().map(_item).toList();
    // Core: two exercises × 2 sets cover abs / obliques / lower back across three sessions a week.
    final core = includeCore
        ? _core().map((e) => _item(e).copyWith(sets: math.min(e.sets, 2))).toList()
        : <PlanItem>[];
    final cooldown = _cooldown().map(_item).toList();

    // Order: power → anchor → secondary → accessories → flex.
    const order = {SlotRole.power: 0, SlotRole.anchor: 1, SlotRole.secondary: 2, SlotRole.accessory: 3, SlotRole.flex: 4};
    picks.sort((a, b) => order[a.role]!.compareTo(order[b.role]!));

    int total() =>
        [...warmup, ...core, ...cooldown].fold<int>(0, (s, i) => s + i.estimateSeconds()) +
        picks.fold<int>(0, (s, p) => s + p.toItem().estimateSeconds());
    final budget = sessionMinutes * 60 + RuleEngine.timeToleranceSeconds;
    bool over() => total() > budget;
    int mainCount() => picks.length;
    final dropped = <String>[];

    // Time fitting – least valuable work goes first. The first power exercise of the week is protected until the
    // accessory volume has been trimmed; any further one goes first.
    final protectPower = _powerThisWeek() == 0;
    final spareDrill = _warmupDrills > 2 && warmup.length > 2 ? warmup.removeLast() : null;
    void dropPower() {
      for (final p in picks.where((p) => p.role == SlotRole.power).toList()) {
        if (over()) picks.remove(p);
      }
    }

    if (!protectPower) dropPower();
    if (over() && core.length > 1 && balance != null) {
      // Abs / obliques usually exceed their band: drop a core exercise whose muscles are all above target.
      final idx = core.indexWhere((i) {
        final muscles = catalog.exercise(i.exerciseId)?.primary.where(trackedMuscles.containsKey).toList() ?? const [];
        return muscles.isNotEmpty && muscles.every(balance!.isHigh);
      });
      if (idx >= 0) core.removeAt(idx);
    }
    for (final p in picks.where((p) => p.role == SlotRole.flex)) {
      if (over() && p.totalSets > 2) p.sets--;
    }
    // Trim accessories whose muscles are already at / above their goal first, the most saturated first.
    final trimmable = picks.where((p) => p.role == SlotRole.accessory && p.extra <= 0).toList()
      ..sort((a, b) => _saturation(b).compareTo(_saturation(a)));
    for (final p in trimmable.where((p) => _saturation(p) >= 1)) {
      if (over() && p.totalSets > 2) p.sets--;
    }
    for (final p in picks.where((p) => p.role == SlotRole.power)) {
      if (over() && p.totalSets > 2) p.sets--;
    }
    for (final p in trimmable) {
      if (over() && p.totalSets > 2) p.sets--;
    }
    dropPower();
    for (final p in picks.where((p) => p.role == SlotRole.flex).toList()) {
      if (over()) {
        picks.remove(p);
        focus.remove(p.flexMuscle);
        _balanceLines.removeWhere((l) => l.startsWith('Flex:'));
      }
    }
    for (final p in picks.where((p) => p.role == SlotRole.accessory).toList()
      ..sort((a, b) {
        final e = a.extra.compareTo(b.extra);
        return e != 0 ? e : _saturation(b).compareTo(_saturation(a));
      })) {
      if (over() && mainCount() > 3) {
        picks.remove(p);
        dropped.add(p.exercise.name);
      }
    }
    for (final p in picks) {
      if (over() && p.role == SlotRole.anchor && p.totalSets > 3) p.sets--;
      if (over() && p.role == SlotRole.secondary && p.totalSets > 2) p.sets--;
    }
    for (final p in picks.reversed.toList()) {
      if (over() && mainCount() > 3 && p.role != SlotRole.anchor) {
        picks.remove(p);
        dropped.add(p.exercise.name);
      }
    }
    _fillSpareTime(total);
    if (spareDrill != null && total() + spareDrill.estimateSeconds() <= budget) warmup.add(spareDrill);
    if (dropped.isNotEmpty) _otherLines.add('Time budget ($sessionMinutes min): skipped ${dropped.join(', ')}');
    for (final p in picks.where((p) => p.role == SlotRole.power)) {
      _otherLines.add('Power: ${p.exercise.name} (badminton support, ${_powerThisWeek() + 1} of max '
          '${RuleEngine.maxPowerPerWeek} this week)');
    }

    final main = picks.map((p) => p.toItem()).toList();
    final blocks = [
      PlanBlock(section: Section.warmup, items: warmup),
      PlanBlock(section: Section.main, items: main),
      if (core.isNotEmpty) PlanBlock(section: Section.core, items: core),
      if (cooldown.isNotEmpty) PlanBlock(section: Section.cooldown, items: cooldown),
    ];

    final rationale = _rationale();
    final meta = PlanMeta(
      program: state.labelFor(day),
      variant: state.variant,
      deload: deload,
      focus: List.unmodifiable(focus),
      rationale: rationale,
    );
    return GeneratedWorkout(
      title: '${day.label} ${state.variant} · ${deload ? 'Deload' : template.title}',
      coachNote: _coachNote(),
      blocks: blocks,
      estimatedMinutes: estimateMinutes(blocks),
      rationale: rationale,
      focusMuscles: List.unmodifiable(focus),
      meta: meta,
      roles: {for (final p in picks) p.exercise.id: p.role},
    );
  }

  String _coachNote() {
    if (deload) {
      return 'Deload week: about 90 % of your usual weights, one set fewer, and stop 3–4 reps short. '
          'Recovering now sets up the next block.';
    }
    return 'Target: ${rirPhrase(state.targetRir)} on every working set. When all sets reach the top of the rep '
        'range, add the smallest weight step next time.';
  }

  List<String> _rationale() {
    final lines = <String>[];
    if (deload) {
      lines.add('${state.deloadReason ?? 'Deload'}: −1 set, ~90 % load, RIR 3–4');
    } else {
      lines.add('${state.labelFor(day)}: ${template.focus}, target RIR ${state.rirLabel}');
    }
    final limitationNames = ctx.limitations.activeLimitations
        .where((l) => l.affectedExercises > 0)
        .take(2)
        .map((l) => l.region != null
            ? '${prettyRegion(l.region!)} ${l.kind.id} (${l.severityLabel}): ${l.effect.toLowerCase()}'
            : '${l.effect} (${l.kind.id})')
        .toList();
    final candidates = [
      ...limitationNames,
      ..._limitLines,
      ..._balanceLines,
      ..._anchorLines,
      ..._feedbackLines,
      ..._otherLines,
    ];
    for (final c in candidates) {
      if (lines.length >= 6) break;
      if (!lines.contains(c)) lines.add(c);
    }
    return lines;
  }
}

String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
