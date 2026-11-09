import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/muscles.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/stats.dart';
import 'package:wfit/domain/training_load.dart';

import 'helpers.dart';

Exercise ex(String id, List<String> primary, {List<String> secondary = const [], String category = 'strength', String pattern = 'x'}) =>
    Exercise(
      id: id,
      name: id,
      category: category,
      splits: const ['push', 'pull', 'legs'],
      primary: primary,
      secondary: secondary,
      pattern: pattern,
      equipment: const [],
      difficulty: 1,
      compound: primary.length > 1,
      unilateral: false,
      isTimed: false,
      sets: 3,
      repMin: 8,
      repMax: 12,
      rest: 60,
      incrementKg: 2.5,
      instructions: const [],
    );

final testCatalog = Catalog(version: 3, equipment: const [], exercises: [
  ex('curl', ['biceps'], secondary: ['forearms'], pattern: 'biceps'),
  ex('press', ['chest'], secondary: ['triceps', 'front_delts'], pattern: 'horizontal_push'),
  ex('ohp', ['front_delts'], secondary: ['side_delts', 'triceps'], pattern: 'vertical_push'),
  ex('row', ['upper_back', 'lats'], secondary: ['biceps', 'rear_delts'], pattern: 'horizontal_pull'),
  ex('squat', ['quads', 'glutes'], secondary: ['adductors'], pattern: 'squat'),
  ex('leg-curl', ['hamstrings'], secondary: ['calves'], pattern: 'knee_flexion'),
  ex('slam', ['lats', 'abs'], secondary: ['full_body'], category: 'power', pattern: 'plyo_upper'),
  ex('plank', ['abs'], secondary: ['obliques', 'hip_flexors'], category: 'core', pattern: 'anti_extension'),
  ex('arm-circles', ['front_delts'], category: 'warmup', pattern: 'activation'),
]);

/// [n] completed sets of [exercise] in session [session] on [day].
List<LoggedSet> sets(String exercise, DateTime day, {int n = 3, String? session, double w = 20, int reps = 10, String? section}) => [
      for (var i = 0; i < n; i++)
        LoggedSet(
          sessionId: session ?? 's${isoDate(day)}',
          exerciseId: exercise,
          date: DateTime(day.year, day.month, day.day, 18),
          weightKg: w,
          reps: reps,
          section: section,
        ),
    ];

void main() {
  group('effective sets', () {
    test('primary 1.0, secondary 0.5, untracked muscles ignored', () {
      expect(effectiveSetsFor(testCatalog.exercise('press')!, 3), {'chest': 3.0, 'triceps': 1.5, 'front_delts': 1.5});
      expect(effectiveSetsFor(testCatalog.exercise('slam')!, 2), {'lats': 2.0, 'abs': 2.0});
      expect(effectiveSetsFor(testCatalog.exercise('plank')!, 2), {'abs': 2.0, 'obliques': 1.0});
      expect(effectiveSetsFor(testCatalog.exercise('arm-circles')!, 2), isEmpty, reason: 'warm-up never counts');
      expect(secondarySetWeight, 0.5);
    });

    test('real catalog: every strength exercise contributes to at least one tracked muscle', () {
      final catalog = loadTestCatalog();
      for (final e in catalog.exercises.where((e) => e.category == 'strength')) {
        expect(effectiveSetsFor(e, 1), isNotEmpty, reason: e.id);
      }
    });
  });

  group('weeklyMuscleVolume', () {
    final now = DateTime(2026, 11, 11); // Wednesday
    test('ISO weeks start on Monday; warm-up sections and incomplete sets do not count', () {
      final logged = [
        ...sets('curl', DateTime(2026, 11, 9)), // this week (Monday)
        ...sets('curl', DateTime(2026, 11, 8)), // Sunday → last week
        ...sets('curl', DateTime(2026, 11, 9), n: 2, section: 'warmup'),
        LoggedSet(sessionId: 'x', exerciseId: 'curl', date: DateTime(2026, 11, 9), reps: 10, completed: false),
        ...sets('unknown-exercise', DateTime(2026, 11, 9)),
      ];
      final weeks = weeklyMuscleVolume(logged, testCatalog, weeks: 3, now: now);
      expect(weeks.map((w) => w.weekStart).toList(), [DateTime(2026, 10, 26), DateTime(2026, 11, 2), DateTime(2026, 11, 9)]);
      expect(weeks.last.of('biceps'), 3);
      expect(weeks.last.of('forearms'), 1.5);
      expect(weeks[1].of('biceps'), 3);
      expect(weeks.last.sessions, 1);
      expect(weeks.first.total, 0);
      expect(weeks.last.primarySets['biceps'], 3);
    });
  });

  group('analyzeBalance', () {
    final now = DateTime(2026, 11, 9); // Monday, nothing logged this week yet
    DateTime weekDay(int weeksAgo, [int day = 0]) => addDays(now, -7 * weeksAgo + day);

    List<LoggedSet> history({int bicepsLastWeek = 3, int bicepsBefore = 3}) => [
          for (var w = 1; w <= 4; w++) ...[
            ...sets('press', weekDay(w), n: 7),
            ...sets('row', weekDay(w, 2), n: 6),
            ...sets('curl', weekDay(w, 2), n: w == 1 ? bicepsLastWeek : bicepsBefore),
            ...sets('squat', weekDay(w, 4), n: 6),
            ...sets('leg-curl', weekDay(w, 4), n: 3),
          ],
        ];

    BalanceReport analyze(List<LoggedSet> logged, {Iterable<DateTime> deloadWeeks = const []}) =>
        analyzeBalance(weeklyMuscleVolume(logged, testCatalog, weeks: 8, now: now), logged, testCatalog,
            now: now, deloadWeeks: deloadWeeks);

    test('status, weeks under, days since trained and priorities', () {
      // Biceps: 1 curl set + 6 row sets × 0.5 = 4 per week → ok; 0 curls → 3 → under.
      final r = analyze(history(bicepsLastWeek: 0, bicepsBefore: 0));
      final biceps = r.status('biceps')!;
      expect(biceps.lastWeek, 3);
      expect(biceps.recentAvg, 3);
      expect(biceps.status, VolumeStatus.under);
      expect(biceps.weeksUnder, 4);
      expect(biceps.daysSinceTrained, isNull, reason: 'never a primary target');
      final p = r.priority('biceps')!;
      expect(p.extraSets, 2);
      expect(p.reason, contains('3/4 sets last week'));
      expect(p.reason, contains('below target 4 weeks running'));
      expect(r.priority('side_delts')!.score, greaterThan(p.score), reason: 'untrained muscles rank first');
      expect(r.notes.any((n) => n.startsWith('Biceps below target in 4 of the last 4 weeks')), isTrue);

      final chest = r.status('chest')!;
      expect(chest.lastWeek, 7);
      expect(chest.status, VolumeStatus.ok);
      expect(chest.daysSinceTrained, 7);
      expect(r.priority('chest')!.extraSets, 1, reason: '7 sets < goal 7.5');
      expect(r.priority('chest')!.reason, contains('goal 7.5'));
      expect(r.status('triceps')!.status, VolumeStatus.under, reason: '7 pressing sets × 0.5 = 3.5 < 4');
      expect(r.status('glutes')!.status, VolumeStatus.ok);
    });

    test('carry-over: a deficit last week creates a priority, a good week clears it', () {
      final under = analyze(history(bicepsLastWeek: 0));
      expect(under.priority('biceps'), isNotNull);
      expect(under.status('biceps')!.weeksUnder, 1);
      expect(under.status('biceps')!.trend, VolumeTrend.down);
      final ok = analyze(history(bicepsLastWeek: 4, bicepsBefore: 4));
      expect(ok.priority('biceps'), isNull);
      expect(ok.status('biceps')!.status, VolumeStatus.ok);
    });

    test('this week reaching the goal removes the priority', () {
      final logged = [...history(bicepsLastWeek: 0), ...sets('curl', now, n: 6)];
      final r = analyzeBalance(weeklyMuscleVolume(logged, testCatalog, now: now), logged, testCatalog, now: now);
      expect(r.status('biceps')!.thisWeek, 6);
      expect(r.priority('biceps'), isNull);
    });

    test('above max → high status and a note; no priority', () {
      final logged = [...history(), ...sets('press', weekDay(1, 1), n: 8)];
      final r = analyze(logged);
      expect(r.status('chest')!.lastWeek, 15);
      expect(r.status('chest')!.status, VolumeStatus.high);
      expect(r.isHigh('chest'), isTrue);
      expect(r.priority('chest'), isNull);
      expect(r.notes, contains('Chest above target (15 sets, max 12)'));
    });

    test('recent average skips weeks without sessions and deload weeks', () {
      final logged = [
        ...sets('curl', weekDay(1), n: 6),
        ...sets('curl', weekDay(3), n: 2),
        ...sets('curl', weekDay(4), n: 4),
        ...sets('curl', weekDay(5), n: 8),
      ];
      final r = analyze(logged);
      expect(r.status('biceps')!.recentAvg, closeTo(4, 1e-9), reason: '(6 + 2 + 4) / 3, empty week 2 skipped');
      final withDeload = analyze(logged, deloadWeeks: [weekDay(3, 3)]);
      expect(withDeload.status('biceps')!.recentAvg, closeTo(6, 1e-9), reason: '(6 + 4 + 8) / 3');
    });

    test('ratios, group share and brief shape', () {
      final r = analyze(history());
      expect(r.pushPullRatio, closeTo(28 / 24, 1e-9));
      expect(r.quadHamRatio, closeTo(24 / 12, 1e-9));
      expect(r.groupShare.values.fold<double>(0, (a, b) => a + b), closeTo(1, 1e-9));
      final brief = r.toBrief();
      expect(brief.keys, ['muscles', 'priorities', 'ratios', 'notes']);
      final biceps = (brief['muscles'] as List).cast<Map<String, dynamic>>().firstWhere((m) => m['muscle'] == 'biceps');
      expect(biceps.keys, [
        'muscle', 'thisWeek', 'lastWeek', 'recentAvg', 'targetMin', 'targetMax', 'status', 'weeksUnder',
        'daysSinceTrained', 'trend',
      ]);
      expect((brief['muscles'] as List).length, trackedMuscleInfo.length);
      expect(brief['ratios'], {'pushPull': 1.17, 'quadHam': 2.0});
      expect(r.daysSinceTrainedOn('chest', addDays(now, 2)), 9);
    });

    test('no history: everything under, no priorities', () {
      final r = analyze(const []);
      expect(r.priorities, isEmpty);
      expect(r.muscles.every((m) => m.status == VolumeStatus.under), isTrue);
      expect(r.pushPullRatio, isNull);
    });
  });

  group('exercise trends', () {
    List<List<LoggedSet>> hist(List<(double, List<int>)> newestFirst) => [
          for (var i = 0; i < newestFirst.length; i++)
            [
              for (final r in newestFirst[i].$2)
                LoggedSet(sessionId: 's$i', exerciseId: 'press', date: DateTime(2026, 11, 20 - i * 3), weightKg: newestFirst[i].$1, reps: r),
            ],
        ];

    test('new with fewer than two exposures', () {
      expect(exerciseTrend(const []), ExerciseTrend.isNew);
      expect(exerciseTrend(hist([(50, [10, 10])])), ExerciseTrend.isNew);
      expect(ExerciseTrend.isNew.id, 'new');
      expect(ExerciseTrend.parse('new'), ExerciseTrend.isNew);
    });

    test('progressing: more reps, or more load even with fewer reps', () {
      expect(exerciseTrend(hist([(50, [11, 10]), (50, [10, 10])])), ExerciseTrend.progressing);
      expect(exerciseTrend(hist([(52.5, [8, 8]), (50, [12, 12]), (50, [11, 11])])), ExerciseTrend.progressing);
      expect(exerciseTrend(hist([(52.5, [8, 8]), (52.5, [8, 8]), (50, [12, 12])])), ExerciseTrend.progressing,
          reason: 'held the new load – still progressing over the window');
    });

    test('stalled: no progress over three exposures', () {
      expect(exerciseTrend(hist([(50, [10, 9]), (50, [10, 9]), (50, [10, 9])])), ExerciseTrend.stalled);
    });

    test('regressing: two declines in a row or a big drop', () {
      expect(exerciseTrend(hist([(50, [8, 7]), (50, [9, 8]), (50, [10, 9])])), ExerciseTrend.regressing);
      expect(exerciseTrend(hist([(40, [8, 8]), (50, [10, 10]), (50, [10, 10])])), ExerciseTrend.regressing);
    });

    test('bodyweight exercises use reps', () {
      List<List<LoggedSet>> bw(List<int> reps) => [
            for (var i = 0; i < reps.length; i++)
              [LoggedSet(sessionId: 's$i', exerciseId: 'push-up', date: DateTime(2026, 11, 20 - i), reps: reps[i])],
          ];
      expect(exerciseTrend(bw([12, 11, 10])), ExerciseTrend.progressing);
      expect(exerciseTrend(bw([10, 10, 10])), ExerciseTrend.stalled);
    });

    test('groupHistory, exerciseTrends and the brief entries', () {
      final logged = [
        for (var i = 0; i < 6; i++) ...sets('press', DateTime(2026, 11, 2 + i), w: 50 + i * 2.5, reps: 8),
        ...sets('curl', DateTime(2026, 11, 3), w: 10, reps: 12),
        ...sets('plank', DateTime(2026, 11, 4)),
        ...sets('arm-circles', DateTime(2026, 11, 8)),
        ...sets('press', DateTime(2026, 8, 1)), // older than 12 weeks
      ];
      final grouped = groupHistory(logged);
      expect(grouped['press']!.first.first.weightKg, 62.5, reason: 'most recent first');
      expect(exerciseTrends(logged)['press'], ExerciseTrend.progressing);
      final brief = exerciseHistoryBrief(logged, catalog: testCatalog, now: DateTime(2026, 11, 9));
      expect(brief.map((b) => b['exerciseId']).toList(), ['press', 'plank', 'curl'], reason: 'warm-up excluded');
      final press = brief.first;
      expect(press['trend'], 'progressing');
      expect(press['lastPerformed'], '2026-11-07');
      expect(press['exposures'], hasLength(4));
      expect((press['exposures'] as List).first, {'date': '2026-11-07', 'sets': '62.5x8, 62.5x8, 62.5x8', 'e1rm': 79.2});
      expect(exerciseHistoryBrief(logged, now: DateTime(2026, 11, 9), maxExercises: 1), hasLength(1));
    });
  });
}
