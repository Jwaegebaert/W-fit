import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/api/sync_service.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/rule_engine.dart';
import 'package:wfit/domain/training_load.dart';
import 'package:wfit/providers.dart';

import 'helpers.dart';
import 'ux_helpers.dart';

/// Machines with 2, 4, 6, 8 on the stack: plate numbers for the athlete, real kg for everything else.
void main() {
  final catalog = loadTestCatalog();
  const row = 'seated-cable-row';
  const machine = 'seated_row_machine';

  LoggedSet set(double kg, int reps, {String session = 'a', String exercise = row, bool assisted = false}) => LoggedSet(
      sessionId: session, exerciseId: exercise, date: DateTime(2026, 11, 1), weightKg: kg, reps: reps, assisted: assisted);

  group('labels and progression', () {
    final tuned = catalog.withPlates(const {machine: 7.5, 'assisted_pullup_machine': 7.5});
    final e = tuned.exercise(row)!;

    test('only exercises on the machine change', () {
      expect((e.plateKg, e.incrementKg), (7.5, 7.5));
      expect(tuned.exercise('lat-pulldown')!.plateKg, isNull);
      expect(identical(catalog.withPlates(const {}), catalog), isTrue);
      expect(tuned.exercises.length, catalog.exercises.length);
    });

    test('weights read as plate numbers with the kg behind them', () {
      final loads = LoadModel(catalog, const {}, const {machine: 5});
      expect(loads.weightLabel(catalog.exercise(row), 35), 'plate 7 (35 kg)');
      expect(loads.weightLabel(catalog.exercise('lat-pulldown'), 35), '35 kg');
      expect(loads.totalKg(row, 35), 35, reason: 'stats use the real weight');
      final assist = LoadModel(catalog, const {}, const {'assisted_pullup_machine': 5});
      expect(assist.weightLabel(catalog.exercise('assisted-pull-up'), 25), 'plate 5 (25 kg assist)');
      expect(LoadModel.parsePlates('{"leg_curl": 5, "leg_press": 0}'), {'leg_curl': 5.0});
      expect(LoadModel.parsePlates('nonsense'), isEmpty);
    });

    test('progress goes one plate at a time and says so', () {
      final top = e.repMax!;
      final up = adviseProgression(e, [[for (var i = 0; i < 3; i++) set(45, top)]]);
      expect(up.weightKg, 52.5);
      expect(up.message, contains('add one plate'));
      expect(up.lastSummary, startsWith('plate 6 × '));
      final same = adviseProgression(e, [[for (var i = 0; i < 3; i++) set(45, e.repMin!)]]);
      expect(same.weightKg, 45);
    });

    test('a step back is always at least one plate, and never below the first', () {
      final low = [for (var i = 0; i < 3; i++) set(37.5, e.repMin! - 2)];
      final back = adviseProgression(e, [low, [for (final s in low) set(s.weightKg!, s.reps!, session: 'b')]]);
      expect(back.weightKg, 30, reason: 'plate 5 to 4');
      final deload = adviseProgression(e, [[set(37.5, 10), set(37.5, 10)]], deload: true);
      expect(deload.weightKg, 30);
      expect(deload.message, contains('plate 4'));
      expect(adviseProgression(e, [[set(7.5, 10), set(7.5, 10)]], deload: true).weightKg, 7.5);
    });

    test('on an assisted machine a plate less is harder', () {
      final a = tuned.exercise('assisted-pull-up')!;
      final up = adviseProgression(a, [[for (var i = 0; i < 3; i++) set(30, a.repMax!, exercise: a.id, assisted: true)]]);
      expect(up.weightKg, 22.5);
      expect(up.message, contains('take one plate less assistance'));
      expect(up.lastSummary, startsWith('plate 4 assist'));
      expect(a.snapKg(1), 0);
    });

    test('a weight from before the numbers is rounded to a plate', () {
      expect(adviseProgression(e, [[set(40, e.repMin!), set(40, e.repMin!)]]).weightKg, 37.5);
      expect(formatPlate(40 / 7.5), '5.3');
      expect(formatPlate(7 * 4.54 / 4.54), '7');
    });

    test('plans get whole plates and the coach the plate weight', () {
      final history = {row: [[for (var i = 0; i < 3; i++) set(46, 8)]]};
      final w = RuleEngine(TrainingContext(catalog: tuned, history: history))
          .generate(day: DayType.pull, date: DateTime(2026, 11, 3), sessionMinutes: 120);
      for (final i in w.blocks.expand((b) => b.items).where((i) => i.exerciseId == row)) {
        expect(i.targetWeightKg! % 7.5, 0);
      }
      final brief = exerciseHistoryBrief([set(45, 10)], catalog: tuned, now: DateTime(2026, 11, 2));
      expect(brief.single, containsPair('plateKg', 7.5));
      expect((brief.single['exposures'] as List).single, containsPair('sets', '45x10'));
      expect(exerciseHistoryBrief([set(45, 10)], catalog: catalog, now: DateTime(2026, 11, 2)).single.keys,
          isNot(contains('plateKg')));
    });
  });

  group('settings', () {
    late AppDatabase db;
    late Repository repo;
    late String session;
    late String plan;

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = AppDatabase(NativeDatabase.memory());
      repo = Repository(db, catalog: catalog);
      addTearDown(db.close);
      session = await repo.startSession(day: DayType.pull, title: 'Pull');
      plan = await repo.savePlanned(
        date: DateTime.now().add(const Duration(days: 1)),
        day: DayType.pull,
        title: 'Pull',
        source: 'ai',
        coachNote: '',
        blocks: [
          PlanBlock(section: Section.main, items: [
            PlanItem.fromExercise(catalog.exercise(row)!, targetWeightKg: 37),
            PlanItem.fromExercise(catalog.exercise('lat-pulldown')!, targetWeightKg: 37),
          ]),
        ],
      );
    });

    Future<void> log(int n, double kg, {double? plate, String exercise = row}) => repo.logSet(
        sessionId: session, exerciseId: exercise, section: Section.main, exerciseOrder: exercise == row ? 0 : 1,
        setNumber: n, weightKg: kg, plate: plate, reps: 10, completed: true);
    Future<List<(double?, double?)>> sets() async =>
        [for (final s in await repo.setsForSession(session)) (s.plate, s.weightKg)];
    Future<List<double?>> targets() async => [
          for (final b in Repository.decodeBlocks((await repo.plannedById(plan))!.blocksJson))
            ...b.items.map((i) => i.targetWeightKg),
        ];

    test('kg logged before stay kg; the plan gets whole plates', () async {
      await log(1, 32);
      await log(1, 32, exercise: 'lat-pulldown');
      expect(await repo.countKgSets(machine), 1);
      await repo.setStackPlate(machine, 5);
      expect(await sets(), [(null, 32), (null, 32)]);
      expect(await targets(), [35, 37], reason: 'the lat pulldown is another machine');
      expect((await repo.loadModel())!.plateKg(row), 5);
    });

    test('numbers logged before turn into their weight', () async {
      await log(1, 7);
      await repo.setStackPlate(machine, 5, numbersLogged: true);
      expect(await sets(), [(7, 35)]);
      expect((await targets()).first, 185, reason: 'the plan counted in plates too');
      expect(await repo.countKgSets(machine), 0);
    });

    test('another plate weight keeps the numbers, also in the plan', () async {
      await repo.setStackPlate(machine, 5);
      await log(1, 35, plate: 7);
      await log(2, 32); // kg from before
      await repo.setStackPlate(machine, 6);
      expect(await sets(), [(7, 42), (null, 32)]);
      expect((await targets()).first, 42);
      final stored = (await repo.setsForSession(session)).first;
      expect(stored.dirty, isTrue, reason: 'the correction is synced');
      expect((await repo.loggedSets()).first.weightKg, 42);
    });

    test('back to kg keeps every weight', () async {
      await repo.setStackPlate(machine, 5);
      await log(1, 35, plate: 7);
      await repo.setStackPlate(machine, null);
      expect(await sets(), [(7, 35)]);
      expect((await repo.loadModel())!.plateKg(row), isNull);
      expect((await repo.getProfile()).stackPlatesJson, '{}');
    });

    test('syncs, and a server from before keeps what is here', () async {
      await repo.setStackPlate(machine, 5);
      await log(1, 35, plate: 7);
      final profile = jsonDecode(jsonEncode(profileToJson(await repo.getProfile()))) as Map<String, dynamic>;
      expect(profile['stackPlates'], {machine: 5});
      final logged = setToJson((await repo.setsForSession(session)).single);
      expect(logged['plate'], 7);

      final later = DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String();
      final sync = SyncService(db);
      await sync.applyRemoteChanges({
        'profile': {...profile, 'name': 'Alex', 'updatedAt': later}..remove('stackPlates'),
        'sets': [{...logged, 'reps': 9, 'updatedAt': later}..remove('plate')],
      });
      expect((await repo.getProfile()).name, 'Alex');
      expect(LoadModel.parsePlates((await repo.getProfile()).stackPlatesJson), {machine: 5});
      expect(((await repo.setsForSession(session)).single.reps, (await sets()).single), (9, (7.0, 35.0)));

      final latest = DateTime.now().toUtc().add(const Duration(minutes: 6)).toIso8601String();
      await sync.applyRemoteChanges({
        'profile': {...profile, 'stackPlates': {'leg_curl': 4.5}, 'updatedAt': latest},
      });
      expect(LoadModel.parsePlates((await repo.getProfile()).stackPlatesJson), {'leg_curl': 4.5});
    });
  });

  testWidgets('machines are switched to numbers in the equipment settings', (tester) async {
    setUpDevice(tester, size: const Size(360, 720), textScale: 1.3);
    final c = await pumpWFit(tester, db: AppDatabase(NativeDatabase.memory()));
    await go(tester, '/settings/equipment');
    await tester.tap(find.text('Numbered machines'));
    await settle(tester);
    final name = catalog.equipmentById(machine)!.name;
    final toggle = find.descendant(of: find.widgetWithText(ListTile, name), matching: find.byType(Switch));
    await tester.scrollUntilVisible(toggle, 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(toggle);
    await settle(tester);
    expect(find.text('I logged plate numbers before'), findsNothing, reason: 'nothing logged yet');
    await tester.ensureVisible(find.text('10 lb'));
    await tester.tap(find.text('10 lb'));
    await settle(tester, frames: 5);
    expect(find.text('2 = 9.1 kg · 4 = 18.2 kg · 10 = 45.4 kg'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '5');
    await settle(tester, frames: 5);
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(find.text('2 = 10 kg · 4 = 20 kg · 10 = 50 kg'), findsOneWidget);
    final repo = c.read(repositoryProvider);
    expect(LoadModel.parsePlates((await pumpUntil(tester, repo.getProfile)).stackPlatesJson), {machine: 5});

    await tester.tap(toggle);
    await settle(tester);
    expect((await pumpUntil(tester, repo.getProfile)).stackPlatesJson, '{}');
    await unpumpWFit(tester);
  });
}
