import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/stats.dart';

import 'helpers.dart';

LoggedSet s(String session, double w, int r, {String ex = 'goblet-squat', DateTime? d}) =>
    LoggedSet(sessionId: session, exerciseId: ex, date: d ?? DateTime(2026, 11, 1), weightKg: w, reps: r);

void main() {
  final catalog = loadTestCatalog();
  final goblet = catalog.exercise('goblet-squat')!; // 8–12 reps, +2 kg

  group('double progression', () {
    test('first time gives guidance without a weight', () {
      final a = adviseProgression(goblet, const []);
      expect(a.weightKg, isNull);
      expect(a.message, contains('First time'));
    });

    test('adds weight when every set hit the top of the range', () {
      final a = adviseProgression(goblet, [
        [s('a', 16, 12), s('a', 16, 12), s('a', 16, 12)],
      ]);
      expect(a.weightKg, 18);
      expect(a.targetReps, 8);
    });

    test('keeps the weight and aims for one more rep otherwise', () {
      final a = adviseProgression(goblet, [
        [s('a', 16, 12), s('a', 16, 10), s('a', 16, 9)],
      ]);
      expect(a.weightKg, 16);
      expect(a.targetReps, 10);
    });

    test('deloads ~10% after two sessions below the range', () {
      final a = adviseProgression(goblet, [
        [s('b', 20, 7), s('b', 20, 6)],
        [s('a', 20, 7), s('a', 20, 6)],
      ]);
      expect(a.weightKg, 18);
    });

    test('rounds barbell loads to 2.5 kg', () {
      expect(roundToStep(41.3, 2.5), 42.5);
      expect(roundToStep(17.2, 2), 17);
    });

    test('deload: ~90 % of the working weight, bottom of the range', () {
      final a = adviseProgression(goblet, [
        [s('a', 20, 10), s('a', 20, 10)],
      ], deload: true);
      expect(a.weightKg, 18);
      expect(a.targetReps, 8);
      expect(a.message, startsWith('Deload'));
    });

    test('too_hard / too_easy move the target by one increment', () {
      final history = [
        [s('a', 16, 10), s('a', 16, 10), s('a', 16, 9)],
      ];
      expect(adviseProgression(goblet, history, incrementSteps: -1).weightKg, 14);
      expect(adviseProgression(goblet, history, incrementSteps: 1).weightKg, 18);
      expect(adviseProgression(goblet, history, incrementSteps: -1).message, contains('too hard'));
    });

    test('anchors hold the weight instead of resetting inside a block', () {
      final history = [
        [s('b', 20, 7), s('b', 20, 6)],
        [s('a', 20, 7), s('a', 20, 6)],
      ];
      expect(adviseProgression(goblet, history, holdOnStruggle: true).weightKg, 20);
      expect(adviseProgression(goblet, history).weightKg, 18);
    });

    test('reported RIR: every set with 4+ reps in reserve adds weight; target RIR in the message', () {
      final easy = adviseProgression(goblet, [
        [
          LoggedSet(sessionId: 'a', exerciseId: 'goblet-squat', date: DateTime(2026, 11, 1), weightKg: 16, reps: 9, rir: 4),
          LoggedSet(sessionId: 'a', exerciseId: 'goblet-squat', date: DateTime(2026, 11, 1), weightKg: 16, reps: 9, rir: 5),
        ],
      ]);
      expect(easy.weightKg, 18);
      final rir = adviseProgression(goblet, [
        [s('a', 16, 10), s('a', 16, 10)],
      ], targetRir: 2);
      expect(rir.message, endsWith('Stop with ~2 reps in reserve.'));
      expect(rirPhrase(1), '1–2 reps in reserve');
    });
  });

  group('dates', () {
    test('dateOnly, daysBetween (DST-safe) and isoDate', () {
      expect(dateOnly(DateTime(2026, 3, 29, 23, 30)), DateTime(2026, 3, 29));
      expect(daysBetween(DateTime(2026, 3, 28, 20), DateTime(2026, 3, 30, 1)), 2);
      expect(daysBetween(DateTime(2026, 10, 24), DateTime(2026, 10, 26)), 2);
      expect(daysBetween(DateTime(2026, 11, 9), DateTime(2026, 11, 2)), -7);
      expect(isoDate(DateTime(2026, 1, 5, 18)), '2026-01-05');
    });
  });

  group('stats', () {
    test('Epley e1RM', () {
      expect(estimatedOneRepMax(100, 1), 100);
      expect(estimatedOneRepMax(100, 10), closeTo(133.3, 0.1));
      expect(estimatedOneRepMax(0, 10), 0);
    });

    test('detects weight PRs but not first-time baselines', () {
      final previous = [s('a', 16, 10)];
      final prs = detectPrs([s('b', 18, 8), s('b', 10, 10, ex: 'push-up')], previous);
      expect(prs.length, 1);
      expect(prs.first.exerciseId, 'goblet-squat');
      expect(prs.first.type, PrType.weight);
    });

    test('detects e1RM PR at the same weight with more reps', () {
      final prs = detectPrs([s('b', 16, 12)], [s('a', 16, 10)]);
      expect(prs.single.type, PrType.e1rm);
    });

    test('weekly stats and streak', () {
      final now = DateTime(2026, 11, 4); // Wednesday
      final dates = [
        DateTime(2026, 11, 2), // this week
        DateTime(2026, 10, 27), DateTime(2026, 10, 29), DateTime(2026, 10, 31), // last week x3
        DateTime(2026, 10, 20), DateTime(2026, 10, 22), DateTime(2026, 10, 24), // x3
      ];
      final weeks = weeklyStats(dates, [s('x', 10, 10, d: DateTime(2026, 11, 2))], weeks: 4, now: now);
      expect(weeks.map((w) => w.sessions).toList(), [0, 3, 3, 1]);
      expect(weeks.last.volume, 100);
      expect(weekStreak(weeks, 3), 2);
    });

    test('upcoming training dates follow ISO weekdays', () {
      final dates = upcomingTrainingDates([1, 3, 5], count: 3, from: DateTime(2026, 11, 3)); // Tuesday
      expect(dates.map((d) => d.weekday).toList(), [3, 5, 1]);
    });
  });
}
