import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/workout_countdown.dart';
import 'package:wfit/features/workout/workout_timer.dart';
import 'package:wfit/providers.dart';

import 'helpers.dart';

/// Countdown rules shared with the watch (`watch/fixtures/timers.json` also runs there) and the phone's timer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shared cases', () {
    final cases = jsonDecode(File('../watch/fixtures/timers.json').readAsStringSync()) as List;
    for (final c in cases.cast<Map<String, dynamic>>()) {
      test(c['name'], () {
        var timer = Countdown.fromJson(c['timer'] as Map<String, dynamic>);
        expect(jsonDecode(jsonEncode(timer.toJson())), c['timer'], reason: 'round trip');
        if (c['extend'] != null) timer = timer.extend(c['extend'] as int, c['extendAt'] as int);
        final now = c['now'] as int;
        final running = timer.at(now);
        final expected = c['expect'] as Map<String, dynamic>?;
        if (expected == null) {
          expect(running, isNull);
          return;
        }
        expect(running, isNotNull);
        expect(running!.kind.name, expected['kind']);
        expect(running.phaseAt(now)!.label, expected['label']);
        expect(running.remaining(now), expected['remaining']);
        expect(running.endsAt, expected['endsAt']);
      });
    }
  });

  test('the newest change wins between phone and watch', () {
    final older = Countdown.rest('Rest', 60, from: 1000, owner: CountdownOwner.phone);
    final stopped = Countdown.none(2000, CountdownOwner.watch);
    expect(Countdown.newest(older, stopped), same(stopped));
    expect(Countdown.newest(stopped, older), same(stopped));
    expect(Countdown.newest(null, older), same(older));
  });

  group('phone timer', () {
    late AppDatabase db;
    late ProviderContainer container;
    late String sessionId;
    var now = 0;

    WorkoutTimer timer() => container.read(workoutTimerProvider.notifier);
    Countdown? running() => container.read(workoutTimerProvider);
    Future<List<SetLog>> sets() => container.read(repositoryProvider).setsForSession(sessionId);

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      now = DateTime.utc(2026, 11, 23, 10).millisecondsSinceEpoch;
      db = AppDatabase(NativeDatabase.memory());
      container = ProviderContainer(overrides: [
        catalogProvider.overrideWithValue(loadTestCatalog()),
        databaseProvider.overrideWithValue(db),
        nowMsProvider.overrideWithValue(() => now),
      ]);
      sessionId = await container.read(repositoryProvider).startSession(day: DayType.push, title: 'Push');
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    SetRef hold({int rest = 45}) => SetRef(
        sessionId: sessionId,
        order: 4,
        exerciseId: 'side-plank',
        section: 'core',
        set: 1,
        seconds: 30,
        rest: rest,
        last: false);

    Future<void> run(WidgetTester tester, Future<void> Function() body) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(body);
    }

    testWidgets('one-sided hold runs both sides, logs the set once and starts the rest', (tester) async {
      await run(tester, () async {
        timer().startWork('Side Plank', hold(), perSide: true);
        Future<void> pass(int seconds) async {
          now += seconds * 1000;
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }

        await pass(29);
        expect(running()!.phaseAt(now)!.label, 'Side 1 · Side Plank');
        await pass(2);
        expect(running()!.phaseAt(now)!.label, 'Side 2 · Side Plank');
        expect(await sets(), isEmpty, reason: 'only side 1 is done');
        await pass(30);
        expect(running()!.kind, CountdownKind.rest);
        expect(running()!.remaining(now), 44, reason: 'rest counts from the end of the hold');
        final log = (await sets()).single;
        expect(log.durationSeconds, 30, reason: 'seconds per side');
        expect(log.completed, isTrue);
        expect(log.completedAt!.millisecondsSinceEpoch, now - 1000);
        await pass(60);
        expect(running(), isNull);
        expect(await sets(), hasLength(1));
      });
    });

    testWidgets('skipping a work countdown logs nothing', (tester) async {
      await run(tester, () async {
        timer().startWork('Side Plank', hold(), perSide: true);
        timer().skip();
        now += 120000;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(running(), isNull);
        expect(await sets(), isEmpty);
        expect(timer().register!.kind, CountdownKind.none, reason: 'the watch must hear about it');
      });
    });

    testWidgets('a countdown from the watch is shown here but logged by the watch', (tester) async {
      await run(tester, () async {
        timer().adopt(Countdown.work('Side Plank', hold(), perSide: true, from: now, owner: CountdownOwner.watch));
        expect(running()!.isWork, isTrue);
        now += 61000;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(running()!.kind, CountdownKind.rest);
        expect(await sets(), isEmpty);
      });
    });

    testWidgets('an older or finished countdown from the watch changes nothing', (tester) async {
      await run(tester, () async {
        final stale = Countdown.rest('Rest', 300, from: now - 1000, owner: CountdownOwner.watch);
        timer().start('Rest', 60);
        timer().adopt(stale);
        expect(running()!.remaining(now), 60);
        timer().skip();
        timer().adopt(stale);
        expect(running(), isNull, reason: 'skipped after the watch started it');

        now += 1000;
        timer().adopt(Countdown.rest('Rest', 60, from: now - 1, owner: CountdownOwner.watch));
        expect(running(), isNotNull);
        timer().adopt(Countdown.none(now + 1, CountdownOwner.watch));
        expect(running(), isNull, reason: 'stopped on the watch');
      });
    });

    testWidgets('a phone countdown extended on the watch is still logged when it ended out of reach', (tester) async {
      await run(tester, () async {
        timer().startWork('Plank', hold(), perSide: false);
        now += 1000;
        final extended = running()!.extend(15, now);
        now += 50000; // ended meanwhile (45 s), the phone had no chance to tick
        timer().adopt(extended);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect((await sets()).single.durationSeconds, 30);
        expect(running()!.kind, CountdownKind.rest);
      });
    });
  });
}
