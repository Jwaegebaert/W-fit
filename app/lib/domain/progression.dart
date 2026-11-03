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
  });

  final String sessionId;
  final String exerciseId;
  final DateTime date;
  final double? weightKg;
  final int? reps;
  final int? durationSeconds;
  final bool completed;

  double get volume => (weightKg ?? 0) * (reps ?? 0);
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

class ProgressionAdvice {
  const ProgressionAdvice({this.weightKg, this.targetReps, required this.message, this.lastSummary});

  final double? weightKg;
  final int? targetReps;
  final String message;
  final String? lastSummary;
}

/// Double progression for beginners.
///
/// [history] contains completed sets for one exercise, grouped per session, most recent session first.
ProgressionAdvice adviseProgression(Exercise e, List<List<LoggedSet>> history, {int? repMin, int? repMax}) {
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

  final last = sessions.first.where((x) => x.completed && (x.reps ?? 0) > 0).toList();
  final topWeight = last.map((x) => x.weightKg ?? 0).fold<double>(0, math.max);
  final working = last.where((x) => (x.weightKg ?? 0) == topWeight).toList();
  final summary = topWeight > 0
      ? '${_fmt(topWeight)} kg × ${working.map((x) => x.reps).join(', ')}'
      : '${working.map((x) => x.reps).join(', ')} reps';

  if (!e.isWeighted || topWeight == 0) {
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
      weightKg: roundToStep(topWeight + e.incrementKg, e.incrementKg),
      targetReps: lo,
      message: 'All sets hit $hi reps last time – add ${_fmt(e.incrementKg)} kg.',
      lastSummary: summary,
    );
  }

  bool struggled(List<LoggedSet> s) {
    final done = s.where((x) => x.completed && (x.reps ?? 0) > 0).toList();
    if (done.isEmpty) return false;
    final w = done.map((x) => x.weightKg ?? 0).fold<double>(0, math.max);
    return done.where((x) => (x.weightKg ?? 0) == w).any((x) => (x.reps ?? 0) < lo);
  }

  if (sessions.length >= 2 && struggled(sessions[0]) && struggled(sessions[1])) {
    return ProgressionAdvice(
      weightKg: roundToStep(topWeight * 0.9, e.incrementKg),
      targetReps: lo,
      message: 'Below $lo reps twice in a row – drop ~10% and rebuild with good form.',
      lastSummary: summary,
    );
  }

  return ProgressionAdvice(
    weightKg: topWeight,
    targetReps: math.min(hi, working.map((x) => x.reps ?? 0).reduce(math.min) + 1),
    message: 'Same weight – aim for one more rep on your weakest set.',
    lastSummary: summary,
  );
}

String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
String formatKg(double? v) => v == null ? '–' : _fmt(v);
