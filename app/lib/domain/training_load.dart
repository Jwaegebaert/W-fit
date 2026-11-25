/// Training-load analytics: effective (fractional) sets per muscle and ISO week, balance status and priorities
/// against the targets in `muscles.dart`, and per-exercise progression trends.
///
/// Pure Dart; shared by the rule engine, the coach brief and the balance UI so all three use the same numbers.
library;

import 'dart:math' as math;

import 'catalog.dart';
import 'muscles.dart';
import 'plan.dart';
import 'progression.dart';
import 'stats.dart';

/// Catalog categories whose completed working sets count toward muscle volume.
const Set<String> volumeCategories = {'strength', 'power', 'core'};

/// Movement patterns used for the push:pull ratio (horizontal + vertical pressing vs pulling).
const Set<String> pushPatterns = {'horizontal_push', 'incline_push', 'vertical_push'};
const Set<String> pullPatterns = {'horizontal_pull', 'vertical_pull'};

/// A completed set that counts as work (warm-up / cool-down sections never do).
bool isWorkingSet(LoggedSet s) => s.completed && s.section != 'warmup' && s.section != 'cooldown';

/// Effective sets per tracked muscle for [sets] sets of [e]: 1.0 per primary muscle, [secondarySetWeight] per
/// secondary muscle. Only `strength`, `power` and `core` exercises count; untracked muscles (e.g. `full_body`)
/// are ignored.
Map<String, double> effectiveSetsFor(Exercise e, num sets) {
  final out = <String, double>{};
  if (!volumeCategories.contains(e.category) || sets <= 0) return out;
  for (final m in e.primary) {
    if (trackedMuscles.containsKey(m)) out[m] = (out[m] ?? 0) + sets.toDouble();
  }
  for (final m in e.secondary) {
    if (trackedMuscles.containsKey(m) && !e.primary.contains(m)) {
      out[m] = (out[m] ?? 0) + sets * secondarySetWeight;
    }
  }
  return out;
}

/// Planned effective sets per muscle for plan items (unknown exercises are skipped).
Map<String, double> plannedMuscleVolume(Iterable<PlanItem> items, Catalog catalog) {
  final out = <String, double>{};
  for (final i in items) {
    final e = catalog.exercise(i.exerciseId);
    if (e == null) continue;
    effectiveSetsFor(e, i.sets).forEach((m, v) => out[m] = (out[m] ?? 0) + v);
  }
  return out;
}

/// Effective sets per tracked muscle in one ISO week (Monday start).
class MuscleWeek {
  MuscleWeek(this.weekStart);

  final DateTime weekStart;

  /// muscle → effective sets (primary 1.0, secondary 0.5).
  final Map<String, double> sets = {};

  /// muscle → sets in which the muscle was a primary target.
  final Map<String, double> primarySets = {};
  final Set<String> sessionIds = {};

  int get sessions => sessionIds.length;
  double of(String muscle) => sets[muscle] ?? 0;
  double get total => sets.values.fold(0.0, (a, b) => a + b);

  Map<String, dynamic> toJson() => {
        'weekStart': isoDate(weekStart),
        'sessions': sessions,
        'sets': {for (final e in sets.entries) e.key: _r1(e.value)},
      };
}

/// Effective sets per muscle for the last [weeks] ISO weeks (oldest first; the last entry is the current week).
List<MuscleWeek> weeklyMuscleVolume(Iterable<LoggedSet> sets, Catalog catalog, {int weeks = 8, DateTime? now}) {
  final current = startOfWeek(dateOnly(now ?? DateTime.now()));
  final list = List.generate(weeks, (i) => MuscleWeek(addDays(current, -7 * (weeks - 1 - i))));
  final byStart = {for (final w in list) w.weekStart: w};
  for (final s in sets) {
    if (!isWorkingSet(s)) continue;
    final w = byStart[startOfWeek(dateOnly(s.date))];
    if (w == null) continue;
    w.sessionIds.add(s.sessionId);
    final e = catalog.exercise(s.exerciseId);
    if (e == null) continue;
    effectiveSetsFor(e, 1).forEach((m, v) => w.sets[m] = (w.sets[m] ?? 0) + v);
    if (volumeCategories.contains(e.category)) {
      for (final m in e.primary.where(trackedMuscles.containsKey)) {
        w.primarySets[m] = (w.primarySets[m] ?? 0) + 1;
      }
    }
  }
  return list;
}

enum VolumeStatus { under, ok, high }

enum VolumeTrend { up, flat, down }

/// Weekly volume status of one tracked muscle (see `analyzeBalance`).
class MuscleStatus {
  const MuscleStatus({
    required this.muscle,
    required this.thisWeek,
    required this.lastWeek,
    required this.recentAvg,
    required this.targetMin,
    required this.targetMax,
    required this.status,
    required this.weeksUnder,
    required this.daysSinceTrained,
    required this.trend,
    this.lastActiveWeek,
  });

  final String muscle;

  /// Effective sets in the current ISO week so far.
  final double thisWeek;

  /// Effective sets in the previous ISO week.
  final double lastWeek;

  /// Average over the last 3 completed weeks that had ≥ 1 session (deload weeks excluded when known).
  final double recentAvg;
  final double targetMin;
  final double targetMax;
  final VolumeStatus status;

  /// Consecutive completed training weeks (newest first) below [targetMin].
  final int weeksUnder;

  /// Days since the last set with this muscle as a primary target (null = not in the analysed window).
  final int? daysSinceTrained;
  final VolumeTrend trend;

  /// Effective sets in the most recent completed training week (null when there is none).
  final double? lastActiveWeek;

  MuscleInfo get info => trackedMuscles[muscle]!;
  String get label => info.label;

  /// Progress toward the minimum this week (0–1+), handy for progress bars.
  double get weekProgress => targetMin <= 0 ? 1 : thisWeek / targetMin;

  Map<String, dynamic> toBrief() => {
        'muscle': muscle,
        'thisWeek': _r1(thisWeek),
        'lastWeek': _r1(lastWeek),
        'recentAvg': _r1(recentAvg),
        'targetMin': targetMin,
        'targetMax': targetMax,
        'status': status.name,
        'weeksUnder': weeksUnder,
        'daysSinceTrained': daysSinceTrained,
        'trend': trend.name,
      };
}

/// A muscle that should get extra attention in the next sessions.
class MusclePriority {
  const MusclePriority({required this.muscle, required this.score, required this.extraSets, required this.reason});

  final String muscle;

  /// 0–1; higher = more urgent.
  final double score;

  /// Extra working sets the planner should add this week (0–2).
  final int extraSets;
  final String reason;

  String get label => trackedMuscles[muscle]?.label ?? prettyMuscle(muscle);

  Map<String, dynamic> toBrief() =>
      {'muscle': muscle, 'score': _r2(score), 'extraSets': extraSets, 'reason': reason};
}

/// Multi-week muscle balance: status per tracked muscle, priorities, antagonist ratios and notes.
class BalanceReport {
  const BalanceReport({
    required this.asOf,
    required this.muscles,
    required this.priorities,
    this.pushPullRatio,
    this.quadHamRatio,
    this.groupShare = const {},
    this.notes = const [],
  });

  /// Empty report (no data).
  factory BalanceReport.empty(DateTime asOf) => BalanceReport(asOf: dateOnly(asOf), muscles: const [], priorities: const []);

  /// Date the report was computed for (day precision); the engine shifts `daysSinceTrained` to the plan date.
  final DateTime asOf;
  final List<MuscleStatus> muscles;

  /// Sorted by score (highest first); only muscles with extraSets ≥ 1.
  final List<MusclePriority> priorities;

  /// Pressing sets ÷ pulling sets over the last 4 weeks (null without data).
  final double? pushPullRatio;

  /// Quad ÷ hamstring effective sets over the last 4 weeks (null without data).
  final double? quadHamRatio;

  /// Share of effective sets per group over the last 4 weeks (sums to 1 when there is data).
  final Map<MuscleGroup, double> groupShare;
  final List<String> notes;

  MuscleStatus? status(String muscle) {
    for (final m in muscles) {
      if (m.muscle == muscle) return m;
    }
    return null;
  }

  MusclePriority? priority(String muscle) {
    for (final p in priorities) {
      if (p.muscle == muscle) return p;
    }
    return null;
  }

  bool isHigh(String muscle) => status(muscle)?.status == VolumeStatus.high;

  /// Days since [muscle] was trained as of [date] (null = unknown / never).
  int? daysSinceTrainedOn(String muscle, DateTime date) {
    final d = status(muscle)?.daysSinceTrained;
    return d == null ? null : d + daysBetween(asOf, date);
  }

  /// `balance` object of the coach brief (docs/IMPROVEMENT-PLAN.md §4.4).
  Map<String, dynamic> toBrief() => {
        'muscles': muscles.map((m) => m.toBrief()).toList(),
        'priorities': priorities.map((p) => p.toBrief()).toList(),
        'ratios': {'pushPull': _r2n(pushPullRatio), 'quadHam': _r2n(quadHamRatio)},
        'notes': notes,
      };
}

/// Balance status and priorities from weekly volumes ([weeks] from [weeklyMuscleVolume]) and the raw [sets]
/// (used for days-since-trained and the ratios).
///
/// [deloadWeeks] (any date inside each deload week, e.g. `ProgramState.deloadWeekStarts`) are ignored for averages,
/// streaks and carry-over, so a planned low-volume week never triggers catch-up volume.
///
/// Priority score (0–1) = 0.35·last training week's deficit vs min + 0.2·recent-average deficit vs min
/// + 0.15·weeks-under streak + 0.15·staleness (> 8 days, only while below the goal) + 0.15·shortfall vs the planning goal
/// (`MuscleTarget.goal`, lower quarter of the band). It is 0 once this week already reached the goal or the muscle
/// is above its maximum. extraSets: score ≥ 0.45 → 2, any shortfall → 1. Shortfalls inside the current week are
/// handled by the rule engine, which knows which day types were already trained.
BalanceReport analyzeBalance(
  List<MuscleWeek> weeks,
  Iterable<LoggedSet> sets,
  Catalog catalog, {
  DateTime? now,
  Iterable<DateTime> deloadWeeks = const [],
  MuscleFocus focus = MuscleFocus.none,
}) {
  final today = dateOnly(now ?? DateTime.now());
  final currentStart = startOfWeek(today);
  final deload = {for (final d in deloadWeeks) startOfWeek(dateOnly(d))};
  final sorted = [...weeks]..sort((a, b) => a.weekStart.compareTo(b.weekStart));
  MuscleWeek? current;
  for (final w in sorted) {
    if (w.weekStart == currentStart) current = w;
  }
  final completed = sorted.where((w) => w.weekStart.isBefore(currentStart)).toList().reversed.toList();
  final active = completed.where((w) => w.sessions > 0 && !deload.contains(w.weekStart)).toList();
  final lastWeekStart = addDays(currentStart, -7);
  MuscleWeek? lastWeekObj;
  for (final w in completed) {
    if (w.weekStart == lastWeekStart) lastWeekObj = w;
  }
  final hasHistory = active.isNotEmpty;

  // Last primary-trained day per muscle and pressing / pulling sets in the 4-week window.
  final windowStart = addDays(currentStart, -21);
  final lastTrained = <String, DateTime>{};
  var pushSets = 0;
  var pullSets = 0;
  for (final s in sets) {
    if (!isWorkingSet(s)) continue;
    final e = catalog.exercise(s.exerciseId);
    if (e == null || !volumeCategories.contains(e.category)) continue;
    final d = dateOnly(s.date);
    if (d.isAfter(today)) continue;
    for (final m in e.primary.where(trackedMuscles.containsKey)) {
      final prev = lastTrained[m];
      if (prev == null || d.isAfter(prev)) lastTrained[m] = d;
    }
    if (!d.isBefore(windowStart) && e.category == 'strength') {
      if (pushPatterns.contains(e.pattern)) pushSets++;
      if (pullPatterns.contains(e.pattern)) pullSets++;
    }
  }

  final window = sorted.where((w) => !w.weekStart.isBefore(windowStart) && !w.weekStart.isAfter(currentStart));
  double windowSum(String m) => window.fold(0.0, (a, w) => a + w.of(m));

  final statuses = <MuscleStatus>[];
  final priorities = <MusclePriority>[];
  final notes = <String>[];
  for (final info in trackedMuscleInfo) {
    final m = info.id;
    // The athlete's muscle focus scales the band (less / more), so status and priorities follow it.
    final target = focus.targetFor(m);
    final min = target.min;
    final max = target.max;
    final thisWeek = current?.of(m) ?? 0;
    final lastWeek = lastWeekObj?.of(m) ?? 0;
    final recent = active.take(3).map((w) => w.of(m)).toList();
    final recentAvg = recent.isEmpty ? 0.0 : recent.reduce((a, b) => a + b) / recent.length;
    final lastActive = hasHistory ? active.first.of(m) : null;
    final weeksUnder = active.takeWhile((w) => w.of(m) < min).length;
    final last = lastTrained[m];
    final daysSince = last == null ? null : daysBetween(last, today);

    var trend = VolumeTrend.flat;
    if (active.length >= 2) {
      final v0 = active[0].of(m);
      final prev = active.skip(1).take(2).map((w) => w.of(m)).toList();
      final prevAvg = prev.reduce((a, b) => a + b) / prev.length;
      if (v0 > prevAvg * 1.15 && v0 - prevAvg >= 1) trend = VolumeTrend.up;
      if (v0 < prevAvg * 0.85 && prevAvg - v0 >= 1) trend = VolumeTrend.down;
    }

    final ref = thisWeek >= min ? thisWeek : (lastActive ?? thisWeek);
    final peak = math.max(thisWeek, lastActive ?? 0);
    final status = peak > max
        ? VolumeStatus.high
        : ref < min
            ? VolumeStatus.under
            : VolumeStatus.ok;
    statuses.add(MuscleStatus(
      muscle: m,
      thisWeek: thisWeek,
      lastWeek: lastWeek,
      recentAvg: recentAvg,
      targetMin: min,
      targetMax: max,
      status: status,
      weeksUnder: weeksUnder,
      daysSinceTrained: daysSince,
      trend: trend,
      lastActiveWeek: lastActive,
    ));

    // ---- priority ----
    final goal = target.goal;
    double deficit(double v) => ((min - v) / min).clamp(0.0, 1.0);
    final lastDef = lastActive == null ? 0.0 : deficit(lastActive);
    final goalDef = lastActive == null || lastActive >= goal ? 0.0 : ((goal - lastActive) / goal).clamp(0.0, 1.0);
    final avgDef = recent.isEmpty ? 0.0 : deficit(recentAvg);
    final streak = math.min(weeksUnder, 3) / 3;
    final stale = !hasHistory || (lastActive != null && lastActive >= goal)
        ? 0.0
        : daysSince == null
            ? 1.0
            : ((daysSince - 8) / 7).clamp(0.0, 1.0);
    var score = 0.35 * lastDef + 0.2 * avgDef + 0.15 * streak + 0.15 * stale + 0.15 * goalDef;
    if (thisWeek >= goal || status == VolumeStatus.high) score = 0;
    score = score.clamp(0.0, 1.0);
    final extra = score >= 0.45 ? 2 : (score > 0 ? 1 : 0);
    if (extra > 0) {
      final reasons = <String>[];
      if (lastActive != null && lastActive < goal) {
        final when = active.first.weekStart == lastWeekStart ? 'last week' : 'last training week';
        reasons.add(lastActive < min
            ? '${_fmt(lastActive)}/${_fmt(min)} sets $when'
            : '${_fmt(lastActive)} sets $when, goal ${_fmt(goal)}');
      }
      if (weeksUnder >= 2) reasons.add('below target $weeksUnder weeks running');
      if (avgDef > 0 && lastDef == 0) reasons.add('avg ${_fmt(recentAvg)}/${_fmt(min)} over recent weeks');
      if (stale >= 0.3) reasons.add(daysSince == null ? 'not trained recently' : 'not trained for $daysSince days');
      priorities.add(MusclePriority(
        muscle: m,
        score: score,
        extraSets: extra,
        reason: reasons.isEmpty ? 'below target' : reasons.join(', '),
      ));
    }

    // ---- notes ----
    final last4 = active.take(4).toList();
    final under4 = last4.where((w) => w.of(m) < min).length;
    if (last4.length >= 3 && under4 >= 3) {
      notes.add('${info.label} below target in $under4 of the last ${last4.length} weeks');
    } else if (weeksUnder >= 2) {
      notes.add('${info.label} below target $weeksUnder weeks running');
    }
    if (hasHistory && daysSince != null && daysSince >= 10) {
      notes.add('${info.label} not trained for $daysSince days');
    }
    if (lastActive != null && lastActive > max) {
      notes.add('${info.label} above target (${_fmt(lastActive)} sets, max ${_fmt(max)})');
    }
  }
  priorities.sort((a, b) => b.score.compareTo(a.score));

  final quads = windowSum('quads');
  final hams = windowSum('hamstrings');
  final pushPull = pushSets > 0 && pullSets > 0 ? pushSets / pullSets : null;
  final quadHam = quads > 0 && hams > 0 ? quads / hams : null;
  if (pushPull != null && pushPull > 1.3) {
    notes.add('Push:pull ratio ${pushPull.toStringAsFixed(2)} – pulling is behind');
  } else if (pushPull != null && pushPull < 0.7) {
    notes.add('Push:pull ratio ${pushPull.toStringAsFixed(2)} – pressing is behind');
  }
  if (quadHam != null && quadHam > 2.0) {
    notes.add('Quads:hamstrings ${quadHam.toStringAsFixed(2)} – hamstrings are behind');
  } else if (quadHam != null && quadHam < 0.8) {
    notes.add('Quads:hamstrings ${quadHam.toStringAsFixed(2)} – quads are behind');
  }

  final groupTotals = <MuscleGroup, double>{};
  for (final info in trackedMuscleInfo) {
    groupTotals[info.group] = (groupTotals[info.group] ?? 0) + windowSum(info.id);
  }
  final total = groupTotals.values.fold(0.0, (a, b) => a + b);
  final share = total <= 0 ? <MuscleGroup, double>{} : {for (final e in groupTotals.entries) e.key: e.value / total};

  return BalanceReport(
    asOf: today,
    muscles: statuses,
    priorities: priorities,
    pushPullRatio: pushPull,
    quadHamRatio: quadHam,
    groupShare: share,
    notes: notes.take(8).toList(),
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Exercise progression trends
// ---------------------------------------------------------------------------------------------------------------

/// Progression trend of one exercise over its last 3–4 exposures.
enum ExerciseTrend {
  progressing,
  stalled,
  regressing,

  /// Fewer than 2–3 exposures – not enough data. Serialised as `new`.
  isNew;

  String get id => this == ExerciseTrend.isNew ? 'new' : name;

  static ExerciseTrend parse(String? id) => switch (id) {
        'progressing' => ExerciseTrend.progressing,
        'stalled' => ExerciseTrend.stalled,
        'regressing' => ExerciseTrend.regressing,
        _ => ExerciseTrend.isNew,
      };
}

/// Summary of one session's sets for one exercise.
class Exposure {
  Exposure(List<LoggedSet> session)
      : date = session.isEmpty ? DateTime(1970) : session.first.date,
        _sets = session.where((s) => s.completed && ((s.reps ?? 0) > 0 || (s.durationSeconds ?? 0) > 0)).toList() {
    for (final s in _sets) {
      final w = s.weightKg ?? 0;
      final r = s.reps ?? 0;
      if (w > topWeight) topWeight = w;
      e1rm = math.max(e1rm, estimatedOneRepMax(w, r));
      bestDuration = math.max(bestDuration, s.durationSeconds ?? 0);
    }
    for (final s in _sets) {
      if ((s.weightKg ?? 0) == topWeight) {
        bestReps = math.max(bestReps, s.reps ?? 0);
        totalReps += s.reps ?? 0;
      }
    }
  }

  final DateTime date;
  final List<LoggedSet> _sets;
  double topWeight = 0;
  double e1rm = 0;
  int bestReps = 0;
  int totalReps = 0;
  int bestDuration = 0;

  bool get isEmpty => _sets.isEmpty;

  /// Single comparable number: e1RM for loaded sets, else best reps, else best duration.
  double get metric => e1rm > 0 ? e1rm : (bestReps > 0 ? bestReps.toDouble() : bestDuration.toDouble());

  /// "52.5x10, 52.5x9" for loaded sets, "BWx12" for bodyweight reps, "30s" for timed sets.
  String get setsLabel => _sets.map((s) {
        if ((s.reps ?? 0) > 0) {
          final w = s.weightKg ?? 0;
          return w > 0 ? '${formatKg(w)}x${s.reps}' : 'BWx${s.reps}';
        }
        return '${s.durationSeconds}s';
      }).join(', ');

  /// +1 if this exposure beats [other], −1 if it is worse, 0 if equivalent.
  int compareTo(Exposure other) {
    if (topWeight > 0 || other.topWeight > 0) {
      if (topWeight > other.topWeight + 1e-6) return 1;
      if (topWeight < other.topWeight - 1e-6) return e1rm > other.e1rm * 1.01 ? 1 : -1;
      if (bestReps != other.bestReps) return bestReps > other.bestReps ? 1 : -1;
      if (totalReps != other.totalReps) return totalReps > other.totalReps ? 1 : -1;
      return 0;
    }
    if (bestReps > 0 || other.bestReps > 0) {
      if (bestReps != other.bestReps) return bestReps > other.bestReps ? 1 : -1;
      if (totalReps != other.totalReps) return totalReps > other.totalReps ? 1 : -1;
      return 0;
    }
    return bestDuration.compareTo(other.bestDuration).sign;
  }
}

/// Trend from [history] (sets of one exercise grouped per session, most recent first – the same shape as
/// `adviseProgression`). Uses the last 4 exposures:
/// progressing = the latest exposure beats the previous one (more load, or more reps at the same load), or beats
/// the one before that; regressing = two declines in a row or a > 10 % drop below the window's best;
/// stalled = no progress over the last 3 exposures; new = fewer than 2 exposures (or 2 without a clear change).
ExerciseTrend exerciseTrend(List<List<LoggedSet>> history) {
  final xs = history.map(Exposure.new).where((x) => !x.isEmpty).take(4).toList();
  if (xs.length < 2) return ExerciseTrend.isNew;
  final t0 = xs[0].compareTo(xs[1]);
  final best = xs.skip(1).map((x) => x.metric).reduce(math.max);
  final bigDrop = best > 0 && xs[0].metric < best * 0.9;
  if (xs.length == 2) {
    if (t0 > 0) return ExerciseTrend.progressing;
    if (t0 < 0 && bigDrop) return ExerciseTrend.regressing;
    return ExerciseTrend.isNew;
  }
  if (t0 > 0) return ExerciseTrend.progressing;
  final t1 = xs[1].compareTo(xs[2]);
  if ((t0 < 0 && t1 < 0) || bigDrop) return ExerciseTrend.regressing;
  if (xs[0].compareTo(xs[2]) > 0) return ExerciseTrend.progressing;
  return ExerciseTrend.stalled;
}

/// Groups completed sets per exercise and session: exerciseId → sessions (most recent first) → sets in order.
/// Sessions in [excludeSessionIds] (e.g. deload sessions) are skipped.
Map<String, List<List<LoggedSet>>> groupHistory(Iterable<LoggedSet> sets, {Set<String> excludeSessionIds = const {}}) {
  final byExercise = <String, Map<String, List<LoggedSet>>>{};
  for (final s in sets) {
    if (!s.completed || excludeSessionIds.contains(s.sessionId)) continue;
    byExercise.putIfAbsent(s.exerciseId, () => {}).putIfAbsent(s.sessionId, () => []).add(s);
  }
  return {
    for (final e in byExercise.entries)
      e.key: (e.value.values.toList()
        ..sort((a, b) {
          final c = b.first.date.compareTo(a.first.date);
          return c != 0 ? c : b.first.sessionId.compareTo(a.first.sessionId);
        })),
  };
}

/// Trend per exercise for all exercises in [sets].
Map<String, ExerciseTrend> exerciseTrends(Iterable<LoggedSet> sets, {Set<String> excludeSessionIds = const {}}) => {
      for (final e in groupHistory(sets, excludeSessionIds: excludeSessionIds).entries) e.key: exerciseTrend(e.value),
    };

/// `exerciseHistory` entries of the coach brief (docs/IMPROVEMENT-PLAN.md §4.4): the [maxExercises] most recently
/// performed strength / power / core exercises of the last [weeks] weeks, each with its trend and up to
/// [maxExposures] exposures (`{date, sets, e1rm}`).
List<Map<String, dynamic>> exerciseHistoryBrief(
  Iterable<LoggedSet> sets, {
  Catalog? catalog,
  DateTime? now,
  int maxExercises = 25,
  int maxExposures = 4,
  int weeks = 12,
  Set<String> excludeSessionIds = const {},
}) {
  final today = dateOnly(now ?? DateTime.now());
  final since = addDays(today, -7 * weeks);
  final relevant = sets.where((s) {
    if (!isWorkingSet(s)) return false;
    final d = dateOnly(s.date);
    if (d.isBefore(since) || d.isAfter(today)) return false;
    if (catalog == null) return true;
    final e = catalog.exercise(s.exerciseId);
    return e != null && volumeCategories.contains(e.category);
  });
  final grouped = groupHistory(relevant, excludeSessionIds: excludeSessionIds).entries.toList()
    ..sort((a, b) {
      final c = b.value.first.first.date.compareTo(a.value.first.first.date);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return [
    for (final g in grouped.take(maxExercises))
      {
        'exerciseId': g.key,
        'trend': exerciseTrend(g.value).id,
        'lastPerformed': isoDate(g.value.first.first.date),
        // Logged kg are plates only for bar exercises; barKg is the empty bar on top.
        if (g.value.first.first.barKg > 0) 'barKg': g.value.first.first.barKg,
        // Numbered stack: the sets below are real kg, the athlete works with plate numbers.
        'plateKg': ?catalog?.exercise(g.key)?.plateKg,
        'exposures': [
          for (final x in g.value.take(maxExposures).map(Exposure.new))
            {'date': isoDate(x.date), 'sets': x.setsLabel, 'e1rm': x.e1rm > 0 ? _r1(x.e1rm) : null},
        ],
      },
  ];
}

double _r1(double v) => (v * 10).roundToDouble() / 10;
double _r2(double v) => (v * 100).roundToDouble() / 100;
double? _r2n(double? v) => v == null ? null : _r2(v);
String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
