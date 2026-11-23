import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/rule_engine.dart';
import 'package:wfit/domain/stats.dart';

import 'helpers.dart';

/// Per-side prescriptions, plates-only bar logging, assisted machines and the rest / cool-down settings.
void main() {
  final catalog = loadTestCatalog();
  final loads = LoadModel(catalog);

  LoggedSet set(String ex, double? kg, int reps, {String session = 'a', double barKg = 0, bool assisted = false}) =>
      LoggedSet(
        sessionId: session,
        exerciseId: ex,
        date: DateTime(2026, 11, 1),
        weightKg: kg,
        reps: reps,
        barKg: barKg,
        assisted: assisted,
      );

  group('per side', () {
    test('label says "/ side" and the flag survives JSON', () {
      final e = catalog.exercise('bulgarian-split-squat')!;
      final item = PlanItem.fromExercise(e);
      expect(item.perSide, isTrue);
      expect(item.targetLabel, endsWith('/ side'));
      expect(PlanItem.fromJson(item.toJson()).perSide, isTrue);
      expect(PlanItem.fromExercise(catalog.exercise('barbell-back-squat')!).targetLabel, isNot(contains('side')));
    });

    test('timed per-side holds count both sides in the time estimate', () {
      final plank = PlanItem.fromExercise(catalog.exercise('side-plank')!);
      final both = plank.copyWith(perSide: false);
      expect(plank.estimateSeconds() - both.estimateSeconds(), plank.sets * plank.durationSeconds!);
    });
  });

  group('bar exercises (plates only)', () {
    test('real load adds the bar; user overrides win; assisted has no load', () {
      expect(loads.barKgFor('barbell-back-squat'), 20);
      expect(loads.barKgFor('ez-bar-curl'), 10);
      expect(loads.barKgFor('landmine-press'), 0);
      expect(loads.totalKg('barbell-back-squat', 40), 60);
      expect(loads.totalKg('dumbbell-bench-press', 20), 20);
      expect(loads.totalKg('assisted-pull-up', 30), isNull);
      final mine = LoadModel(catalog, LoadModel.parseOverrides('{"smith_machine": 15, "barbell": 15}'));
      expect(mine.barKgFor('smith-squat'), 15);
      expect(mine.totalKg('barbell-back-squat', 40), 55);
      expect(LoadModel.parseOverrides('not json'), isEmpty);
      expect(mine.weightLabel(catalog.exercise('barbell-back-squat'), 40), '40 kg plates (+15 bar)');
    });

    test('stats count plates + bar, progression stays in plates', () {
      final squat = catalog.exercise('barbell-back-squat')!;
      final sets = [for (var i = 0; i < 3; i++) set(squat.id, 40, 8, barKg: 20)];
      expect(sets.first.loadKg, 60);
      expect(sets.first.volume, 480);
      final best = computeBests(sets)[squat.id]!;
      expect(best.heaviest!.loadKg, 60);
      expect(best.bestE1rm, closeTo(60 * (1 + 8 / 30), 0.01));
      // Top of the range (5–8) on every set → add the increment to the logged plates.
      expect(adviseProgression(squat, [sets]).weightKg, 42.5);
    });

    test('an empty bar (0 kg of plates) still progresses by adding plates', () {
      final squat = catalog.exercise('barbell-back-squat')!;
      final a = adviseProgression(squat, [
        [for (var i = 0; i < 3; i++) set(squat.id, 0, 8, barKg: 20)],
      ]);
      expect(a.weightKg, 2.5);
      expect(a.lastSummary, contains('0 kg'));
    });
  });

  group('assisted machines', () {
    final assisted = catalog.exercise('assisted-pull-up')!; // 6–10 reps, 5 kg steps

    test('progress by taking assistance away', () {
      final a = adviseProgression(assisted, [
        [for (var i = 0; i < 3; i++) set(assisted.id, 30, 10, assisted: true)],
      ]);
      expect(a.weightKg, 25);
      expect(a.message, contains('less assistance'));
      expect(a.lastSummary, contains('assist'));
    });

    test('struggling twice adds assistance; too hard adds a step', () {
      final low = [for (var i = 0; i < 3; i++) set(assisted.id, 30, 4, assisted: true)];
      final a = adviseProgression(assisted, [low, [for (final s in low) set(s.exerciseId, 30, 4, session: 'b', assisted: true)]]);
      expect(a.weightKg, 35);
      final b = adviseProgression(assisted, [
        [for (var i = 0; i < 3; i++) set(assisted.id, 30, 8, assisted: true)],
      ], incrementSteps: -1);
      expect(b.weightKg, 35);
      expect(b.message, contains('more assistance'));
    });

    test('the hardest set is the one with the least assistance', () {
      final a = adviseProgression(assisted, [
        [set(assisted.id, 35, 10, assisted: true), set(assisted.id, 30, 10, assisted: true), set(assisted.id, 30, 10, assisted: true)],
      ]);
      expect(a.weightKg, 25);
    });
  });

  group('rest and cool-down settings', () {
    List<PlanItem> itemsOf(GeneratedWorkout w, Section s) =>
        w.blocks.where((b) => b.section == s).expand((b) => b.items).toList();

    test('short rest scales every rest period and shortens the estimate', () {
      final normal = RuleEngine(TrainingContext(catalog: catalog)).generate(day: DayType.push, date: DateTime(2026, 3, 2));
      final short = RuleEngine(TrainingContext(catalog: catalog, restScale: restScaleFor('short')))
          .generate(day: DayType.push, date: DateTime(2026, 3, 2));
      final nMain = itemsOf(normal, Section.main);
      final sMain = itemsOf(short, Section.main);
      expect(sMain.first.exerciseId, nMain.first.exerciseId);
      expect(sMain.first.restSeconds, (nMain.first.restSeconds * 0.7 / 5).round() * 5);
      expect(short.estimatedMinutes, lessThanOrEqualTo(normal.estimatedMinutes));
    });

    test('cool-down follows the number of stretches; 0 drops the block', () {
      for (final n in [0, 1, 2, 3]) {
        final w = RuleEngine(TrainingContext(catalog: catalog, cooldownStretches: n))
            .generate(day: DayType.legs, date: DateTime(2026, 3, 4));
        expect(itemsOf(w, Section.cooldown), hasLength(n), reason: '$n stretches');
        expect(w.blocks.any((b) => b.section == Section.cooldown), n > 0);
      }
    });

    test('rest scale helper', () {
      expect(restScaleFor('short'), 0.7);
      expect(restScaleFor('normal'), 1.0);
      expect(restScaleFor('long'), 1.3);
      final long = TrainingContext(catalog: catalog, restScale: 1.3);
      expect(long.scaleRest(0), 0);
      expect(long.scaleRest(120), 155);
    });
  });
}
