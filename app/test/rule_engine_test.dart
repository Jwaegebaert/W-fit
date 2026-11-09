import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/equipment_presets.dart';
import 'package:wfit/domain/limitations.dart';
import 'package:wfit/domain/muscles.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/program.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/rule_engine.dart';
import 'package:wfit/domain/stats.dart';
import 'package:wfit/domain/templates.dart';
import 'package:wfit/domain/training_load.dart';

import 'helpers.dart';

/// Copy of [e] with different stress regions (keeps the tests independent of the catalog's stress tags).
Exercise withStress(Exercise e, List<String> stress) => Exercise(
      id: e.id,
      name: e.name,
      category: e.category,
      splits: e.splits,
      primary: e.primary,
      secondary: e.secondary,
      pattern: e.pattern,
      equipment: e.equipment,
      difficulty: e.difficulty,
      compound: e.compound,
      unilateral: e.unilateral,
      isTimed: e.isTimed,
      sets: e.sets,
      repMin: e.repMin,
      repMax: e.repMax,
      durationSeconds: e.durationSeconds,
      rest: e.rest,
      incrementKg: e.incrementKg,
      badminton: e.badminton,
      instructions: e.instructions,
      tip: e.tip,
      mistakes: e.mistakes,
      stress: stress,
    );

/// The test catalog with neck stress on every vertical press, shrug, carry and on the barbell back squat.
Catalog neckTaggedCatalog(Catalog c) => Catalog(
      version: c.version,
      equipment: c.equipment,
      exercises: [
        for (final e in c.exercises)
          ({'vertical_push', 'shrug', 'carry'}.contains(e.pattern) || e.id == 'barbell-back-squat')
              ? withStress(e, {...e.stress, 'neck'}.toList())
              : e,
      ],
    );

List<PlanItem> mainOf(GeneratedWorkout w) => w.blocks.firstWhere((b) => b.section == Section.main).items;
Set<String> idsOf(GeneratedWorkout w) => w.blocks.expand((b) => b.items).map((i) => i.exerciseId).toSet();

/// Follows the generated plans for [weeks] weeks (Mon / Wed / Fri) and returns every plan with its program state.
List<(DateTime, ProgramState, GeneratedWorkout)> follow(
  TrainingContext base, {
  required int weeks,
  DateTime? start,
  Map<String, ExerciseTrend> Function(int week)? trends,
}) {
  final first = start ?? DateTime(2026, 1, 5);
  final sessions = <SessionInfo>[];
  final out = <(DateTime, ProgramState, GeneratedWorkout)>[];
  for (var w = 0; w < weeks; w++) {
    for (final offset in const [0, 2, 4]) {
      final date = addDays(first, 7 * w + offset);
      final day = sessions.isEmpty ? DayType.push : sessions.last.dayType.next;
      final program = computeProgramState(sessions, now: date, day: day);
      final workout = RuleEngine(base.copyWith(program: program, trends: trends?.call(w))).generate(day: day, date: date);
      out.add((date, program, workout));
      sessions.add(SessionInfo(
        id: 's${sessions.length}',
        date: date,
        dayType: day,
        rating: 4,
        effort: 7,
        mainExerciseIds: mainOf(workout).map((i) => i.exerciseId).toList(),
        meta: workout.meta,
      ));
    }
  }
  return out;
}

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
        for (final r in e.stress) {
          expect(regionVocabulary, contains(r), reason: '${e.id} stress $r');
        }
      }
      expect(catalog.exercises.length, greaterThanOrEqualTo(120));
    });

    test('v2+ fields: every exercise has 2–3 mistakes, every equipment a description', () {
      expect(catalog.version, greaterThanOrEqualTo(2));
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

  group('templates', () {
    test('A and B variant for every day type, each with an anchor and a flex slot', () {
      for (final day in DayType.values) {
        for (final v in const ['A', 'B']) {
          final t = templateFor(day, v);
          expect(t.day, day);
          expect(t.variant, v);
          expect(t.slots.where((s) => s.role == SlotRole.anchor), hasLength(1));
          expect(t.slots.where((s) => s.role == SlotRole.flex), hasLength(1));
          expect(t.slots.where((s) => s.role == SlotRole.power).length, lessThanOrEqualTo(1));
        }
      }
    });

    test('use the v3 patterns (shrug, adduction, pullover, back extension, forearm, carry, glute isolation)', () {
      expect(templatePatterns,
          containsAll(['shrug', 'hip_adduction', 'pullover', 'back_extension', 'forearm', 'carry', 'glute_isolation']));
    });

    test('variant emphasis follows the programming model', () {
      String anchor(DayType d, String v) => templateFor(d, v).slots.firstWhere((s) => s.role == SlotRole.anchor).patterns.first;
      expect(anchor(DayType.push, 'A'), 'horizontal_push');
      expect(anchor(DayType.push, 'B'), 'vertical_push');
      expect(anchor(DayType.pull, 'A'), 'vertical_pull');
      expect(anchor(DayType.pull, 'B'), 'horizontal_pull');
      expect(anchor(DayType.legs, 'A'), 'squat');
      expect(anchor(DayType.legs, 'B'), 'hinge');
    });

    test('role schemes: anchors 6–10 reps, accessories 10–15, deload −1 set (min 2)', () {
      expect(RoleScheme.anchor.repMin, 6);
      expect(RoleScheme.anchor.repMax, 10);
      expect(RoleScheme.accessory.repMax, 15);
      expect(RoleScheme.baseSets(SlotRole.anchor, blockWeek: 1, deload: false), 3);
      expect(RoleScheme.baseSets(SlotRole.anchor, blockWeek: 4, deload: false), 4);
      expect(RoleScheme.baseSets(SlotRole.anchor, blockWeek: 6, deload: true), 2);
      expect(RoleScheme.baseSets(SlotRole.accessory, blockWeek: 6, deload: true), 2);
      expect(RoleScheme.baseSets(SlotRole.accessory, blockWeek: 6, deload: true, override: 4), 3);
    });
  });

  group('RuleEngine.generate', () {
    for (final day in DayType.values) {
      test('builds a complete ${day.label} session within the time budget', () {
        final w = RuleEngine(TrainingContext(catalog: catalog)).generate(day: day);
        final sections = w.blocks.map((b) => b.section).toList();
        expect(sections, [Section.warmup, Section.main, Section.core, Section.cooldown]);
        final main = mainOf(w);
        expect(main.length, inInclusiveRange(4, 8));
        for (final i in main) {
          final e = catalog.exercise(i.exerciseId)!;
          expect(e.fitsDay(day), isTrue, reason: e.id);
          expect({'strength', 'power'}, contains(e.category));
        }
        final ids = w.blocks.expand((b) => b.items).map((i) => i.exerciseId).toList();
        expect(ids.toSet().length, ids.length, reason: 'no duplicates');
        expect(w.estimatedMinutes, inInclusiveRange(45, 65));
        expect(w.blocks.firstWhere((b) => b.section == Section.cooldown).items, hasLength(3));
        expect(w.roles.values.where((r) => r == SlotRole.anchor), hasLength(1));
        expect(w.meta.program, 'Block 1 · Week 1 · ${day.label} A');
        expect(w.meta.variant, 'A');
        expect(w.rationale, isNotEmpty);
        expect(w.rationale.length, lessThanOrEqualTo(6));
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
        test('${day.label}: complete plan with machine cardio, ≤ 1 power exercise and little floor work', () {
          final w = workouts[day]!;
          final all = w.blocks.expand((b) => b.items).map(ex).toList();
          for (final e in all) {
            expect(e.equipment.toSet().intersection(missing), isEmpty, reason: e.id);
          }
          final warmup = section(w, Section.warmup);
          expect(warmup.first.pattern, 'cardio');
          expect(warmup.first.equipment.single, isIn(['elliptical', 'treadmill', 'stationary_bike']));
          final main = section(w, Section.main);
          expect(main.length, inInclusiveRange(4, 8));
          expect(main.where((e) => e.category == 'power').length, lessThanOrEqualTo(1));
          for (final s in [Section.warmup, Section.core, Section.cooldown]) {
            expect(section(w, s).where((e) => e.isFloor).length, lessThanOrEqualTo(1), reason: s.name);
          }
          expect(section(w, Section.core), hasLength(2));
          expect(section(w, Section.cooldown), hasLength(3));
          expect(w.estimatedMinutes, inInclusiveRange(45, 65));
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
        final banned = RuleEngine(ctx.copyWith(preferences: {'bike-easy': 'banned'}));
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

    test('prefers machines for the heavy press in a fresh plan', () {
      final engine = RuleEngine(TrainingContext(catalog: catalog));
      final press = mainOf(engine.generate(day: DayType.push))
          .map((i) => catalog.exercise(i.exerciseId)!)
          .firstWhere((e) => e.pattern == 'horizontal_push');
      expect(engine.isMachine(press), isTrue, reason: press.id);
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
      final main = mainOf(w);
      expect(main, isNotEmpty);
      expect(main.every((i) => catalog.exercise(i.exerciseId)!.equipment.isEmpty), isTrue);
    });

    test('never picks banned exercises', () {
      final ctx = TrainingContext(catalog: catalog, preferences: {'machine-chest-press': 'banned'});
      for (final day in DayType.values) {
        expect(idsOf(RuleEngine(ctx).generate(day: day)), isNot(contains('machine-chest-press')));
      }
    });

    test('beginners do not get difficulty-3 exercises and core can be skipped', () {
      final w = RuleEngine(TrainingContext(catalog: catalog)).generate(day: DayType.pull, includeCore: false);
      expect(w.blocks.any((b) => b.section == Section.core), isFalse);
      for (final i in w.blocks.expand((b) => b.items)) {
        expect(catalog.exercise(i.exerciseId)!.difficulty, lessThanOrEqualTo(2));
      }
    });

    test('shorter sessions get fewer main exercises; every length stays within its budget', () {
      final engine = RuleEngine(TrainingContext(catalog: catalog));
      int mainCount(int minutes) => mainOf(engine.generate(day: DayType.push, sessionMinutes: minutes)).length;
      expect(mainCount(40), lessThan(mainCount(75)));
      for (final minutes in const [45, 60, 75]) {
        for (final day in DayType.values) {
          expect(engine.generate(day: day, sessionMinutes: minutes).estimatedMinutes,
              lessThanOrEqualTo(minutes + 5), reason: '$day $minutes min');
        }
      }
    });

    test('rep schemes per role: anchor 6–10 with ≥ 2 min rest, accessories 10–15', () {
      final w = RuleEngine(TrainingContext(catalog: catalog)).generate(day: DayType.push);
      for (final i in mainOf(w)) {
        final role = w.roles[i.exerciseId]!;
        if (i.isTimed) continue;
        if (role == SlotRole.anchor) {
          expect(i.repMin, greaterThanOrEqualTo(6));
          expect(i.repMax, lessThanOrEqualTo(10));
          expect(i.restSeconds, greaterThanOrEqualTo(120));
        }
        if (role == SlotRole.accessory) expect(i.repMax, greaterThanOrEqualTo(12));
      }
    });
  });

  group('programming model', () {
    final ctx = TrainingContext(
      catalog: catalog,
      equipmentAvailability: EquipmentPreset.classicMachineGym.availability(catalog),
    );

    test('A/B variants differ, anchors and accessories persist within a block', () {
      final plans = follow(ctx, weeks: 5);
      final push = plans.where((p) => p.$3.meta.program.contains('Push')).toList();
      expect(push.map((p) => p.$3.meta.variant).toList(), ['A', 'B', 'A', 'B', 'A']);
      final a1 = mainOf(push[0].$3).map((i) => i.exerciseId).toSet();
      final b1 = mainOf(push[1].$3).map((i) => i.exerciseId).toSet();
      expect(a1.intersection(b1).length / a1.length, lessThan(0.8));
      Set<String> withRole(GeneratedWorkout w, SlotRole r) =>
          w.roles.entries.where((e) => e.value == r).map((e) => e.key).toSet();
      for (final role in [SlotRole.anchor, SlotRole.secondary, SlotRole.accessory]) {
        expect(withRole(push[2].$3, role), withRole(push[0].$3, role), reason: role.name);
        expect(withRole(push[4].$3, role), withRole(push[0].$3, role), reason: role.name);
      }
      expect(push[2].$3.meta.program, 'Block 1 · Week 3 · Push A');
    });

    test('a new block keeps a progressing anchor, rotates accessories and stalled anchors', () {
      final plans = follow(ctx, weeks: 7);
      final pushA = plans.where((p) => p.$3.meta.program.endsWith('Push A')).toList();
      final block1 = pushA.first.$3;
      final block2 = pushA.last.$3;
      expect(block2.meta.program, 'Block 2 · Week 1 · Push A');
      String anchorOf(GeneratedWorkout w) => w.roles.entries.firstWhere((e) => e.value == SlotRole.anchor).key;
      expect(anchorOf(block2), anchorOf(block1), reason: 'progressing anchor kept for a 2nd block');

      final block1Push = plans
          .where((p) => p.$2.blockNumber == 1 && p.$3.meta.program.contains('Push'))
          .expand((p) => p.$3.roles.entries.where((e) => e.value == SlotRole.accessory).map((e) => e.key))
          .toSet();
      final triceps1 = block1Push.where((id) => catalog.exercise(id)!.pattern == 'triceps').toSet();
      final triceps2 = block2.roles.keys.where((id) => catalog.exercise(id)!.pattern == 'triceps').toSet();
      expect(triceps2.intersection(triceps1), isEmpty, reason: 'triceps accessory rotated ($triceps1 → $triceps2)');

      final stalled = follow(ctx, weeks: 7, trends: (w) => w == 6 ? {anchorOf(block1): ExerciseTrend.stalled} : const {});
      final rotated = stalled.where((p) => p.$3.meta.program == 'Block 2 · Week 1 · Push A').single.$3;
      expect(anchorOf(rotated), isNot(anchorOf(block1)));
      expect(catalog.exercise(anchorOf(rotated))!.pattern, 'horizontal_push');
      expect(rotated.rationale.join(' '), contains('New anchor'));
    });

    test('an anchor used for two blocks rotates in the third', () {
      final plans = follow(ctx, weeks: 13);
      String anchorOf(GeneratedWorkout w) => w.roles.entries.firstWhere((e) => e.value == SlotRole.anchor).key;
      final pushA = {
        for (final p in plans.where((p) => p.$3.meta.program.endsWith('Push A'))) p.$2.blockNumber: anchorOf(p.$3),
      };
      expect(pushA[2], pushA[1]);
      expect(pushA[3], isNot(pushA[1]));
    });

    test('deload: −1 set, no power, ~90 % load', () {
      final day = DateTime(2026, 2, 9);
      final history = {
        'machine-chest-press': [
          [for (var i = 0; i < 3; i++) LoggedSet(sessionId: 'x', exerciseId: 'machine-chest-press', date: DateTime(2026, 2, 2), weightKg: 50, reps: 8)],
        ],
      };
      ProgramState state(bool deload) =>
          ProgramState(date: day, day: DayType.push, blockNumber: 1, blockWeek: deload ? 6 : 5, deload: deload, deloadReason: deload ? 'Planned deload (week 6 of 6)' : null);
      final normal = RuleEngine(ctx.copyWith(history: history, program: state(false))).generate(day: DayType.push, date: day);
      final deload = RuleEngine(ctx.copyWith(history: history, program: state(true))).generate(day: DayType.push, date: day);
      expect(deload.meta.deload, isTrue);
      expect(deload.title, contains('Deload'));
      final press = mainOf(normal).firstWhere((i) => i.exerciseId == 'machine-chest-press');
      final light = mainOf(deload).firstWhere((i) => i.exerciseId == 'machine-chest-press');
      expect(press.targetWeightKg, 50);
      expect(light.targetWeightKg, 45);
      expect(light.sets, press.sets - 2); // week 5 anchor = 4 sets, deload anchor = 2
      for (final i in mainOf(deload)) {
        expect(i.sets, inInclusiveRange(2, 3));
        expect(catalog.exercise(i.exerciseId)!.category, isNot('power'));
      }
      expect(deload.rationale.first, contains('Planned deload'));
    });

    test('power: at most one per session, protected once per week, none once two were done this week', () {
      final monday = DateTime(2026, 3, 2);
      final power = catalog.exercises.where((e) => e.category == 'power' && e.fitsDay(DayType.pull)).first.id;
      SessionInfo s(String id, int dayOffset, DayType d) => SessionInfo(
          id: id, date: addDays(monday, dayOffset), dayType: d, mainExerciseIds: [power], meta: const PlanMeta(program: 'x', variant: 'A'));
      final sessions = [s('a', 0, DayType.pull), s('b', 1, DayType.push)];
      final program = computeProgramState(sessions, now: addDays(monday, 3), day: DayType.legs);
      expect(program.variant, 'A');
      final w = RuleEngine(ctx.copyWith(program: program)).generate(day: DayType.legs, date: addDays(monday, 3));
      expect(mainOf(w).where((i) => catalog.exercise(i.exerciseId)!.category == 'power'), isEmpty);
      for (final minutes in const [60, 75]) {
        final fresh = RuleEngine(ctx.copyWith(program: ProgramState.initial(DayType.legs, monday)))
            .generate(day: DayType.legs, date: monday, sessionMinutes: minutes);
        final powerItems = mainOf(fresh).where((i) => catalog.exercise(i.exerciseId)!.category == 'power').toList();
        expect(powerItems, hasLength(1), reason: '$minutes min');
        expect(fresh.roles[powerItems.single.exerciseId], SlotRole.power);
        expect(fresh.rationale.join(' '), contains('Power:'));
      }
    });
  });

  group('balance-driven volume', () {
    MuscleStatus status(String m, {double last = 6, int? days = 3, VolumeStatus s = VolumeStatus.ok}) => MuscleStatus(
          muscle: m,
          thisWeek: 0,
          lastWeek: last,
          recentAvg: last,
          targetMin: trackedMuscles[m]!.target.min,
          targetMax: trackedMuscles[m]!.target.max,
          status: s,
          weeksUnder: s == VolumeStatus.under ? 1 : 0,
          daysSinceTrained: days,
          trend: VolumeTrend.flat,
          lastActiveWeek: last,
        );
    BalanceReport report({int bicepsDays = 5, bool chestHigh = false}) => BalanceReport(
          asOf: DateTime(2026, 3, 2),
          muscles: [
            status('biceps', last: 2, days: bicepsDays, s: VolumeStatus.under),
            status('chest', last: chestHigh ? 14 : 8, s: chestHigh ? VolumeStatus.high : VolumeStatus.ok),
          ],
          priorities: const [
            MusclePriority(muscle: 'biceps', score: 0.5, extraSets: 2, reason: '2/4 sets last week'),
          ],
        );
    final ctx = TrainingContext(catalog: catalog);

    test('flex slot trains an under-target muscle that is not today\'s target', () {
      final w = RuleEngine(ctx).generate(day: DayType.push, date: DateTime(2026, 3, 2), balance: report());
      final flex = w.roles.entries.where((e) => e.value == SlotRole.flex).map((e) => catalog.exercise(e.key)!).toList();
      expect(flex, hasLength(1));
      expect(flex.single.primary, contains('biceps'));
      expect(mainOf(w).firstWhere((i) => i.exerciseId == flex.single.id).sets, 3, reason: 'extraSets 2 → 3 flex sets');
      expect(w.focusMuscles, contains('biceps'));
      expect(w.meta.focus, contains('biceps'));
      expect(w.rationale.join(' '), contains('biceps'));
    });

    test('no flex for a muscle trained within 48 h', () {
      final w = RuleEngine(ctx).generate(day: DayType.push, date: DateTime(2026, 3, 2), balance: report(bicepsDays: 1));
      expect(w.roles.values, isNot(contains(SlotRole.flex)));
    });

    test('priority muscles get +1 set on the slots that train them (≤ +3 per session)', () {
      final plain = RuleEngine(ctx).generate(day: DayType.pull, date: DateTime(2026, 3, 4));
      final boosted = RuleEngine(ctx).generate(day: DayType.pull, date: DateTime(2026, 3, 4), balance: report());
      int bicepsSets(GeneratedWorkout w) => mainOf(w)
          .where((i) => catalog.exercise(i.exerciseId)!.primary.contains('biceps'))
          .fold(0, (s, i) => s + i.sets);
      expect(bicepsSets(boosted), greaterThan(bicepsSets(plain)));
      expect(boosted.rationale.any((l) => l.startsWith('Biceps') && l.contains('+1 set')), isTrue);
      final extra = mainOf(boosted).fold(0, (s, i) => s + i.sets) - mainOf(plain).fold(0, (s, i) => s + i.sets);
      expect(extra, lessThanOrEqualTo(RuleEngine.maxExtraSetsPerSession + 3));
    });

    test('muscles above target lose a set on isolation work (min 2)', () {
      final w = RuleEngine(ctx).generate(day: DayType.push, date: DateTime(2026, 3, 2), balance: report(chestHigh: true));
      final fly = mainOf(w).firstWhere((i) => catalog.exercise(i.exerciseId)!.pattern == 'chest_fly');
      expect(fly.sets, 2);
      expect(w.rationale.join(' '), contains('−1 set'));
    });
  });

  group('limitations', () {
    final tagged = neckTaggedCatalog(catalog);
    FeedbackRecord neck(int severity) => FeedbackRecord(
          id: 'n$severity',
          createdAt: DateTime(2026, 3, 1),
          kind: FeedbackKind.pain,
          region: 'neck',
          severity: severity,
        );
    TrainingContext ctxFor(List<FeedbackRecord> fb) =>
        TrainingContext(catalog: tagged, limitations: LimitationPolicy.fromFeedback(fb, tagged, now: DateTime(2026, 3, 2)));

    test('severity 2 neck pain removes every neck-stress exercise and is explained', () {
      final ctx = ctxFor([neck(2)]);
      for (final day in DayType.values) {
        for (final variant in const ['A', 'B']) {
          final program = ProgramState.initial(day, DateTime(2026, 3, 2)).copyVariant(day, variant);
          final w = RuleEngine(ctx.copyWith(program: program)).generate(day: day, date: DateTime(2026, 3, 2));
          for (final id in idsOf(w)) {
            expect(tagged.exercise(id)!.stress, isNot(contains('neck')), reason: '$day $variant $id');
          }
          expect(w.rationale.any((l) => l.toLowerCase().contains('neck')), isTrue, reason: '$day $variant');
        }
      }
    });

    test('severity 1 only penalises: neck-stress exercises are used only when nothing else fits', () {
      final partly = Catalog(
        version: catalog.version,
        equipment: catalog.equipment,
        exercises: [
          for (final e in catalog.exercises)
            e.pattern == 'vertical_push' && e.id != 'landmine-press' ? withStress(e, const ['neck', 'shoulder']) : e,
        ],
      );
      final program = ProgramState.initial(DayType.push, DateTime(2026, 3, 2)).copyVariant(DayType.push, 'B');
      String anchor(Catalog c) {
        final policy = LimitationPolicy.fromFeedback([neck(1)], c, now: DateTime(2026, 3, 2));
        final w = RuleEngine(TrainingContext(catalog: c, limitations: policy, program: program))
            .generate(day: DayType.push, date: DateTime(2026, 3, 2));
        return w.roles.entries.firstWhere((e) => e.value == SlotRole.anchor).key;
      }

      expect(anchor(partly), 'landmine-press');
      // Every vertical press stresses the neck in the tagged catalog: mild pain still allows one.
      expect(tagged.exercise(anchor(tagged))!.pattern, 'vertical_push');
    });

    test('severity 3 elbow pain also removes direct biceps / triceps / forearm work', () {
      final ctx = ctxFor([
        FeedbackRecord(id: 'e', createdAt: DateTime(2026, 3, 1), kind: FeedbackKind.pain, region: 'elbow', severity: 3),
      ]);
      for (final day in [DayType.push, DayType.pull]) {
        for (final id in idsOf(RuleEngine(ctx).generate(day: day))) {
          expect(tagged.exercise(id)!.primary.toSet().intersection({'biceps', 'triceps', 'forearms'}), isEmpty, reason: id);
        }
      }
    });

    test('rankSwaps never suggests excluded exercises', () {
      final ctx = ctxFor([neck(2)]);
      final press = tagged.exercise('machine-shoulder-press')!;
      final swaps = RuleEngine(ctx).rankSwaps(press, day: DayType.push, limit: 20);
      expect(swaps, isNotEmpty);
      for (final s in swaps) {
        expect(s.exercise.stress, isNot(contains('neck')), reason: s.exercise.id);
      }
    });

    test('adjustForLimitations replaces excluded exercises instantly and lists the changes', () {
      final before = RuleEngine(TrainingContext(catalog: tagged))
          .generate(day: DayType.push, program: ProgramState.initial(DayType.push, DateTime(2026, 3, 2)).copyVariant(DayType.push, 'B'));
      final neckIds = idsOf(before).where((id) => tagged.exercise(id)!.stress.contains('neck')).toSet();
      expect(neckIds, isNotEmpty);
      final adjusted = RuleEngine(ctxFor([neck(2)])).adjustForLimitations(before.blocks, DayType.push);
      expect(adjusted.changed, isTrue);
      expect(adjusted.changes.map((c) => c.from).toSet(), neckIds);
      for (final c in adjusted.changes) {
        expect(c.reason, contains('neck'));
        if (c.to != null) expect(tagged.exercise(c.to!)!.stress, isNot(contains('neck')));
      }
      final after = adjusted.blocks.expand((b) => b.items).toList();
      for (final i in after) {
        expect(tagged.exercise(i.exerciseId)!.stress, isNot(contains('neck')));
      }
      // Replacements keep the prescription of the slot they fill.
      final anchorBefore = mainOf(before).first;
      final anchorAfter = adjusted.blocks.firstWhere((b) => b.section == Section.main).items.first;
      expect(anchorAfter.sets, anchorBefore.sets);
      expect(RuleEngine(TrainingContext(catalog: tagged)).adjustForLimitations(before.blocks, DayType.push).changed, isFalse);
    });

    test('too_hard feedback lowers the next target weight by one increment', () {
      final history = {
        'machine-chest-press': [
          [for (var i = 0; i < 3; i++) LoggedSet(sessionId: 'x', exerciseId: 'machine-chest-press', date: DateTime(2026, 2, 23), weightKg: 50, reps: 8)],
        ],
      };
      final fb = [
        FeedbackRecord(id: 'h', createdAt: DateTime(2026, 2, 23), kind: FeedbackKind.tooHard, exerciseId: 'machine-chest-press'),
      ];
      final base = TrainingContext(
          catalog: catalog, history: history, program: ProgramState.initial(DayType.push, DateTime(2026, 3, 2)));
      double? target(TrainingContext c) => mainOf(RuleEngine(c).generate(day: DayType.push))
          .firstWhere((i) => i.exerciseId == 'machine-chest-press')
          .targetWeightKg;
      expect(target(base), 50);
      expect(target(base.copyWith(limitations: LimitationPolicy.fromFeedback(fb, catalog, now: DateTime(2026, 3, 2)))), 45);
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

  group('plan JSON', () {
    test('PlanItem roundtrip and labels', () {
      const item = PlanItem(exerciseId: 'goblet-squat', sets: 3, repMin: 8, repMax: 12, restSeconds: 90, targetWeightKg: 16);
      final back = PlanItem.fromJson(item.toJson());
      expect(back.exerciseId, 'goblet-squat');
      expect(back.targetWeightKg, 16);
      expect(back.targetLabel, '3 × 8–12');
      const timed = PlanItem(exerciseId: 'plank', sets: 3, durationSeconds: 30, restSeconds: 30);
      expect(timed.targetLabel, '3 × 30s');
    });

    test('PlanMeta matches the metaJson contract exactly', () {
      final meta = RuleEngine(TrainingContext(catalog: catalog)).generate(day: DayType.pull).meta.withChanges(
          [const PlanChange(from: 'a', to: 'b', reason: 'Avoids neck load (neck pain)'), const PlanChange(from: 'c', reason: 'x')]);
      final json = meta.toJson();
      expect(json.keys.toList(), ['program', 'variant', 'deload', 'focus', 'rationale', 'changes']);
      expect((json['changes'] as List).first, {'from': 'a', 'to': 'b', 'reason': 'Avoids neck load (neck pain)'});
      final back = PlanMeta.decode(meta.encode());
      expect(back.program, 'Block 1 · Week 1 · Pull A');
      expect(back.variant, 'A');
      expect(back.changes.last.to, isNull);
      expect(back.rationale, meta.rationale);
      expect(PlanMeta.decode('{}').isEmpty, isTrue);
      expect(PlanMeta.decode('not json').isEmpty, isTrue);
      expect(meta.encode().length, lessThan(8000));
    });
  });
}
