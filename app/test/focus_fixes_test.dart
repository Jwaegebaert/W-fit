import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/api/api_client.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/muscles.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/program.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/rule_engine.dart';
import 'package:wfit/providers.dart';

import 'helpers.dart';

/// Regressions: muscle focus on coach-refined plans and inside a running block, the spare-time note.
void main() {
  final catalog = loadTestCatalog();
  List<PlanItem> mainItems(List<PlanBlock> blocks) => blocks.firstWhere((b) => b.section == Section.main).items;
  List<PlanItem> mainOf(GeneratedWorkout w) => mainItems(w.blocks);
  bool isBar(PlanItem i) => catalog.exercise(i.exerciseId)!.bar != null;
  LoggedSet set(String ex, double kg, int reps, {double bar = 0}) => LoggedSet(
      sessionId: 'a', exerciseId: ex, date: DateTime(2026, 3, 1), weightKg: kg, reps: reps, barKg: bar, section: 'main');

  group('go light', () {
    test('replaces a barbell / Smith lift that is already running in the block, and the kept anchor of the last block', () {
      final d1 = DateTime(2026, 3, 4);
      final first = RuleEngine(TrainingContext(catalog: catalog)).generate(day: DayType.legs, date: d1);
      expect(mainOf(first).any(isBar), isTrue, reason: 'baseline has a bar lift');
      final session = SessionInfo(
        id: 's',
        date: d1,
        dayType: DayType.legs,
        rating: 4,
        effort: 7,
        mainExerciseIds: [for (final i in mainOf(first)) i.exerciseId],
        meta: first.meta,
      );
      final focus = MuscleFocus.none.withLight('quads', true).withLight('glutes', true).withLight('hamstrings', true);
      for (final days in [7, 14, 21, 28, 42]) {
        final date = d1.add(Duration(days: days));
        final prog = computeProgramState([session], now: date, day: DayType.legs, catalog: catalog);
        final w = RuleEngine(TrainingContext(catalog: catalog, focus: focus, program: prog)).generate(day: DayType.legs, date: date);
        expect(mainOf(w).where(isBar).map((i) => i.exerciseId), isEmpty, reason: '${w.meta.program} (+$days days)');
      }
    });

    test('does not prescribe the old heavy weight for 10–15 reps', () {
      final press = catalog.exercise('leg-press')!;
      final heavy = [for (var i = 0; i < 3; i++) set(press.id, 100, 7)];
      final ctx = TrainingContext(
        catalog: catalog,
        focus: MuscleFocus.none.withLight('quads', true),
        history: {press.id: [heavy]},
        preferences: {for (final e in catalog.exercises) if (e.pattern == 'squat' && e.id != press.id) e.id: 'banned'},
      );
      final w = RuleEngine(ctx).generate(day: DayType.legs, date: DateTime(2026, 3, 4));
      final item = mainOf(w).firstWhere((i) => i.exerciseId == press.id);
      expect(item.repMin, greaterThanOrEqualTo(10));
      // 100 kg × 7 ≈ 123 kg e1RM: 12 easy reps (3 in reserve) is about 80 kg.
      expect(item.targetWeightKg, lessThanOrEqualTo(85));
      expect(item.targetWeightKg, greaterThanOrEqualTo(60));
    });
  });

  group('spare-time note', () {
    test('only claims the muscles are on target when none of today\'s muscles needs more', () {
      for (final day in DayType.values) {
        final w = RuleEngine(TrainingContext(catalog: catalog)).generate(day: day, date: DateTime(2026, 3, 2), sessionMinutes: 120);
        double planned(String m) => mainOf(w).fold(0.0, (s, i) {
              final e = catalog.exercise(i.exerciseId)!;
              return s + (e.primary.contains(m) ? i.sets : e.secondary.contains(m) ? secondarySetWeight * i.sets : 0);
            });
        // Without training history the engine judges today's plan against the middle of each weekly band.
        final short = [
          for (final m in trackedMuscleInfo)
            if (m.group.name == day.name && planned(m.id) < m.target.mid) m.id,
        ];
        final note = w.rationale.firstWhere((l) => l.contains('min to spare'));
        expect(note.contains('already at their weekly target'), short.isEmpty, reason: '${day.name}: short on $short – $note');
      }
    });

    test('a "more" muscle that already reached its raised target gets no spare-time exercise', () {
      final focus = MuscleFocus.none.withLevel('biceps', FocusLevel.more);
      final w = RuleEngine(TrainingContext(catalog: catalog, focus: focus))
          .generate(day: DayType.pull, date: DateTime(2026, 3, 2), sessionMinutes: 120);
      final extra = mainOf(w).where((i) => i.notes == 'Extra time · biceps').length;
      expect(extra, lessThanOrEqualTo(1));
    });
  });

  group('focus change on a coach-refined plan', () {
    late ProviderContainer c;
    late Repository repo;
    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final db = AppDatabase(NativeDatabase.memory());
      c = ProviderContainer(overrides: [
        catalogProvider.overrideWithValue(catalog),
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(ApiClient(ApiConfig.empty)),
      ]);
      repo = c.read(repositoryProvider);
      addTearDown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        c.dispose();
        await db.close();
      });
    });

    Future<String> aiPlan(List<PlanItem> main) => repo.savePlanned(
          date: DateTime.now().add(const Duration(days: 1)),
          day: DayType.legs,
          title: 'Coach plan',
          source: 'ai',
          coachNote: 'As you asked.',
          blocks: [PlanBlock(section: Section.main, items: main)],
        );
    PlanItem item(String id, {int sets = 3, int lo = 6, int hi = 10, double? kg}) =>
        PlanItem(exerciseId: id, sets: sets, repMin: lo, repMax: hi, restSeconds: 120, targetWeightKg: kg);

    test('go light swaps its barbell lifts, raises the reps and keeps the rest of the coach\'s plan', () async {
      final id = await aiPlan([
        item('barbell-back-squat', kg: 60),
        item('leg-extension', lo: 8, hi: 10, kg: 40),
        item('seated-calf-raise', lo: 10, hi: 15),
      ]);
      await c.read(coachServiceProvider).saveMuscleFocus(MuscleFocus.none.withLight('quads', true));
      final plan = (await repo.plannedById(id))!;
      final items = mainItems(Repository.decodeBlocks(plan.blocksJson));
      expect(plan.title, 'Coach plan');
      expect(plan.source, 'ai');
      expect(items, hasLength(3));
      expect(isBar(items.first), isFalse);
      expect(items.first.exerciseId, isNot('barbell-back-squat'));
      expect(items[0].repMin, greaterThanOrEqualTo(10));
      expect(items[1].exerciseId, 'leg-extension');
      expect(items[1].repMin, 10);
      expect(items[1].targetWeightKg, isNull, reason: 'the coach\'s weight was for 8–10 reps');
      expect(items[2].exerciseId, 'seated-calf-raise');
      final change = PlanMeta.decode(plan.metaJson).changes.single;
      expect(change.from, 'barbell-back-squat');
      expect(change.reason, contains('Go light'));
    });

    test('stretch times from before the per-side change are converted once, newer plans are left alone', () async {
      PlanItem hold(String id, int sec) => PlanItem(exerciseId: id, sets: 1, durationSeconds: sec, restSeconds: 0);
      final date = DateTime.now().add(const Duration(days: 1));
      Future<String> save(DateTime d, List<PlanItem> items) => repo.savePlanned(
          date: d, day: DayType.legs, title: 'Legs', source: 'ai', coachNote: '', blocks: [PlanBlock(section: Section.cooldown, items: items)]);
      Future<List<int?>> seconds(String id) async => [
            for (final b in Repository.decodeBlocks((await repo.plannedById(id))!.blocksJson)) ...b.items.map((i) => i.durationSeconds),
          ];
      final old = await save(date, [hold('hamstring-stretch', 60), hold('pigeon-stretch', 90), hold('side-plank', 25), hold('suitcase-carry', 40)]);
      // Already per side, but the server dropped the perSide marker: must not be halved.
      final current = await save(date.add(const Duration(days: 2)), [hold('hamstring-stretch', 30), hold('pigeon-stretch', 45)]);
      final coach = c.read(coachServiceProvider);
      await coach.convertLegacyPlans();
      expect(await seconds(old), [30, 45, 25, 30]);
      expect(await seconds(current), [30, 45]);

      final later = await save(date.add(const Duration(days: 4)), [hold('hamstring-stretch', 60)]);
      await coach.convertLegacyPlans();
      expect(await seconds(later), [60], reason: 'a longer hold asked for later is kept');
    });

    test('less / more change the sets within the limits; nothing else moves', () async {
      final id = await aiPlan([item('leg-press', sets: 4), item('lying-leg-curl'), item('seated-calf-raise', sets: 2)]);
      final coach = c.read(coachServiceProvider);
      await coach.saveMuscleFocus(MuscleFocus.none
          .withLevel('quads', FocusLevel.less)
          .withLevel('hamstrings', FocusLevel.more)
          .withLevel('calves', FocusLevel.less));
      var items = mainItems(Repository.decodeBlocks((await repo.plannedById(id))!.blocksJson));
      expect(items.map((i) => i.exerciseId), ['leg-press', 'lying-leg-curl', 'seated-calf-raise']);
      expect(items[0].sets, 3);
      expect(items[1].sets, 3, reason: 'isolation cap is 3');
      expect(items[2].sets, 2, reason: 'never below 2');
      // Saving the same focus again must not keep trimming.
      await coach.saveMuscleFocus(MuscleFocus.decode((await repo.getProfile()).muscleFocusJson));
      items = mainItems(Repository.decodeBlocks((await repo.plannedById(id))!.blocksJson));
      expect(items[0].sets, 3);
      expect(jsonDecode((await repo.getProfile()).muscleFocusJson)['less'], ['quads', 'calves']);
    });
  });
}
