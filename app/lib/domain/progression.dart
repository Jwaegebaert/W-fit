import 'dart:math' as math;

import 'catalog.dart';

/// Lightweight, storage-agnostic view of a logged set.
class LoggedSet {
  const LoggedSet({
    required this.sessionId,
    required this.exerciseId,
    required this.date,
    this.weightKg,
    this.reps,
    this.durationSeconds,
    this.completed = true,
    this.section,
    this.rir,
    this.barKg = 0,
    this.assisted = false,
  });

  final String sessionId;
  final String exerciseId;
  final DateTime date;
  final double? weightKg;
  final int? reps;
  final int? durationSeconds;
  final bool completed;

  /// Plan section name (`warmup` | `main` | `core` | `cooldown`) when known. Warm-up and cool-down sets never
  /// count as working sets.
  final String? section;

  /// Reps in reserve reported for the set, when captured.
  final int? rir;

  /// Empty-bar weight on top of the logged plates ([weightKg] is plates only for bar exercises).
  final double barKg;

  /// Assisted machine: [weightKg] is assistance, not load.
  final bool assisted;

  /// Real load lifted: plates + bar; null for assisted sets or when no weight was logged. Statistics use this;
  /// progression keeps working in logged (plate) kg.
  double? get loadKg => assisted || weightKg == null ? null : weightKg! + barKg;

  double get volume => (loadKg ?? 0) * (reps ?? 0);
}

/// Epley estimated one-rep max. Only meaningful for loaded sets of 1–12 reps.
double estimatedOneRepMax(double weightKg, int reps) {
  if (weightKg <= 0 || reps <= 0) return 0;
  if (reps == 1) return weightKg;
  return weightKg * (1 + math.min(reps, 12) / 30);
}

double roundToStep(double value, double step) {
  if (step <= 0) return value;
  final unit = step >= 2.5 ? step : 0.5;
  return (value / unit).round() * unit;
}

/// [kg] rounded to what can be loaded for [e].
double _round(Exercise e, double kg) => e.plateKg == null ? roundToStep(kg, e.incrementKg) : e.snapKg(kg);

/// About 10 % lighter; on a numbered stack at least one plate.
double _lighter(Exercise e, double kg) => switch (e.plateKg) {
      final plate? => math.max(1, (kg * 0.9 / plate + 0.01).floor()) * plate,
      _ => roundToStep(kg * 0.9, e.incrementKg),
    };

/// "35 kg", or "plate 7" on a numbered stack.
String _load(Exercise e, double kg) =>
    e.plateKg == null ? '${_fmt(kg)} kg' : 'plate ${formatPlate(kg / e.plateKg!)}';

class ProgressionAdvice {
  const ProgressionAdvice({this.weightKg, this.targetReps, required this.message, this.lastSummary});

  /// The advice for a plan that prescribes [planKg] itself (coach, deload, go light). When that differs from the weight
  /// advised here, its reps and wording no longer fit, so the aim becomes the bottom of the range ([repMin]).
  ProgressionAdvice forPlanWeight(double? planKg, {required int? repMin, required bool assisted}) {
    final own = weightKg;
    if (planKg == null || own == null || repMin == null || (planKg - own).abs() < 0.01) return this;
    final heavier = assisted ? planKg < own : planKg > own;
    return ProgressionAdvice(
      weightKg: planKg,
      targetReps: repMin,
      message: heavier ? 'A step up from last time – aim for $repMin good reps.' : 'Lighter today – $repMin controlled reps.',
      lastSummary: lastSummary,
    );
  }

  final double? weightKg;
  final int? targetReps;
  final String message;
  final String? lastSummary;
}

/// Human label for a target RIR, e.g. "2 reps in reserve".
String rirPhrase(int rir) => rir == 1 ? '1–2 reps in reserve' : '$rir reps in reserve';

/// Double progression for beginners.
///
/// [history] contains completed sets for one exercise, grouped per session, most recent session first.
/// [repMin]/[repMax] override the catalog range (use the plan's prescription).
///
/// Optional v3 adjustments:
/// * [deload] – deload week: ~90 % of the normal working weight, bottom of the rep range.
/// * [incrementSteps] – feedback adjustment in weight increments (`too_hard` → −1, `too_easy` → +1).
/// * [targetRir] – adds reps-in-reserve guidance to the message.
/// * [holdOnStruggle] – keep the weight instead of the ~10 % reset after two sessions below the range (used for
///   anchor lifts inside a block, where the deload / next block handles resets).
/// * [light] – the athlete's "go light" setting: a weight last used below [repMin] is too heavy for the light rep
///   range and is replaced by one for ~12 easy reps.
ProgressionAdvice adviseProgression(
  Exercise e,
  List<List<LoggedSet>> history, {
  int? repMin,
  int? repMax,
  bool deload = false,
  int incrementSteps = 0,
  int? targetRir,
  bool holdOnStruggle = false,
  bool light = false,
}) {
  final base = _baseAdvice(e, history, repMin: repMin, repMax: repMax, holdOnStruggle: holdOnStruggle);
  final lo = repMin ?? e.repMin ?? 8;
  var weight = base.weightKg;
  var reps = base.targetReps;
  var message = base.message;

  if (light && weight != null) {
    final easy = _lightWeight(e, history, lo);
    if (easy != null && (e.isAssisted ? easy > weight : easy < weight)) {
      weight = easy;
      reps = lo;
      message = 'Go light: ${_load(e, easy)}${e.isAssisted ? ' assistance' : ''} for $lo+ easy reps.';
    }
  }

  // Assisted machines run the other way: more assistance kg = easier.
  final dir = e.isAssisted ? -1 : 1;
  if (incrementSteps != 0 && weight != null && e.isWeighted) {
    final adjusted = _round(e, weight + dir * incrementSteps * e.incrementKg);
    weight = adjusted > 0 || e.isAssisted ? math.max(0.0, adjusted) : weight;
    message = e.isAssisted
        ? (incrementSteps < 0
            ? 'Last time felt too hard – a bit more assistance (${_load(e, weight)}).'
            : 'Last time felt too easy – a bit less assistance (${_load(e, weight)}).')
        : (incrementSteps < 0
            ? 'Last time felt too hard – one step lighter (${_load(e, weight)}).'
            : 'Last time felt too easy – one extra step (${_load(e, weight)}).');
  } else if (incrementSteps != 0 && !e.isWeighted && history.isNotEmpty) {
    message = incrementSteps < 0
        ? 'Last time felt too hard – slow down and stop 3 reps short.'
        : 'Last time felt too easy – add reps or slow the tempo.';
  }

  if (deload) {
    if (weight != null && e.isWeighted) {
      weight = e.isAssisted ? weight + e.incrementKg : _lighter(e, weight);
    }
    reps = history.isEmpty ? reps : lo;
    message = weight == null
        ? 'Deload: keep it light, one set fewer, stop 3–4 reps short.'
        : e.isAssisted
            ? 'Deload: a bit more assistance (${_load(e, weight)}), one set fewer, stop 3–4 reps short.'
            : 'Deload: ~90 % load (${_load(e, weight)}), one set fewer, stop 3–4 reps short.';
  } else if (targetRir != null && history.isNotEmpty) {
    message = '$message Stop with ~${rirPhrase(targetRir)}.';
  }

  return ProgressionAdvice(
    weightKg: weight == null ? null : e.snapKg(weight),
    targetReps: reps,
    message: message,
    lastSummary: base.lastSummary,
  );
}

/// Weight for ~12 reps with 3 in reserve when the last session stayed below [lo] reps; null when the last weight
/// already suits the range (normal progression applies). Bar exercises: computed on plates + bar, returned as plates.
double? _lightWeight(Exercise e, List<List<LoggedSet>> history, int lo) {
  final last = history
      .map((s) => s.where((x) => x.completed && (x.reps ?? 0) > 0 && x.weightKg != null).toList())
      .where((s) => s.isNotEmpty)
      .firstOrNull;
  if (last == null || last.every((x) => x.reps! >= lo)) return null;
  if (e.isAssisted) return last.map((x) => x.weightKg!).reduce(math.max) + e.incrementKg;
  var oneRm = 0.0;
  for (final x in last) {
    oneRm = math.max(oneRm, estimatedOneRepMax(x.loadKg ?? 0, x.reps!));
  }
  if (oneRm <= 0) return null;
  // Epley for 15 reps (12 + 3 in reserve).
  final plates = oneRm / 1.5 - last.first.barKg;
  return math.max(0.0, _round(e, plates));
}

ProgressionAdvice _baseAdvice(
  Exercise e,
  List<List<LoggedSet>> history, {
  int? repMin,
  int? repMax,
  bool holdOnStruggle = false,
}) {
  final lo = repMin ?? e.repMin ?? 8;
  final hi = repMax ?? e.repMax ?? 12;
  final sessions = history.where((s) => s.any((x) => x.completed && (x.reps ?? 0) > 0)).toList();
  if (sessions.isEmpty) {
    return ProgressionAdvice(
      message: e.isWeighted
          ? 'First time: choose a weight you could lift for ~3 more reps. Focus on form.'
          : 'First time: focus on smooth, controlled reps.',
    );
  }

  final assisted = e.isAssisted;
  // Hardest load of a session: the heaviest weight, or the least assistance on assisted machines.
  double hardest(Iterable<LoggedSet> s) {
    final w = s.map((x) => x.weightKg ?? 0);
    return assisted ? w.reduce(math.min) : w.fold<double>(0, math.max);
  }

  final last = sessions.first.where((x) => x.completed && (x.reps ?? 0) > 0).toList();
  final topWeight = hardest(last);
  final working = last.where((x) => (x.weightKg ?? 0) == topWeight).toList();
  final reps = working.map((x) => x.reps).join(', ');
  // Bar exercises log plates only: an empty bar (0 kg of plates) is still a loaded set.
  final emptyBar = topWeight == 0 && !assisted && last.any((x) => x.barKg > 0 && x.weightKg != null);
  final summary = topWeight > 0
      ? '${_load(e, topWeight)}${assisted ? ' assist' : ''} × $reps'
      : emptyBar
          ? 'Empty bar (0 kg plates) × $reps'
          : '$reps reps';
  final inc = e.incrementKg;
  double harder(double w) => assisted ? math.max(0.0, _round(e, w - inc)) : _round(e, w + inc);
  final step = e.plateKg == null ? '${_fmt(inc)} kg' : 'one plate';
  final stepUp = assisted ? 'take $step less assistance' : 'add $step';

  if (!e.isWeighted || (topWeight == 0 && !emptyBar)) {
    final allTop = working.every((x) => (x.reps ?? 0) >= hi);
    return ProgressionAdvice(
      targetReps: allTop ? hi : math.min(hi, (working.map((x) => x.reps ?? 0).reduce(math.max)) + 1),
      message: allTop
          ? 'You hit the top of the range – slow the tempo or pick a harder variation.'
          : 'Aim for one more rep per set than last time.',
      lastSummary: summary,
    );
  }

  final allTop = working.length >= math.min(e.sets, 2) && working.every((x) => (x.reps ?? 0) >= hi);
  if (allTop) {
    return ProgressionAdvice(
      weightKg: harder(topWeight),
      targetReps: lo,
      message: 'All sets hit $hi reps last time – $stepUp.',
      lastSummary: summary,
    );
  }

  // Reported reps in reserve: every working set inside the range with ≥ 4 RIR means the load is too light.
  final easy = working.length >= math.min(e.sets, 2) &&
      working.every((x) => x.rir != null && x.rir! >= 4 && (x.reps ?? 0) >= lo);
  if (easy) {
    return ProgressionAdvice(
      weightKg: harder(topWeight),
      targetReps: lo,
      message: 'Last sets felt easy (4+ reps in reserve) – $stepUp.',
      lastSummary: summary,
    );
  }

  bool struggled(List<LoggedSet> s) {
    final done = s.where((x) => x.completed && (x.reps ?? 0) > 0).toList();
    if (done.isEmpty) return false;
    final w = hardest(done);
    return done.where((x) => (x.weightKg ?? 0) == w).any((x) => (x.reps ?? 0) < lo);
  }

  if (sessions.length >= 2 && struggled(sessions[0]) && struggled(sessions[1])) {
    if (holdOnStruggle) {
      return ProgressionAdvice(
        weightKg: topWeight,
        targetReps: lo,
        message: 'Below $lo reps twice – keep ${_load(e, topWeight)}${assisted ? ' assistance' : ''} and own every rep; '
            'the deload resets the load.',
        lastSummary: summary,
      );
    }
    return ProgressionAdvice(
      weightKg: assisted ? topWeight + inc : _lighter(e, topWeight),
      targetReps: lo,
      message: assisted
          ? 'Below $lo reps twice in a row – add $step${e.plateKg == null ? '' : ' of'} assistance and rebuild with good form.'
          : 'Below $lo reps twice in a row – drop ~10% and rebuild with good form.',
      lastSummary: summary,
    );
  }

  return ProgressionAdvice(
    weightKg: topWeight,
    targetReps: math.min(hi, working.map((x) => x.reps ?? 0).reduce(math.min) + 1),
    message: assisted
        ? 'Same assistance – aim for one more rep on your weakest set.'
        : 'Same weight – aim for one more rep on your weakest set.',
    lastSummary: summary,
  );
}

String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
String formatKg(double? v) => v == null ? '–' : _fmt(v);
