import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/muscles.dart';
import 'package:wfit/providers.dart';

import 'ux_helpers.dart';

/// Settings that save themselves: schedule, about you, injuries, muscle focus, equipment and preferences.
void main() {
  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester, frames: 14);
  }

  Future<void> toTop(WidgetTester tester) async {
    tester.state<ScrollableState>(find.byType(Scrollable).hitTestable().first).position.jumpTo(0);
    await settle(tester, frames: 4);
  }

  Future<(Repository, Future<Profile> Function())> open(WidgetTester tester, String route) async {
    setUpDevice(tester, size: const Size(393, 851));
    final c = await pumpWFit(tester, db: AppDatabase(NativeDatabase.memory()));
    final repo = c.read(repositoryProvider);
    await pumpUntil(tester, () => c.read(coachServiceProvider).ensurePlan(DateTime.now()));
    await go(tester, route);
    return (repo, () => pumpUntil(tester, repo.getProfile));
  }

  List<int> rests(PlannedWorkout p) => [
        for (final b in Repository.decodeBlocks(p.blocksJson).where((b) => b.section == Section.main))
          for (final i in b.items) i.restSeconds,
      ];

  testWidgets('schedule: saved at once, open plans follow once even when days change too', (tester) async {
    final (repo, profile) = await open(tester, '/settings/schedule');
    Future<PlannedWorkout> today() async => (await repo.plannedForDate(DateTime.now()))!;
    final before = rests(await pumpUntil(tester, today));
    await tap(tester, find.text('Short'));
    expect((await profile()).restMode, 'short');
    expect(rests(await pumpUntil(tester, today)), before, reason: 'waits until the taps stop');

    await tap(tester, find.byTooltip('Sunday'));
    expect((await profile()).trainingDays, '1,3,5,7');
    final after = rests(await pumpUntil(tester, today));
    expect([for (final (i, r) in after.indexed) r < before[i]], everyElement(isTrue));

    await go(tester, '/'); // leaving must not scale them again
    expect(rests(await pumpUntil(tester, today)), after);
    await unpumpWFit(tester);
  });

  testWidgets('schedule: the last training day cannot be removed', (tester) async {
    final (_, profile) = await open(tester, '/settings/schedule');
    for (final d in ['Monday', 'Wednesday', 'Friday']) {
      await tap(tester, find.byTooltip(d));
    }
    expect((await profile()).trainingDays, '5');
    await unpumpWFit(tester);
  });

  testWidgets('about you and injuries save while typing and when the page is left', (tester) async {
    final (_, profile) = await open(tester, '/settings/profile');
    await tester.enterText(find.widgetWithText(TextField, 'Height (cm)'), '183');
    await settle(tester, frames: 20);
    expect((await profile()).heightCm, 183);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Sam');
    await go(tester, '/settings/injuries'); // before the typing delay is over
    expect((await profile()).name, 'Sam');

    await tester.enterText(find.byType(TextField), 'Old ankle sprain');
    await go(tester, '/');
    expect((await profile()).injuries, 'Old ankle sprain');
    await unpumpWFit(tester);
  });

  testWidgets('muscle focus: choices of one muscle, kept when the sheet is dragged away', (tester) async {
    final (_, profile) = await open(tester, '/settings/focus');
    await tap(tester, find.text('Chest'));
    await tap(tester, find.text('More'));
    await tap(tester, find.text('Go light'));
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await settle(tester, frames: 30);
    final focus = MuscleFocus.decode((await profile()).muscleFocusJson);
    expect((focus.levelOf('chest'), focus.isLight('chest')), (FocusLevel.more, true));
    await toTop(tester);
    expect(find.text('Changed'), findsOneWidget);
    expect(find.text('More, Go light'), findsOneWidget);
    await unpumpWFit(tester);
  });

  testWidgets('equipment: groups fold, a switch counts, an unknown bar weight is asked for', (tester) async {
    final (repo, _) = await open(tester, '/settings/equipment');
    expect(find.textContaining('Set the bar weight of your smith machine'), findsOneWidget);
    expect(find.text('Dumbbells'), findsNothing);
    await tap(tester, find.text('Free weights'));
    final tile = find.ancestor(of: find.text('Dumbbells'), matching: find.byType(ListTile)).first;
    await tap(tester, find.descendant(of: tile, matching: find.byType(Switch)));
    expect((await pumpUntil(tester, repo.getEquipment))['dumbbells'], isFalse);
    expect(find.textContaining('5 of 6'), findsOneWidget);

    await toTop(tester);
    await tap(tester, find.textContaining('Set the bar weight of your smith machine'));
    await tester.enterText(find.byType(TextField), '15');
    await tap(tester, find.text('Save'));
    expect(find.textContaining('Set the bar weight'), findsNothing);
    expect(tester.takeException(), isNull);
    await unpumpWFit(tester);
  });

  testWidgets('exercises: long press excludes one, the filter finds it again', (tester) async {
    final (repo, _) = await open(tester, '/library');
    await tester.longPress(find.byType(ListTile).first);
    await settle(tester, frames: 14);
    await tap(tester, find.text('Exclude'));
    expect((await pumpUntil(tester, repo.getPreferences)).values, ['banned']);
    await tap(tester, find.text('Liked or excluded'));
    expect(find.byType(ListTile), findsOneWidget);
    await unpumpWFit(tester);
  });
}
