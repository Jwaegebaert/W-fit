import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/program.dart';
import 'package:wfit/domain/stats.dart';
import 'package:wfit/domain/training_load.dart';

import 'helpers.dart';

final start = DateTime(2026, 1, 5); // Monday

/// Mon / Wed / Fri Push → Pull → Legs sessions for [weeks] weeks starting at [from].
List<SessionInfo> schedule(int weeks, {DateTime? from, int? effort, int? rating, int firstIndex = 0, DayType first = DayType.push}) {
  final out = <SessionInfo>[];
  var day = first;
  for (var w = 0; w < weeks; w++) {
    for (final offset in const [0, 2, 4]) {
      out.add(SessionInfo(
        id: 's${firstIndex + out.length}',
        date: addDays(from ?? start, 7 * w + offset).add(const Duration(hours: 18)),
        dayType: day,
        effort: effort,
        rating: rating,
      ));
      day = day.next;
    }
  }
  return out;
}

void main() {
  test('no history: block 1, week 1, Push A', () {
    final p = computeProgramState(const [], now: start);
    expect(p.blockNumber, 1);
    expect(p.blockWeek, 1);
    expect(p.day, DayType.push);
    expect(p.variant, 'A');
    expect(p.deload, isFalse);
    expect(p.targetRir, 3);
    expect(p.label, 'Block 1 · Week 1 · Push A');
    expect(p.completedSessions, 0);
  });

  test('variants alternate per day type; weeks count training weeks', () {
    final sessions = schedule(2);
    final p = computeProgramState(sessions, now: addDays(start, 14));
    expect(p.blockWeek, 3);
    expect(p.day, DayType.push);
    expect(p.variant, 'A');
    expect(p.variantFor(DayType.legs), 'A');
    expect(p.history.map((s) => s.variant).toList(), ['A', 'A', 'A', 'B', 'B', 'B']);
    expect(p.history.last.blockWeek, 2);
    expect(p.completedSessions, 6);
    expect(p.weeksTraining, 2);
    expect(p.targetRir, 2);
    expect(p.rirLabel, '2');

    // Mid-week: Wednesday of week 3 after Monday's Push A.
    final mid = computeProgramState([...sessions, ...schedule(1, from: addDays(start, 14), firstIndex: 6).take(1)],
        now: addDays(start, 16));
    expect(mid.blockWeek, 3);
    expect(mid.day, DayType.pull);
    expect(mid.label, 'Block 1 · Week 3 · Pull A');
  });

  test('target RIR follows the block week', () {
    int rir(int weeks) => computeProgramState(schedule(weeks), now: addDays(start, 7 * weeks)).targetRir;
    expect(rir(0), 3);
    expect(rir(1), 2);
    expect(rir(2), 2);
    expect(rir(3), 1);
    expect(computeProgramState(schedule(4), now: addDays(start, 28)).rirLabel, '1–2');
  });

  test('week 6 is a planned deload, then a new block starts with variant A', () {
    final five = schedule(5);
    final deload = computeProgramState(five, now: addDays(start, 35));
    expect(deload.blockWeek, 6);
    expect(deload.deload, isTrue);
    expect(deload.phase, 'deload');
    expect(deload.deloadReason, 'Planned deload (week 6 of 6)');
    expect(deload.targetRir, 3);
    expect(deload.rirLabel, '3–4');

    final six = schedule(6);
    final next = computeProgramState(six, now: addDays(start, 42));
    expect(next.blockNumber, 2);
    expect(next.blockWeek, 1);
    expect(next.deload, isFalse);
    expect(next.variant, 'A');
    expect(next.deloadWeekStarts, {addDays(start, 35)});
    expect(next.deloadSessionIds, {'s15', 's16', 's17'});
    expect(next.history.where((s) => s.block == 1), hasLength(18));
    expect(next.weeksTraining, 6);
  });

  test('a gap of 14+ days starts a new block', () {
    final sessions = schedule(3);
    final last = sessions.last.date;
    expect(computeProgramState(sessions, now: addDays(last, 13)).blockNumber, 1);
    final after = computeProgramState(sessions, now: addDays(last, 14));
    expect(after.blockNumber, 2);
    expect(after.blockWeek, 1);
    final resumed = [...sessions, ...schedule(1, from: startOfWeek(addDays(last, 17)), firstIndex: 9)];
    final p = computeProgramState(resumed, now: addDays(resumed.last.date, 2));
    expect(p.blockNumber, 2);
    expect(p.history.where((s) => s.block == 2).map((s) => s.variant).toSet(), {'A'});
  });

  test('a week without training does not consume the block', () {
    final sessions = [...schedule(2), ...schedule(1, from: addDays(start, 21), firstIndex: 6)];
    final p = computeProgramState(sessions, now: addDays(start, 28));
    expect(p.blockNumber, 1);
    expect(p.blockWeek, 4);
  });

  test('plan meta variant and deload are trusted', () {
    final sessions = [
      SessionInfo(id: 'a', date: start, dayType: DayType.push, meta: const PlanMeta(program: 'x', variant: 'B')),
    ];
    final p = computeProgramState(sessions, now: addDays(start, 7), day: DayType.push);
    expect(p.history.single.variant, 'B');
    expect(p.variant, 'A');
    final early = [
      ...schedule(2),
      SessionInfo(id: 'd', date: addDays(start, 14), dayType: DayType.push, meta: const PlanMeta(program: 'x', variant: 'A', deload: true)),
    ];
    final sameWeek = computeProgramState(early, now: addDays(start, 16));
    expect(sameWeek.deload, isTrue, reason: 'the rest of the deload week stays a deload');
    final nextWeek = computeProgramState(early, now: addDays(start, 21));
    expect(nextWeek.blockNumber, 2);
    expect(nextWeek.deload, isFalse);
  });

  group('early deload triggers', () {
    test('average effort ≥ 8.5 over the last 3 sessions', () {
      final p = computeProgramState(schedule(2, effort: 9), now: addDays(start, 14));
      expect(p.deload, isTrue);
      expect(p.deloadReason, contains('average effort 9.0'));
      expect(computeProgramState(schedule(2, effort: 8), now: addDays(start, 14)).deload, isFalse);
    });

    test('rating ≤ 2 twice in a row', () {
      final p = computeProgramState(schedule(2, rating: 2), now: addDays(start, 14));
      expect(p.deload, isTrue);
      expect(p.deloadReason, contains('rating'));
    });

    test('two regressing anchors', () {
      final catalog = loadTestCatalog();
      final sessions = [
        for (final (i, s) in schedule(2).indexed)
          SessionInfo(
            id: s.id,
            date: s.date,
            dayType: s.dayType,
            mainExerciseIds: switch (s.dayType) {
              DayType.push => ['machine-chest-press', 'cable-lateral-raise'],
              DayType.pull => ['lat-pulldown', 'face-pull'],
              DayType.legs => [if (i > 3) 'leg-press' else 'goblet-squat', 'lying-leg-curl'],
            },
          ),
      ];
      final trends = {'machine-chest-press': ExerciseTrend.regressing, 'leg-press': ExerciseTrend.regressing};
      final p = computeProgramState(sessions, now: addDays(start, 14), trends: trends, catalog: catalog);
      expect(p.deload, isTrue);
      expect(p.deloadReason, contains('2 anchor lifts regressing'));
      final one = computeProgramState(sessions,
          now: addDays(start, 14), trends: {'machine-chest-press': ExerciseTrend.regressing}, catalog: catalog);
      expect(one.deload, isFalse);
    });

    test('never in the first week of a block', () {
      final p = computeProgramState(schedule(1, effort: 10, rating: 1).take(2).toList(), now: addDays(start, 4));
      expect(p.blockWeek, 1);
      expect(p.deload, isFalse);
    });
  });

  test('brief shape', () {
    final brief = computeProgramState(schedule(2), now: addDays(start, 14)).toBrief();
    expect(brief.keys, [
      'blockNumber', 'blockWeek', 'blockLength', 'phase', 'deload', 'deloadReason', 'variant', 'variantFocus',
      'targetRir', 'completedSessions', 'weeksTraining',
    ]);
    expect(brief['variantFocus'], isNotEmpty);
    expect(brief['blockLength'], 6);
  });

  test('copyVariant and forDay', () {
    final p = ProgramState.initial(DayType.push, start).copyVariant(DayType.legs, 'B');
    expect(p.day, DayType.legs);
    expect(p.variant, 'B');
    expect(p.forDay(DayType.push).variant, 'A');
    expect(p.labelFor(DayType.legs), 'Block 1 · Week 1 · Legs B');
  });
}
