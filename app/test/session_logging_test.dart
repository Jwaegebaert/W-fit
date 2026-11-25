import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/features/workout/section_checklist.dart';
import 'package:wfit/features/workout/session_screen.dart';
import 'package:wfit/providers.dart';
import 'package:wfit/router.dart';

import 'health_service_test.dart' show FakeHealthBridge;
import 'helpers.dart';
import 'ux_helpers.dart';

/// Logging sets in the live workout: what a tick saves, which card opens next, finishing and swapping.
void main() {
  final catalog = loadTestCatalog();
  const press = 'machine-chest-press'; // weighted
  const bench = 'barbell-bench-press'; // bar, two pieces of equipment
  const dip = 'bar-dip'; // optional weight
  final warmup = catalog.exercises.firstWhere((e) => e.category == 'warmup' && e.durationSeconds != null).id;

  Finder card(String id) => find.byWidgetPredicate((w) => w is ExerciseCard && w.item.exerciseId == id);
  Finder fields(String id) => find.descendant(of: card(id), matching: find.byType(TextField));
  Finder tick(String id, int set) => find.descendant(of: card(id), matching: find.byTooltip('Log set $set'));
  String? open(WidgetTester tester) =>
      tester.widgetList<ExerciseCard>(find.byType(ExerciseCard)).where((c) => c.expanded).map((c) => c.item.exerciseId).firstOrNull;
  String text(WidgetTester tester, Finder field) => tester.widget<TextField>(field).controller!.text;

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester, frames: 14);
  }

  Future<void> openCard(WidgetTester tester, String id) async {
    if (open(tester) == id) return;
    await tap(tester, find.descendant(of: card(id), matching: find.byType(InkWell)).first);
  }

  /// Starts a workout with a warm-up, three lifts and returns its id.
  Future<(ProviderContainer, Repository, String)> start(WidgetTester tester) async {
    setUpDevice(tester, size: const Size(393, 851));
    final c = await pumpWFit(tester, db: AppDatabase(NativeDatabase.memory()), health: FakeHealthBridge());
    final repo = c.read(repositoryProvider);
    final id = await pumpUntil(tester, () async {
      PlanItem item(String id) => PlanItem.fromExercise(catalog.exercise(id)!).copyWith(sets: 3);
      final plan = await repo.savePlanned(
        date: DateTime.now(),
        day: DayType.push,
        title: 'Push test',
        source: 'rules',
        coachNote: '',
        blocks: [
          PlanBlock(section: Section.warmup, items: [PlanItem.fromExercise(catalog.exercise(warmup)!)]),
          PlanBlock(section: Section.main, items: [item(press), item(bench), item(dip)]),
        ],
      );
      return repo.startSession(plannedWorkoutId: plan, day: DayType.push, title: 'Push test');
    });
    router.push('/session/$id');
    await settle(tester, frames: 25);
    return (c, repo, id);
  }

  Future<List<SetLog>> logged(WidgetTester tester, Repository repo, String session, String exercise) async =>
      [...await pumpUntil(tester, () => repo.setsForSession(session))]
        ..retainWhere((s) => s.exerciseId == exercise && s.completed)
        ..sort((a, b) => a.setNumber.compareTo(b.setNumber));

  testWidgets('a typed weight goes to the following sets and every tick logs it', (tester) async {
    final (_, repo, session) = await start(tester);
    await openCard(tester, press);
    await tester.enterText(fields(press).at(0), '40');
    expect([for (final i in [0, 2, 4]) text(tester, fields(press).at(i))], ['40', '40', '40']);

    // A set typed by hand is a limit: earlier changes stop there.
    await tester.enterText(fields(press).at(4), '45');
    await tester.enterText(fields(press).at(0), '42.5');
    expect([for (final i in [0, 2, 4]) text(tester, fields(press).at(i))], ['42.5', '42.5', '45']);

    for (var n = 1; n <= 3; n++) {
      await tap(tester, tick(press, n));
    }
    final sets = await logged(tester, repo, session, press);
    expect(sets.map((s) => s.weightKg), [42.5, 42.5, 45]);
    await unpumpWFit(tester);
  });

  testWidgets('a weighted set is not logged without weight; bodyweight sets are', (tester) async {
    final (_, repo, session) = await start(tester);
    await openCard(tester, press);
    await tap(tester, tick(press, 1));
    expect(await logged(tester, repo, session, press), isEmpty);
    expect(find.text('Enter the weight first.'), findsOneWidget);
    expect(tester.widget<TextField>(fields(press).at(0)).focusNode!.hasFocus, isTrue);

    await openCard(tester, bench);
    await tester.enterText(fields(bench).at(0), '0'); // the empty bar
    await tap(tester, tick(bench, 1));
    expect((await logged(tester, repo, session, bench)).single.weightKg, 0);

    await openCard(tester, dip);
    await tap(tester, tick(dip, 1));
    expect((await logged(tester, repo, session, dip)).single.weightKg, isNull);
    await unpumpWFit(tester);
  });

  testWidgets('the reps field and the aim show what a tick logs', (tester) async {
    final (_, repo, session) = await start(tester);
    await openCard(tester, press);
    final hint = tester.widget<TextField>(fields(press).at(1)).decoration!.hintText!;
    expect(find.descendant(of: card(press), matching: find.textContaining('Aim $hint reps')), findsOneWidget);
    await tester.enterText(fields(press).at(0), '40');
    await tap(tester, tick(press, 1));
    expect((await logged(tester, repo, session, press)).single.reps, int.parse(hint));
    await unpumpWFit(tester);
  });

  testWidgets('after a card opened by hand is done, the next unfinished one opens and scrolls into view', (tester) async {
    await start(tester);
    expect(open(tester), press, reason: 'warm-up is a list, not a card');
    await openCard(tester, bench);
    await tester.enterText(fields(bench).at(0), '40');
    for (var n = 1; n <= 3; n++) {
      expect(open(tester), bench);
      await tap(tester, tick(bench, n));
    }
    expect(open(tester), dip, reason: 'the next one below, not the skipped first');
    final rect = tester.getRect(card(dip));
    expect(rect.top, greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom - 0.5));
    expect(rect.bottom, lessThanOrEqualTo(contentLimit(tester)));

    // The last exercise in the list is followed by what was skipped.
    for (var n = 1; n <= 3; n++) {
      await tap(tester, tick(dip, n));
    }
    expect(open(tester), press);
    await unpumpWFit(tester);
  });

  testWidgets('a set added before the last one is ticked keeps the card open', (tester) async {
    await start(tester);
    await openCard(tester, dip);
    await tap(tester, find.descendant(of: card(dip), matching: find.text('Add set')));
    for (var n = 1; n <= 4; n++) {
      expect(open(tester), dip);
      await tap(tester, tick(dip, n));
    }
    expect(open(tester), press);
    await unpumpWFit(tester);
  });

  testWidgets('a finished exercise can be reopened and stays open', (tester) async {
    await start(tester);
    await openCard(tester, dip);
    for (var n = 1; n <= 3; n++) {
      await tap(tester, tick(dip, n));
    }
    await openCard(tester, dip);
    await tester.enterText(fields(dip).at(0), '7');
    await settle(tester);
    expect(open(tester), dip);
    await unpumpWFit(tester);
  });

  testWidgets('numbers typed but not ticked survive scrolling away', (tester) async {
    await start(tester);
    await openCard(tester, press);
    await tester.enterText(fields(press).at(0), '33');
    FocusManager.instance.primaryFocus?.unfocus();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).hitTestable().first).position;
    scroll.jumpTo(scroll.maxScrollExtent);
    await settle(tester, frames: 5);
    scroll.jumpTo(0);
    await settle(tester, frames: 5);
    expect(text(tester, fields(press).at(0)), '33');
    await unpumpWFit(tester);
  });

  testWidgets('finishing names open sets and saves no effort unless one is chosen', (tester) async {
    final (_, repo, session) = await start(tester);
    await tap(tester, find.text('Finish'));
    expect(find.text('No sets are ticked yet.'), findsOneWidget);
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await settle(tester, frames: 10);

    await openCard(tester, dip);
    await tap(tester, tick(dip, 1));
    await tap(tester, find.text('Finish'));
    expect(find.text('8 of 9 sets are not ticked.'), findsOneWidget, reason: 'the warm-up does not count');
    await tap(tester, find.text('Save workout'));
    await settle(tester, frames: 20);
    final saved = (await pumpUntil(tester, () => repo.sessionById(session)))!;
    expect(saved.endedAt, isNotNull);
    expect((saved.rating, saved.perceivedEffort), (null, null));
    await unpumpWFit(tester);
  });

  testWidgets('a chosen effort is saved on the 1-10 scale', (tester) async {
    final (_, repo, session) = await start(tester);
    await tap(tester, find.text('Finish'));
    await tap(tester, find.text('Very hard'));
    await tap(tester, find.text('Save workout'));
    await settle(tester, frames: 20);
    expect((await pumpUntil(tester, () => repo.sessionById(session)))!.perceivedEffort, 9);
    await unpumpWFit(tester);
  });

  testWidgets('swap: nothing lasting happens unless it is chosen', (tester) async {
    final (_, repo, _) = await start(tester);
    bool selected(String label) => tester.widget<FilterChip>(find.widgetWithText(FilterChip, label)).selected;
    await openCard(tester, bench);
    await tap(tester, find.descendant(of: card(bench), matching: find.byTooltip('Swap exercise')));
    expect((selected('Barbell & plates'), selected('Flat bench')), (true, true));
    await tap(tester, find.text('Not in my gym'));
    expect((selected('Barbell & plates'), selected('Flat bench')), (false, false));

    await tap(tester, find.text('Prefer another'));
    final suggestion = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Card)).first;
    await tap(tester, suggestion);
    expect(await pumpUntil(tester, () => repo.getPreferences()), isEmpty);
    expect((await pumpUntil(tester, () => repo.getEquipment())).values.where((v) => !v), isEmpty);
    expect(card(bench), findsNothing);
    await unpumpWFit(tester);
  });

  testWidgets('warm-up lines are ticked off one by one or all at once', (tester) async {
    final (_, repo, session) = await start(tester);
    final list = find.byType(SectionChecklist);
    final name = catalog.exercise(warmup)!.name;
    await tap(tester, find.descendant(of: list, matching: find.byTooltip('Done: $name')));
    final sets = await logged(tester, repo, session, warmup);
    expect(sets, hasLength(catalog.exercise(warmup)!.sets));
    expect(sets.first.durationSeconds, catalog.exercise(warmup)!.durationSeconds);
    expect(open(tester), press, reason: 'the open card stays');

    await tap(tester, find.descendant(of: list, matching: find.byTooltip('Undo $name')));
    expect(await logged(tester, repo, session, warmup), isEmpty);
    await tap(tester, find.text('All done'));
    expect(await logged(tester, repo, session, warmup), hasLength(sets.length));
    expect(find.text('All done'), findsNothing);
    await unpumpWFit(tester);
  });

  testWidgets('a numbered machine is logged by plate number and stored with its weight', (tester) async {
    final (_, repo, session) = await start(tester);
    Future<void> setPlate(double? kg, {bool numbersLogged = false}) async {
      await pumpUntil(tester, () async {
        await repo.setStackPlate('chest_press_machine', kg, numbersLogged: numbersLogged);
        return 1;
      });
      await settle(tester);
    }

    await openCard(tester, press);
    expect(find.descendant(of: card(press), matching: find.byIcon(Icons.remove_rounded)), findsNothing);
    await tester.enterText(fields(press).at(0), '40');
    await setPlate(5); // during the workout: what is typed becomes a plate number
    expect(find.text('Plate (5 kg each)'), findsOneWidget);
    expect([for (final i in [0, 2, 4]) text(tester, fields(press).at(i))], ['8', '8', '8']);

    await tester.enterText(fields(press).at(0), '7');
    await tap(tester, tick(press, 1));
    var set = (await logged(tester, repo, session, press)).single;
    expect((set.plate, set.weightKg), (7, 35));

    await setPlate(6); // the plates turn out heavier: same number, other weight
    expect([for (final i in [0, 2]) text(tester, fields(press).at(i))], ['7', '7']);
    set = (await logged(tester, repo, session, press)).single;
    expect((set.plate, set.weightKg), (7, 42));
    await tap(tester, tick(press, 2));
    expect((await logged(tester, repo, session, press)).last.weightKg, 42);

    await setPlate(null);
    expect([for (final i in [0, 2, 4]) text(tester, fields(press).at(i))], ['42', '42', '42']);
    await unpumpWFit(tester);
  });

  testWidgets('a logged set can be corrected later', (tester) async {
    final (_, repo, session) = await start(tester);
    await openCard(tester, dip);
    await tap(tester, tick(dip, 1));
    await pumpUntil(tester, () async {
      await repo.finishSession(session);
      return 1;
    });
    router.go('/');
    router.push('/history/$session');
    await settle(tester, frames: 25);
    await tap(tester, find.text(catalog.exerciseName(dip)));
    await tester.enterText(find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField)).last, '4');
    await tap(tester, find.text('Save'));
    expect((await logged(tester, repo, session, dip)).single.reps, 4);
    await tap(tester, find.text(catalog.exerciseName(dip)));
    await tap(tester, find.byTooltip('Remove set 1'));
    await tap(tester, find.text('Save and remove 1'));
    expect(await logged(tester, repo, session, dip), isEmpty);
    await unpumpWFit(tester);
  });

  testWidgets('an exercise removed from the plan can be brought back', (tester) async {
    final (_, repo, session) = await start(tester);
    await pumpUntil(tester, () async {
      await repo.discardSession(session);
      return 1;
    });
    final plan = await pumpUntil(tester, () async => (await repo.plannedForDate(DateTime.now()))!);
    int count() => Repository.decodeBlocks(plan.blocksJson).expand((b) => b.items).length;
    Future<int> stored() async => Repository.decodeBlocks((await repo.plannedById(plan.id))!.blocksJson).expand((b) => b.items).length;
    router.go('/');
    router.push('/plan/${plan.id}');
    await settle(tester, frames: 25);
    await tap(tester, find.descendant(of: find.byType(ListTile), matching: find.byTooltip('Show menu')).last);
    await tap(tester, find.text('Remove from today'));
    expect(await pumpUntil(tester, stored), count() - 1);
    await tap(tester, find.text('Undo'));
    expect(await pumpUntil(tester, stored), count());

    // Switching the day asks first.
    await tap(tester, find.descendant(of: find.byType(AppBar), matching: find.byTooltip('Show menu')));
    await tap(tester, find.text('Switch to Legs day'));
    expect(find.text('Switch to Legs day?'), findsOneWidget);
    await tap(tester, find.text('Keep plan'));
    expect((await pumpUntil(tester, () => repo.plannedById(plan.id)))!.dayType, 'push');
    await unpumpWFit(tester);
  });

  group('advice when the plan sets its own weight', () {
    const advice = ProgressionAdvice(weightKg: 25, targetReps: 11, message: 'Same weight – aim for one more rep.', lastSummary: 'x');

    test('same or no plan weight keeps the advice', () {
      expect(identical(advice.forPlanWeight(25, repMin: 8, assisted: false), advice), isTrue);
      expect(identical(advice.forPlanWeight(null, repMin: 8, assisted: false), advice), isTrue);
    });

    test('heavier and lighter aim for the bottom of the range and say so', () {
      final up = advice.forPlanWeight(27.5, repMin: 8, assisted: false);
      expect((up.weightKg, up.targetReps, up.lastSummary), (27.5, 8, 'x'));
      expect(up.message, startsWith('A step up'));
      expect(advice.forPlanWeight(22.5, repMin: 8, assisted: false).message, startsWith('Lighter today'));
    });

    test('less help on an assisted machine is the step up', () {
      expect(advice.forPlanWeight(20, repMin: 8, assisted: true).message, startsWith('A step up'));
      expect(advice.forPlanWeight(30, repMin: 8, assisted: true).message, startsWith('Lighter today'));
    });
  });
}
