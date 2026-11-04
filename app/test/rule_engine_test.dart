import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/equipment_presets.dart';
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
      expect(catalog.exercises.length, greaterThanOrEqualTo(120));
    });

    test('v2 fields: every exercise has 2–3 mistakes, every equipment a description', () {
      expect(catalog.version, 2);
      for (final e in catalog.exercises) {
        expect(e.mistakes.length, inInclusiveRange(2, 3), reason: e.id);
      }
      for (final e in catalog.equipment) {
        expect(e.description, isNotNull, reason: e.id);
        expect(e.description!.trim(), isNotEmpty, reason: e.id);
      }
      expect(catalog.equipmentById('elliptical')?.group, 'cardio');
      expect(catalog.exercise('elliptical-easy')?.equipment, ['elliptical']);
      expect(catalog.exercise('plank')!.isFloor, isTrue);
      expect(catalog.exercise('standing-quad-stretch')!.isFloor, isFalse);
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
        expect(w.blocks.firstWhere((b) => b.section == Section.cooldown).items, hasLength(3));
      });
    }

    group('classic machine gym (no medicine ball, foam roller, jump rope, rower)', () {
      final missing = EquipmentPreset.classicMachineGym.unavailable;
      final ctx = TrainingContext(
        catalog: catalog,
        equipmentAvailability: EquipmentPreset.classicMachineGym.availability(catalog),
      );
      final engine = RuleEngine(ctx);
      final workouts = {for (final day in DayType.values) day: engine.generate(day: day)};
      Exercise ex(PlanItem i) => catalog.exercise(i.exerciseId)!;
      List<Exercise> section(GeneratedWorkout w, Section s) =>
          w.blocks.firstWhere((b) => b.section == s).items.map(ex).toList();

      for (final day in DayType.values) {
        test('${day.label}: complete plan with machine cardio, power work and little floor work', () {
          final w = workouts[day]!;
          final all = w.blocks.expand((b) => b.items).map(ex).toList();
          for (final e in all) {
            expect(e.equipment.toSet().intersection(missing), isEmpty, reason: e.id);
          }
          final warmup = section(w, Section.warmup);
          expect(warmup.first.pattern, 'cardio');
          expect(warmup.first.equipment.single, isIn(['elliptical', 'treadmill', 'stationary_bike']));
          final main = section(w, Section.main);
          expect(main.length, inInclusiveRange(4, 7));
          final plyo = day == DayType.legs ? 'plyo_lower' : 'plyo_upper';
          expect(main.any((e) => e.pattern == plyo), isTrue, reason: '$plyo on ${day.name}');
          for (final s in [Section.warmup, Section.core, Section.cooldown]) {
            expect(section(w, s).where((e) => e.isFloor).length, lessThanOrEqualTo(1), reason: s.name);
          }
          expect(section(w, Section.core), hasLength(2));
          expect(section(w, Section.cooldown), hasLength(3));
          expect(w.estimatedMinutes, inInclusiveRange(45, 70));
        });
      }

      test('warm-up cardio rotates across day types', () {
        final cardio = {for (final w in workouts.values) section(w, Section.warmup).first.id};
        expect(cardio, hasLength(3));
      });

      test('presets cover every switchable equipment item', () {
        final switchable = catalog.equipment.where((e) => !e.alwaysAvailable).map((e) => e.id).toSet();
        expect(EquipmentPreset.everything.availability(catalog).keys.toSet(), switchable);
        expect(EquipmentPreset.everything.availability(catalog).values.every((v) => v), isTrue);
        final classic = EquipmentPreset.classicMachineGym.availability(catalog);
        expect(classic.entries.where((e) => !e.value).map((e) => e.key).toSet(), missing);
        expect(switchable.containsAll(missing), isTrue);
      });

      test('cardio rotation respects occupied and banned machines', () {
        final busy = RuleEngine(ctx.copyWith(occupiedEquipment: {'elliptical', 'treadmill'}));
        for (final day in DayType.values) {
          expect(section(busy.generate(day: day), Section.warmup).first.id, 'bike-easy');
        }
        final banned = RuleEngine(TrainingContext(
          catalog: catalog,
          equipmentAvailability: ctx.equipmentAvailability,
          preferences: {'bike-easy': 'banned'},
        ));
        for (final day in DayType.values) {
          expect(section(banned.generate(day: day), Section.warmup).first.id, isNot('bike-easy'));
        }
      });
    });

    test('floor exercises are still used when no standing option is left', () {
      final ctx = TrainingContext(
        catalog: catalog,
        equipmentAvailability: {for (final e in catalog.equipment) e.id: e.id == 'mat'},
      );
      final w = RuleEngine(ctx).generate(day: DayType.push);
      final core = w.blocks.firstWhere((b) => b.section == Section.core).items;
      expect(core, hasLength(2));
      expect(core.every((i) => catalog.exercise(i.exerciseId)!.isFloor), isTrue);
      final cooldown = w.blocks.firstWhere((b) => b.section == Section.cooldown).items;
      expect(cooldown.where((i) => catalog.exercise(i.exerciseId)!.isFloor).length, lessThanOrEqualTo(1));
    });

    test('machine preference stays below the recent-exercise bonus', () {
      expect(RuleEngine.machineBonus, lessThan(RuleEngine.recentBonus));
      final ctx = TrainingContext(catalog: catalog, recentExerciseIds: {'goblet-squat'});
      final w = RuleEngine(ctx).generate(day: DayType.legs);
      final ids = w.blocks.expand((b) => b.items).map((i) => i.exerciseId).toSet();
      expect(ids, contains('goblet-squat'));
      final fresh = RuleEngine(TrainingContext(catalog: catalog)).generate(day: DayType.push);
      final main = fresh.blocks.firstWhere((b) => b.section == Section.main).items;
      final press = main.map((i) => catalog.exercise(i.exerciseId)!).firstWhere((e) => e.pattern == 'horizontal_push');
      expect(RuleEngine(TrainingContext(catalog: catalog)).isMachine(press), isTrue, reason: press.id);
    });

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

    test('non-main swaps prefer standing / station options over floor work', () {
      final plank = catalog.exercise('plank')!;
      final swaps = RuleEngine(TrainingContext(catalog: catalog)).rankSwaps(plank);
      expect(swaps.first.exercise.isFloor, isFalse, reason: swaps.first.exercise.id);
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
