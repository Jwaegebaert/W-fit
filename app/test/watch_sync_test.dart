import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/watch_protocol.dart';
import 'package:wfit/domain/workout_countdown.dart';
import 'package:wfit/features/watch/watch_bridge.dart';
import 'package:wfit/features/watch/watch_sync.dart';
import 'package:wfit/features/workout/set_logger.dart';
import 'package:wfit/features/workout/workout_timer.dart';
import 'package:wfit/providers.dart';

import 'helpers.dart';

/// Stand-in for the Wearable Data Layer: records what the phone publishes and delivers messages from the watch.
class FakeWatchBridge extends WatchBridge {
  FakeWatchBridge({this.isAvailable = true, this.waiting = const []});

  final bool isAvailable;
  List<String> waiting;
  final published = <Map<String, dynamic>>[];
  void Function(String json)? deliver;
  int opened = 0;

  @override
  Future<bool> available() async => isAvailable;
  @override
  Future<void> publish(String json) async => published.add(jsonDecode(json) as Map<String, dynamic>);
  @override
  Future<List<String>> pending() async => waiting;
  @override
  Future<void> openOnWatch() async => opened++;
  @override
  void listen(void Function(String json) onMessage) => deliver = onMessage;

  Map<String, dynamic> get last => published.last;
  Map<String, dynamic> exercise(int order) => (last['exercises'] as List)[order] as Map<String, dynamic>;
}

const _fixtures = '../watch/fixtures';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final catalog = loadTestCatalog();

  PlanItem item(String id, {double? weight}) => PlanItem.fromExercise(catalog.exercise(id)!, targetWeightKg: weight);

  group('messages shared with the watch app', () {
    WatchExercise exercise(int order, Section section, PlanItem item,
            {ProgressionAdvice? advice, List<WatchSet> logged = const []}) =>
        WatchExercise.from(
          order: order,
          item: item,
          section: section,
          exercise: catalog.exercise(item.exerciseId),
          loads: LoadModel(catalog, const {}, const {'seated_row_machine': 5}),
          advice: advice,
          logged: logged,
        );

    test('snapshot matches watch/fixtures/snapshot.json', () {
      final snapshot = WatchSnapshot(
        sessionId: 's1',
        title: 'Push B',
        startedAt: 1700000000000,
        current: 1,
        acked: const ['e1'],
        timer: Countdown.rest('Rest', 120, from: 1700000100000, owner: CountdownOwner.phone),
        exercises: [
          exercise(0, Section.warmup, item('band-external-rotation')),
          exercise(1, Section.main, item('barbell-bench-press', weight: 40),
              advice: const ProgressionAdvice(weightKg: 42.5, targetReps: 7, message: ''),
              logged: const [WatchSet(set: 1, weight: 40, reps: 8, at: 1700000100000)]),
          exercise(2, Section.main, item('assisted-dip'),
              advice: const ProgressionAdvice(weightKg: 25, targetReps: 9, message: '')),
          exercise(3, Section.main, item('bar-dip')),
          exercise(4, Section.core, item('side-plank')),
          exercise(5, Section.main, item('seated-cable-row', weight: 35),
              advice: const ProgressionAdvice(weightKg: 35, targetReps: 9, message: ''),
              logged: const [WatchSet(set: 1, weight: 6, reps: 12, at: 1700000090000)]),
        ],
      );
      final file = File('$_fixtures/snapshot.json');
      expect(jsonDecode(snapshot.encode()), jsonDecode(file.readAsStringSync()));
    });

    test('labels follow the rules of the exercise card', () {
      final bench = exercise(0, Section.main, item('barbell-bench-press', weight: 40));
      expect(bench.weightLabel, 'Plates kg');
      expect(bench.weightText, '40 kg plates (+20 bar)');
      final assisted = exercise(0, Section.main, item('assisted-dip', weight: 25));
      expect(assisted.weightLabel, 'Assist kg');
      expect(assisted.weightText, '25 kg assist');
      expect(assisted.step, 5);
      final dip = exercise(0, Section.main, item('bar-dip'));
      expect(dip.weightLabel, 'Extra kg');
      expect(dip.weight, isNull);
      expect(dip.step, 2.5);
      expect((bench.needsWeight, assisted.needsWeight, dip.needsWeight), (true, true, false));
      expect(exercise(0, Section.warmup, item('barbell-bench-press')).needsWeight, isFalse);
      final warmup = exercise(0, Section.warmup, item('band-external-rotation'));
      expect(warmup.weightLabel, isNull, reason: 'load type none');
      expect(warmup.perSide, isTrue);
      expect(warmup.target, contains('/ side'));
      expect((warmup.checklist, warmup.rest, warmup.targetReps), (true, 0, 15), reason: 'ticked off without rest');
      expect((bench.checklist, bench.rest), (false, 120));
      final plank = exercise(0, Section.core, item('side-plank', weight: 10));
      expect(plank.weight, isNull, reason: 'timed holds have no weight');
      expect(plank.seconds, 25);
      expect(plank.targetReps, isNull);
    });

    test('every message in watch/fixtures/events.json is understood', () {
      final messages = jsonDecode(File('$_fixtures/events.json').readAsStringSync()) as List;
      final parsed = [for (final m in messages) parseWatchMessage(jsonEncode(m))];
      expect(parsed, everyElement(isNotNull));
      final log = parsed[0] as WatchEvent;
      expect((log.isLog, log.order, log.set, log.weight, log.reps), (true, 1, 2, 42.5, 7));
      expect((parsed[1] as WatchEvent).seconds, 25);
      expect((parsed[2] as WatchEvent).isLog, isFalse);
      expect((parsed[3] as Countdown).kind, CountdownKind.rest);
      expect((parsed[4] as Countdown).kind, CountdownKind.none);
      final stretch = parsed[5] as Countdown;
      expect((stretch.set!.count, stretch.phases[1].pause, stretch.phases[2].pause), (2, true, false));
    });

    test('damaged and unknown messages are ignored', () {
      expect(parseWatchMessage('nonsense'), isNull);
      expect(parseWatchMessage('{}'), isNull);
      expect(parseWatchMessage('{"v":2,"type":"log"}'), isNull);
      expect(parseWatchMessage('{"v":1,"type":"log","id":"x"}'), isNull);
    });
  });

  group('sync', () {
    late AppDatabase db;
    late ProviderContainer container;
    late FakeWatchBridge bridge;
    late String sessionId;
    late String planId;

    Repository repo() => container.read(repositoryProvider);
    Future<List<SetLog>> sets() => repo().setsForSession(sessionId);
    /// Waits until the phone has nothing new to tell the watch.
    Future<void> settle() async {
      var quiet = 0;
      var seen = bridge.published.length;
      while (quiet < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        quiet = bridge.published.length == seen ? quiet + 1 : 0;
        seen = bridge.published.length;
      }
    }

    String event({
      String id = 'e1',
      String type = 'log',
      DateTime? at,
      int order = 0,
      String exerciseId = 'barbell-bench-press',
      String section = 'main',
      int set = 1,
      double? weight = 42.5,
      int? reps = 7,
      int? seconds,
      String? session,
    }) =>
        jsonEncode({
          'v': 1, 'type': type, 'id': id, 'at': (at ?? DateTime.now()).millisecondsSinceEpoch,
          'sessionId': session ?? sessionId, 'order': order, 'exerciseId': exerciseId, 'section': section, 'set': set,
          'weight': weight, 'reps': reps, 'seconds': seconds, //
        });

    Future<void> receive(String json) async {
      await container.read(watchSyncProvider).receive(json);
      await settle();
    }

    Future<void> start(FakeWatchBridge b) async {
      bridge = b;
      container = ProviderContainer(overrides: [
        catalogProvider.overrideWithValue(catalog),
        databaseProvider.overrideWithValue(db),
        watchBridgeProvider.overrideWithValue(b),
      ]);
      await container.read(watchSyncProvider).start();
      await settle();
    }

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = AppDatabase(NativeDatabase.memory());
      final r = Repository(db);
      planId = await r.savePlanned(
        date: DateTime.now(),
        day: DayType.push,
        title: 'Push B',
        source: 'rules',
        coachNote: '',
        blocks: [
          PlanBlock(section: Section.main, items: [item('barbell-bench-press', weight: 40), item('bar-dip')]),
          PlanBlock(section: Section.core, items: [item('side-plank')]),
        ],
      );
      sessionId = await r.startSession(plannedWorkoutId: planId, day: DayType.push, title: 'Push B');
      await start(FakeWatchBridge());
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('publishes the active session and every set logged on the phone', () async {
      expect(bridge.last['sessionId'], sessionId);
      expect(bridge.exercise(0)['weightText'], '40 kg plates (+20 bar)');
      expect(bridge.exercise(2)['sectionLabel'], 'Core');

      final before = bridge.published.length;
      await repo().logSet(
          sessionId: sessionId,
          exerciseId: 'barbell-bench-press',
          section: Section.main,
          exerciseOrder: 0,
          setNumber: 1,
          weightKg: 40,
          reps: 8,
          completed: true);
      await settle();
      expect((bridge.exercise(0)['logged'] as List).single, containsPair('reps', 8));
      expect(bridge.published.length, before + 1, reason: 'one change, one message');
    });

    test('a set logged on the watch is stored with its own time, once', () async {
      final at = DateTime.now().subtract(const Duration(minutes: 10));
      await receive(event(at: at));
      await receive(event(at: at)); // delivered twice
      final log = (await sets()).single;
      expect((log.weightKg, log.reps, log.completed, log.dirty), (42.5, 7, true, true));
      expect(log.completedAt!.difference(at).inSeconds.abs(), lessThan(1));
      expect(bridge.last['acked'], ['e1']);
      expect((bridge.exercise(0)['logged'] as List).single, containsPair('weight', 42.5));
      expect(container.read(watchSetProvider)!.reps, 7);
      expect(container.read(workoutTimerProvider), isNull, reason: 'the watch sends its own rest countdown');
    });

    test('two events for one set at the same moment still make one row', () async {
      final sync = container.read(watchSyncProvider);
      await Future.wait([sync.receive(event(id: 'a')), sync.receive(event(id: 'b', reps: 9))]);
      expect((await sets()).single.reps, 9);
    });

    test('a newer entry on the phone wins from an older one on the watch, and the other way round', () async {
      await receive(event(reps: 6));
      await repo().logSet(
          id: (await sets()).single.id,
          sessionId: sessionId,
          exerciseId: 'barbell-bench-press',
          section: Section.main,
          exerciseOrder: 0,
          setNumber: 1,
          weightKg: 45,
          reps: 5,
          completed: true);
      await receive(event(id: 'late', at: DateTime.now().subtract(const Duration(minutes: 1)), reps: 10));
      expect((await sets()).single.reps, 5);
      expect(bridge.last['acked'], contains('late'), reason: 'handled, so the watch stops sending it');
      await receive(event(id: 'newer', at: DateTime.now().add(const Duration(seconds: 2)), reps: 10));
      expect((await sets()).single.reps, 10);
    });

    test('undo on the watch un-logs the set and keeps its numbers', () async {
      await receive(event());
      await receive(event(id: 'e2', type: 'unlog', weight: null, reps: null, at: DateTime.now()));
      final log = (await sets()).single;
      expect((log.completed, log.weightKg, log.reps), (false, 42.5, 7));
      expect(bridge.exercise(0)['logged'], isEmpty);
    });

    test('an undo that arrives before the set it undoes still wins', () async {
      final at = DateTime.now().subtract(const Duration(seconds: 10));
      await receive(event(id: 'undo', type: 'unlog', weight: null, reps: null, at: at.add(const Duration(seconds: 3))));
      await receive(event(id: 'log', at: at));
      expect((await sets()).where((s) => s.completed), isEmpty);
      expect(bridge.exercise(0)['logged'], isEmpty);
    });

    test('bodyweight exercises never get "0 kg", holds store seconds per side', () async {
      await receive(event(id: 'a', order: 1, exerciseId: 'bar-dip', weight: 0));
      await receive(event(
          id: 'b', order: 2, exerciseId: 'side-plank', section: 'core', weight: null, reps: null, seconds: 25));
      final logs = await sets();
      expect(logs.first.weightKg, isNull);
      expect((logs.last.durationSeconds, logs.last.section), (25, 'core'));
    });

    test('on a numbered stack the watch works with plate numbers, the phone stores the weight', () async {
      await repo().setStackPlate('seated_row_machine', 4.5);
      await repo().updatePlannedBlocks(planId, [
        PlanBlock(section: Section.main, items: [item('seated-cable-row', weight: 31.5)]),
      ]);
      await settle();
      expect(bridge.exercise(0), allOf(containsPair('numbered', true), containsPair('weight', 7), containsPair('step', 1)));
      expect(bridge.exercise(0)['weightText'], 'plate 7 (31.5 kg)');
      await receive(event(exerciseId: 'seated-cable-row', weight: 8));
      final log = (await sets()).single;
      expect((log.plate, log.weightKg), (8, 36));
      expect((bridge.exercise(0)['logged'] as List).single, containsPair('weight', 8));
      await receive(event(id: 'e2', type: 'unlog', exerciseId: 'seated-cable-row', weight: null, reps: null));
      expect(((await sets()).single.plate, (await sets()).single.weightKg), (8, 36), reason: 'undo keeps the numbers');
    });

    test('a late set is added to a finished workout and dropped from a discarded one', () async {
      await repo().finishSession(sessionId);
      await settle();
      expect(bridge.last['sessionId'], isNull);
      await receive(event());
      expect(await sets(), hasLength(1));

      final other = await repo().startSession(plannedWorkoutId: planId, day: DayType.push, title: 'Push B');
      await repo().discardSession(other);
      await receive(event(id: 'gone', session: other));
      expect(await repo().setsForSession(other), isEmpty);
      expect(bridge.last['acked'], contains('gone'));
    });

    test('a damaged message does not block the next one', () async {
      await receive('{"v":1,"type":"timer","timer":{"kind":"rest"}}');
      await receive(event());
      expect(await sets(), hasLength(1));
    });

    test('countdowns go both ways', () async {
      container.read(workoutTimerProvider.notifier).start('Rest', 90);
      await settle();
      expect((bridge.last['timer'] as Map)['kind'], 'rest');
      final stop = Countdown.none(DateTime.now().millisecondsSinceEpoch + 1, CountdownOwner.watch);
      await receive(jsonEncode({'v': 1, 'type': 'timer', 'timer': stop.toJson()}));
      expect(container.read(workoutTimerProvider), isNull);
      expect((bridge.last['timer'] as Map)['kind'], 'none');
    });

    test('an exercise opened on the phone is the current one on the watch', () async {
      container.read(openExerciseProvider.notifier).open(sessionId, 2);
      await settle();
      expect(bridge.last['current'], 2);
      container.read(openExerciseProvider.notifier).open('another session', 1);
      await settle();
      expect(bridge.last['current'], isNull);
    });

    test('a swap on the phone reaches the watch', () async {
      await repo().updatePlannedBlocks(planId, [
        PlanBlock(section: Section.main, items: [item('assisted-dip', weight: 25)]),
      ]);
      await settle();
      expect((bridge.last['exercises'] as List), hasLength(1));
      expect(bridge.exercise(0)['weightLabel'], 'Assist kg');
    });

    test('sets logged while the app was closed are picked up at start', () async {
      container.dispose();
      await start(FakeWatchBridge(waiting: [event(id: 'x', set: 1), event(id: 'y', set: 2)]));
      expect(await sets(), hasLength(2));
      expect(bridge.last['acked'], ['x', 'y']);
    });

    test('a workout forgotten for a day is not shown', () async {
      container.dispose();
      await (db.update(db.workoutSessions)).write(
          WorkoutSessionsCompanion(startedAt: Value(DateTime.now().toUtc().subtract(const Duration(hours: 20)))));
      await start(FakeWatchBridge());
      expect(bridge.last['sessionId'], isNull);
    });

    test('without a watch nothing is published', () async {
      container.dispose();
      await start(FakeWatchBridge(isAvailable: false));
      expect(bridge.published, isEmpty);
      expect(bridge.deliver, isNull);
    });

    test('the phone logger starts the rest of the set', () async {
      await container.read(setLoggerProvider).log(
            SetRef(
                sessionId: sessionId,
                order: 0,
                exerciseId: 'barbell-bench-press',
                section: 'main',
                set: 3,
                seconds: 0,
                rest: 120,
                last: true),
            weightKg: 40,
            reps: 8,
          );
      final timer = container.read(workoutTimerProvider)!;
      expect(timer.phases.single.label, Countdown.restNextLabel);
      expect(timer.phases.single.seconds, 120);
    });
  });
}
