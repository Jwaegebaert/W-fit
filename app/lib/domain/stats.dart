import 'dart:math' as math;

import 'catalog.dart';
import 'progression.dart';

enum PrType { weight, e1rm, reps }

class PersonalRecord {
  const PersonalRecord({
    required this.exerciseId,
    required this.type,
    required this.value,
    required this.date,
    this.weightKg,
    this.reps,
  });

  final String exerciseId;
  final PrType type;
  final double value;
  final DateTime date;
  final double? weightKg;
  final int? reps;

  String describe() => switch (type) {
        PrType.weight => 'Heaviest: ${formatKg(value)} kg × $reps',
        PrType.e1rm => 'Est. 1RM: ${formatKg(value)} kg',
        PrType.reps => 'Most reps: ${value.toInt()}${weightKg != null && weightKg! > 0 ? ' @ ${formatKg(weightKg)} kg' : ''}',
      };
}

class ExerciseBest {
  ExerciseBest(this.exerciseId);
  final String exerciseId;
  LoggedSet? heaviest;
  LoggedSet? bestE1rmSet;
  double bestE1rm = 0;
  LoggedSet? mostReps;
}

/// Best performances per exercise over [sets].
Map<String, ExerciseBest> computeBests(Iterable<LoggedSet> sets) {
  final bests = <String, ExerciseBest>{};
  for (final s in sets) {
    if (!s.completed || (s.reps ?? 0) <= 0) continue;
    final b = bests.putIfAbsent(s.exerciseId, () => ExerciseBest(s.exerciseId));
    final w = s.loadKg ?? 0;
    if (b.heaviest == null || w > (b.heaviest!.loadKg ?? 0)) b.heaviest = s;
    final e1 = estimatedOneRepMax(w, s.reps!);
    if (e1 > b.bestE1rm) {
      b.bestE1rm = e1;
      b.bestE1rmSet = s;
    }
    if (b.mostReps == null ||
        (w >= (b.mostReps!.loadKg ?? 0) && s.reps! > b.mostReps!.reps!)) {
      b.mostReps = s;
    }
  }
  return bests;
}

/// PRs achieved in [session] compared with all [previous] sets.
List<PersonalRecord> detectPrs(List<LoggedSet> session, Iterable<LoggedSet> previous) {
  final before = computeBests(previous);
  final now = computeBests(session);
  final prs = <PersonalRecord>[];
  for (final entry in now.entries) {
    final prev = before[entry.key];
    if (prev == null) continue; // first time is a baseline, not a PR
    final cur = entry.value;
    final curW = cur.heaviest?.loadKg ?? 0;
    final prevW = prev.heaviest?.loadKg ?? 0;
    if (curW > 0 && curW > prevW) {
      prs.add(PersonalRecord(
        exerciseId: entry.key,
        type: PrType.weight,
        value: curW,
        date: cur.heaviest!.date,
        weightKg: curW,
        reps: cur.heaviest!.reps,
      ));
    } else if (cur.bestE1rm > 0 && cur.bestE1rm > prev.bestE1rm + 0.01) {
      prs.add(PersonalRecord(
        exerciseId: entry.key,
        type: PrType.e1rm,
        value: cur.bestE1rm,
        date: cur.bestE1rmSet!.date,
        weightKg: cur.bestE1rmSet!.loadKg,
        reps: cur.bestE1rmSet!.reps,
      ));
    } else if (curW == 0 && prevW == 0 && (cur.mostReps?.reps ?? 0) > (prev.mostReps?.reps ?? 0)) {
      prs.add(PersonalRecord(
        exerciseId: entry.key,
        type: PrType.reps,
        value: cur.mostReps!.reps!.toDouble(),
        date: cur.mostReps!.date,
      ));
    }
  }
  return prs;
}

/// Calendar-safe day arithmetic (Duration-based math breaks across DST changes).
DateTime addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

DateTime startOfWeek(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// Local calendar date of [d] (UTC values are converted to local time first).
DateTime dateOnly(DateTime d) {
  final l = d.isUtc ? d.toLocal() : d;
  return DateTime(l.year, l.month, l.day);
}

/// Whole calendar days from [from] to [to] (DST-safe; negative when [to] is earlier).
int daysBetween(DateTime from, DateTime to) =>
    (dateOnly(to).difference(dateOnly(from)).inHours / 24).round();

/// `yyyy-MM-dd` of the local calendar date.
String isoDate(DateTime d) {
  final l = dateOnly(d);
  return '${l.year.toString().padLeft(4, '0')}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

class WeekStat {
  WeekStat(this.weekStart);
  final DateTime weekStart;
  int sessions = 0;
  double volume = 0;
  int sets = 0;
}

/// Per-week aggregates for the last [weeks] weeks (oldest first).
List<WeekStat> weeklyStats(
  Iterable<DateTime> sessionDates,
  Iterable<LoggedSet> sets, {
  int weeks = 12,
  DateTime? now,
}) {
  final current = startOfWeek(now ?? DateTime.now());
  final list = List.generate(weeks, (i) => WeekStat(addDays(current, -7 * (weeks - 1 - i))));
  WeekStat? find(DateTime d) {
    final w = startOfWeek(d);
    for (final s in list) {
      if (s.weekStart == w) return s;
    }
    return null;
  }

  for (final d in sessionDates) {
    find(d)?.sessions++;
  }
  for (final s in sets) {
    if (!s.completed) continue;
    final w = find(s.date);
    if (w == null) continue;
    w.sets++;
    w.volume += s.volume;
  }
  return list;
}

/// Consecutive weeks (ending this week or last week) meeting [target] sessions.
int weekStreak(List<WeekStat> weeks, int target) {
  var streak = 0;
  for (var i = weeks.length - 1; i >= 0; i--) {
    final isCurrent = i == weeks.length - 1;
    if (weeks[i].sessions >= target) {
      streak++;
    } else if (isCurrent) {
      continue; // current week still in progress
    } else {
      break;
    }
  }
  return streak;
}

/// Next [count] training dates starting today (inclusive), using ISO weekdays.
List<DateTime> upcomingTrainingDates(List<int> trainingDays, {int count = 3, DateTime? from}) {
  final days = trainingDays.isEmpty ? const [1, 3, 5] : trainingDays;
  final start = from ?? DateTime.now();
  var d = DateTime(start.year, start.month, start.day);
  final result = <DateTime>[];
  for (var i = 0; i < 21 && result.length < count; i++) {
    if (days.contains(d.weekday)) result.add(d);
    d = addDays(d, 1);
  }
  return result;
}

/// Muscles trained in a set of exercises, weighted primary=2, secondary=1.
Map<String, int> muscleLoad(Iterable<Exercise> exercises) {
  final load = <String, int>{};
  for (final e in exercises) {
    for (final m in e.primary) {
      load[m] = (load[m] ?? 0) + 2;
    }
    for (final m in e.secondary) {
      load[m] = (load[m] ?? 0) + 1;
    }
  }
  return load;
}

double percentChange(double from, double to) => from == 0 ? 0 : (to - from) / from * 100;

double maxOr0(Iterable<double> values) => values.isEmpty ? 0 : values.reduce(math.max);
