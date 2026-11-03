import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/rule_engine.dart';

import 'helpers.dart';

void main() {
  final catalog = loadTestCatalog();

  group('catalog', () {
    test('every exercise references known equipment and has a valid prescription', () {
      final equipment = catalog.equipment.map((e) => e.id).toSet();
      for (final e in catalog.exercises) {
        expect(e.equipment.every(equipment.contains), isTrue, reason: e.id);
        if (e.isTimed) {
          expect(e.durationSeconds, isNotNull, reason: e.id);
        } else {
          expect(e.repMin, isNotNull, reason: e.id);
          expect(e.repMin! <= e.repMax!, isTrue, reason: e.id);
        }
      }
      expect(catalog.exercises.length, greaterThanOrEqualTo(100));
    });
  });

  group('RuleEngine.generate', () {
    for (final day in DayType.values) {
      test('builds a complete ${day.label} session within ~60 minutes', () {
        final w = RuleEngine(TrainingContext(catalog: catalog)).generate(day: day);
        final sections = w.blocks.map((b) => b.section).toList();
        expect(sections, [Section.warmup, Section.main, Section.core, Section.cooldown]);
        final main = w.blocks.firstWhere((b) => b.section == Section.main).items;
        expect(main.length, inInclusiveRange(4, 7));
        for (final i in main) {
          final e = catalog.exercise(i.exerciseId)!;
          expect(e.fitsDay(day), isTrue, reason: e.id);
          expect({'strength', 'power'}, contains(e.category));
        }
        final ids = w.blocks.expand((b) => b.items).map((i) => i.exerciseId).toList();
        expect(ids.toSet().length, ids.length, reason: 'no duplicates');
        expect(w.estimatedMinutes, inInclusiveRange(45, 70));
      });
    }

    test('respects unavailable and occupied equipment', () {
      final ctx = TrainingContext(
        catalog: catalog,
        equipmentAvailability: {'barbell': false, 'cable_machine': false},
        occupiedEquipment: {'dumbbells'},
      );
      for (final day in DayType.values) {
        final w = RuleEngine(ctx).generate(day: day);
        for (final i in w.blocks.expand((b) => b.items)) {
          final e = catalog.exercise(i.exerciseId)!;
          expect(e.equipment, isNot(contains('barbell')));
          expect(e.equipment, isNot(contains('cable_machine')));
          expect(e.equipment, isNot(contains('dumbbells')));
        }
      }
    });

    test('still produces a bodyweight workout with no equipment at all', () {
      final ctx = TrainingContext(
        catalog: catalog,
        equipmentAvailability: {for (final e in catalog.equipment) e.id: false},
      );
      final w = RuleEngine(ctx).generate(day: DayType.legs);
      final main = w.blocks.firstWhere((b) => b.section == Section.main).items;
      expect(main, isNotEmpty);
      expect(main.every((i) => catalog.exercise(i.exerciseId)!.equipment.isEmpty), isTrue);
    });

    test('never picks banned exercises and favours recent ones', () {
      final ctx = TrainingContext(
        catalog: catalog,
        preferences: {'machine-chest-press': 'banned'},
        recentExerciseIds: {'dumbbell-bench-press'},
      );
      final w = RuleEngine(ctx).generate(day: DayType.push);
      final ids = w.blocks.expand((b) => b.items).map((i) => i.exerciseId).toSet();
      expect(ids, isNot(contains('machine-chest-press')));
      expect(ids, contains('dumbbell-bench-press'));
    });

    test('beginners do not get difficulty-3 exercises and core can be skipped', () {
      final w = RuleEngine(TrainingContext(catalog: catalog)).generate(day: DayType.pull, includeCore: false);
      expect(w.blocks.any((b) => b.section == Section.core), isFalse);
      for (final i in w.blocks.expand((b) => b.items)) {
        expect(catalog.exercise(i.exerciseId)!.difficulty, lessThanOrEqualTo(2));
      }
    });

    test('shorter sessions get fewer main exercises', () {
      final engine = RuleEngine(TrainingContext(catalog: catalog));
      int mainCount(int minutes) => engine
          .generate(day: DayType.push, sessionMinutes: minutes)
          .blocks
          .firstWhere((b) => b.section == Section.main)
          .items
          .length;
      expect(mainCount(40), lessThan(mainCount(75)));
    });
  });

  group('RuleEngine.rankSwaps', () {
    test('suggests same-pattern alternatives first and honours equipment', () {
      final ctx = TrainingContext(catalog: catalog, occupiedEquipment: {'flat_bench'});
      final bench = catalog.exercise('barbell-bench-press')!;
      final swaps = RuleEngine(ctx).rankSwaps(bench, day: DayType.push);
      expect(swaps, isNotEmpty);
      expect(swaps.first.exercise.pattern, 'horizontal_push');
      for (final s in swaps) {
        expect(s.exercise.equipment, isNot(contains('flat_bench')));
        expect(s.exercise.id, isNot(bench.id));
      }
    });

    test('core exercises are swapped for core exercises', () {
      final plank = catalog.exercise('plank')!;
      final swaps = RuleEngine(TrainingContext(catalog: catalog)).rankSwaps(plank);
      expect(swaps.every((s) => s.exercise.category == 'core'), isTrue);
    });
  });

  test('PlanItem JSON roundtrip and labels', () {
    const item = PlanItem(exerciseId: 'goblet-squat', sets: 3, repMin: 8, repMax: 12, restSeconds: 90, targetWeightKg: 16);
    final back = PlanItem.fromJson(item.toJson());
    expect(back.exerciseId, 'goblet-squat');
    expect(back.targetWeightKg, 16);
    expect(back.targetLabel, '3 × 8–12');
    const timed = PlanItem(exerciseId: 'plank', sets: 3, durationSeconds: 30, restSeconds: 30);
    expect(timed.targetLabel, '3 × 30s');
  });
}
