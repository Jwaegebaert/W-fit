import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/muscles.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/rule_engine.dart';
import 'package:wfit/domain/templates.dart';
import 'package:wfit/domain/training_load.dart';

import 'helpers.dart';
import 'simulation_test.dart' show runSimulation;

/// Phase 2: spare session time is filled with useful exercises (never with reps), and the athlete's muscle focus
/// (less / more / go light) steers targets, selection and prescriptions.
void main() {
  final catalog = loadTestCatalog();
  List<PlanItem> mainOf(GeneratedWorkout w) => w.blocks.firstWhere((b) => b.section == Section.main).items;
  GeneratedWorkout gen(DayType day, {int minutes = 60, MuscleFocus focus = MuscleFocus.none}) =>
      RuleEngine(TrainingContext(catalog: catalog, focus: focus))
          .generate(day: day, date: DateTime(2026, 3, 2), sessionMinutes: minutes);

  group('spare time', () {
    test('a longer session adds exercises for under-trained muscles, not reps', () {
      for (final day in DayType.values) {
        final short = gen(day);
        final long = gen(day, minutes: 90);
        expect(mainOf(long).length, greaterThan(mainOf(short).length), reason: '${day.name}: extra exercise first');
        expect(long.estimatedMinutes, greaterThan(short.estimatedMinutes), reason: day.name);
        expect(long.estimatedMinutes, lessThanOrEqualTo(90 + RuleEngine.timeToleranceSeconds ~/ 60), reason: day.name);
        expect(long.rationale.join(' '), contains('Extra time (90 min)'), reason: day.name);
        // Same exercise → same rep range: time is never filled by raising reps.
        final shortReps = {for (final i in mainOf(short)) i.exerciseId: (i.repMin, i.repMax)};
        for (final i in mainOf(long).where((i) => shortReps.containsKey(i.exerciseId))) {
          expect((i.repMin, i.repMax), shortReps[i.exerciseId], reason: '${day.name}: ${i.exerciseId}');
        }
      }
    });

    test('added exercises use accessory prescriptions and respect the set caps', () {
      final long = gen(DayType.pull, minutes: 90);
      final base = {for (final i in mainOf(gen(DayType.pull))) i.exerciseId: i.sets};
      for (final i in mainOf(long)) {
        final e = catalog.exercise(i.exerciseId)!;
        final cap = e.compound ? RuleEngine.maxSetsCompound : RuleEngine.maxSetsIsolation;
        final before = base[i.exerciseId];
        if (before == null) {
          expect(i.notes, startsWith('Extra time'), reason: i.exerciseId);
          expect(i.repMin, greaterThanOrEqualTo(RoleScheme.accessory.repMin - 2), reason: i.exerciseId);
        } else if (i.sets > before) {
          expect(i.sets, lessThanOrEqualTo(cap), reason: '${i.exerciseId} padded past the cap');
        }
      }
    });

    test('a balanced athlete gets no padding: the plan says the time is spare', () {
      final r = runSimulation(catalog, weeks: 5, sessionMinutes: 90);
      final late = r.plans.skip(9).toList();
      expect(late.any((p) => p.workout.rationale.any((l) => l.contains('min to spare'))), isTrue);
      for (final p in late) {
        expect(p.workout.estimatedMinutes, lessThanOrEqualTo(93));
        for (final i in p.main) {
          expect(i.sets, lessThanOrEqualTo(5), reason: i.exerciseId);
        }
      }
    });
  });

  group('muscle focus', () {
    test('encodes, decodes and scales targets', () {
      final f = MuscleFocus.none
          .withLevel('side_delts', FocusLevel.less)
          .withLevel('glutes', FocusLevel.more)
          .withLight('lower_back', true);
      final back = MuscleFocus.decode(f.encode());
      expect(back.levelOf('side_delts'), FocusLevel.less);
      expect(back.levelOf('glutes'), FocusLevel.more);
      expect(back.isLight('lower_back'), isTrue);
      expect(back.levelOf('chest'), FocusLevel.normal);
      expect(MuscleFocus.decode('{"less":["chest","neck"],"more":["chest"]}').levelOf('chest'), FocusLevel.more,
          reason: 'more wins; unknown muscles are dropped');
      expect(MuscleFocus.decode('nope').isEmpty, isTrue);
      final base = trackedMuscles['side_delts']!.target;
      expect(f.targetFor('side_delts').max, lessThan(base.max));
      expect(f.targetFor('glutes').min, greaterThan(trackedMuscles['glutes']!.target.min));
      expect(f.withLevel('side_delts', FocusLevel.normal).levelOf('side_delts'), FocusLevel.normal);
    });

    test('balance judges a "less" muscle against its lower band', () {
      // 8 sets of lateral raises last week (side delts band 5–10; "less" → 3–7).
      final sets = [
        for (var i = 0; i < 8; i++)
          LoggedSet(sessionId: 'a', exerciseId: 'cable-lateral-raise', date: DateTime(2026, 2, 25, 18), weightKg: 5, reps: 12, section: 'main'),
      ];
      final now = DateTime(2026, 3, 2);
      final weeks = weeklyMuscleVolume(sets, catalog, weeks: 4, now: now);
      final normal = analyzeBalance(weeks, sets, catalog, now: now);
      final less = analyzeBalance(weeks, sets, catalog, now: now, focus: MuscleFocus.none.withLevel('side_delts', FocusLevel.less));
      expect(normal.isHigh('side_delts'), isFalse);
      expect(less.isHigh('side_delts'), isTrue, reason: '8 sets is above 70 % of the 10-set max');
    });

    test('"go light" turns heavy sets into 10–15 reps and avoids barbell lifts for that muscle', () {
      final normal = gen(DayType.legs);
      final light = gen(DayType.legs, focus: MuscleFocus.none.withLight('quads', true).withLight('glutes', true));
      bool hitsLight(PlanItem i) => catalog.exercise(i.exerciseId)!.primary.any({'quads', 'glutes'}.contains);
      expect(mainOf(normal).where(hitsLight).any((i) => (i.repMin ?? 99) < 10), isTrue, reason: 'baseline has heavy sets');
      for (final i in mainOf(light).where(hitsLight)) {
        expect(i.repMin, greaterThanOrEqualTo(10), reason: i.exerciseId);
        expect(catalog.exercise(i.exerciseId)!.bar, isNull, reason: '${i.exerciseId}: no barbell lift');
      }
    });

    test('"less" muscles get no spare-time work; "more" muscles get it first', () {
      final less = gen(DayType.push, minutes: 90, focus: MuscleFocus.none.withLevel('side_delts', FocusLevel.less));
      final added = mainOf(less).where((i) => i.notes.startsWith('Extra time'));
      expect(added.any((i) => catalog.exercise(i.exerciseId)!.primary.contains('side_delts')), isFalse);
      final more = gen(DayType.pull, minutes: 90, focus: MuscleFocus.none.withLevel('biceps', FocusLevel.more));
      final firstExtra = mainOf(more).firstWhere((i) => i.notes.startsWith('Extra time'));
      expect(catalog.exercise(firstExtra.exerciseId)!.primary, contains('biceps'));
    });
  });
}
