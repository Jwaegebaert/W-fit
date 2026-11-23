import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/api/api_client.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/providers.dart';

import 'helpers.dart';

/// Configured API whose every call fails like a phone without connection.
class OfflineApi extends ApiClient {
  OfflineApi() : super(const ApiConfig(baseUrl: 'https://fake.test', apiKey: 'key'));

  int calls = 0;

  @override
  Future<Map<String, dynamic>> post(String path, Object body, {Duration timeout = const Duration(seconds: 60)}) async {
    calls++;
    throw ApiException('offline', 'No connection to the W-fit server.');
  }
}

ProviderContainer _container({ApiClient? api}) {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final db = AppDatabase(NativeDatabase.memory());
  final c = ProviderContainer(overrides: [
    catalogProvider.overrideWithValue(loadTestCatalog()),
    databaseProvider.overrideWithValue(db),
    apiClientProvider.overrideWithValue(api ?? ApiClient(ApiConfig.empty)),
  ]);
  addTearDown(() async {
    // Let fire-and-forget sync status refreshes finish before the database goes away.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    c.dispose();
    await db.close();
  });
  return c;
}

/// Completes [count] rule-engine plans (Push → Pull → Legs, every other day, all sets logged with RIR 2).
Future<void> _seedSessions(ProviderContainer c, int count) async {
  final repo = c.read(repositoryProvider);
  final coach = c.read(coachServiceProvider);
  final db = c.read(databaseProvider);
  var day = DayType.push;
  for (var i = 0; i < count; i++) {
    final date = DateTime.now().subtract(Duration(days: (count - i) * 2 + 1));
    final pid = await coach.generateWithRules(date, day: day);
    final plan = (await repo.plannedById(pid))!;
    final sid = await repo.startSession(plannedWorkoutId: pid, day: day, title: plan.title);
    var order = 0;
    for (final b in Repository.decodeBlocks(plan.blocksJson)) {
      for (final item in b.items) {
        for (var n = 1; n <= item.sets; n++) {
          await repo.logSet(
            sessionId: sid,
            exerciseId: item.exerciseId,
            section: b.section,
            exerciseOrder: order,
            setNumber: n,
            weightKg: item.isTimed ? null : item.targetWeightKg ?? 20,
            reps: item.isTimed ? null : item.repMax ?? 10,
            durationSeconds: item.isTimed ? item.durationSeconds : null,
            rir: 2,
            completed: true,
          );
        }
        order++;
      }
    }
    await repo.finishSession(sid, rating: 4, effort: 7, notes: 'Session $i went well');
    final start = DateTime(date.year, date.month, date.day, 18).toUtc();
    await (db.update(db.workoutSessions)..where((t) => t.id.equals(sid))).write(WorkoutSessionsCompanion(
      startedAt: Value(start),
      endedAt: Value(start.add(const Duration(minutes: 60))),
      durationSeconds: const Value(3600),
    ));
    day = day.next;
  }
}

void main() {
  test('coach brief has the documented shape, list limits and stays well below 40 KB', () async {
    final c = _container();
    await _seedSessions(c, 24);
    final repo = c.read(repositoryProvider);
    await repo.addFeedback(kind: 'pain', region: 'neck', severity: 2, note: 'Stiff neck');
    await repo.addFeedback(kind: 'too_hard', exerciseId: 'leg-press', note: 'Heavy');
    await repo.saveBodyMetric(BodyMetricsCompanion(date: Value(dateKey(DateTime.now())), weightKg: const Value(78.5)));

    final coach = c.read(coachServiceProvider);
    final snap = await coach.snapshot(day: DayType.push);
    final brief = coach.buildBrief(snap, day: DayType.push, occupied: {'cable_machine'});

    expect(brief.keys, containsAll(['today', 'profile', 'equipment', 'preferences', 'limitations', 'exerciseFeedback',
      'program', 'balance', 'exerciseHistory', 'recentSessions', 'weekly']));
    expect(brief['today'], dateKey(DateTime.now()));
    expect((brief['profile'] as Map)['bodyweightKg'], 78.5);
    expect((brief['equipment'] as Map)['occupied'], ['cable_machine']);
    expect(((brief['limitations'] as List).single as Map)['region'], 'neck');
    expect(((brief['exerciseFeedback'] as List).single as Map)['kind'], 'too_hard');
    expect((brief['program'] as Map)['completedSessions'], 24);
    expect((brief['balance'] as Map)['muscles'], isNotEmpty);
    expect((brief['recentSessions'] as List).length, 9);
    expect(((brief['recentSessions'] as List).first as Map)['exercises'], isNotEmpty);
    expect((brief['weekly'] as List).length, 8);
    final history = (brief['exerciseHistory'] as List).cast<Map<String, dynamic>>();
    expect(history.length, inInclusiveRange(1, 25));
    expect(history.every((h) => (h['exposures'] as List).length <= 4), isTrue);
    expect(snap.sets.any((s) => s.rir == 2 && s.section == 'main'), isTrue);

    final bytes = utf8.encode(jsonEncode(brief)).length;
    expect(bytes, lessThan(40 * 1024), reason: 'brief is $bytes bytes');
  });

  test('moderate neck pain removes neck-loading exercises from open plans and records the changes', () async {
    final c = _container();
    final repo = c.read(repositoryProvider);
    final catalog = c.read(catalogProvider);
    final coach = c.read(coachServiceProvider);
    final blocks = [
      PlanBlock(section: Section.main, items: [
        for (final id in ['barbell-back-squat', 'smith-squat', 'leg-press']) PlanItem.fromExercise(catalog.exercise(id)!),
      ]),
    ];
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final pid = await repo.savePlanned(
        date: tomorrow, day: DayType.legs, title: 'Legs A', source: 'rules', coachNote: '', blocks: blocks,
        metaJson: '{"program":"Block 1 · Week 1 · Legs A","variant":"A"}');
    final pastId = await repo.savePlanned(
        date: DateTime.now().subtract(const Duration(days: 3)), day: DayType.legs, title: 'Old', source: 'rules',
        coachNote: '', blocks: blocks);

    final out = await coach.reportIssue(kind: 'pain', region: 'neck', severity: 2);

    expect(out.coachReply, isNull, reason: 'AI not configured');
    expect(out.changes.map((ch) => ch.from), containsAll(['barbell-back-squat', 'smith-squat']));
    final plan = (await repo.plannedById(pid))!;
    final ids = Repository.decodeBlocks(plan.blocksJson).expand((b) => b.items).map((i) => i.exerciseId).toList();
    expect(ids, contains('leg-press'));
    for (final id in ids) {
      expect(catalog.exercise(id)!.stress, isNot(contains('neck')), reason: id);
    }
    final meta = PlanMeta.decode(plan.metaJson);
    expect(meta.program, 'Block 1 · Week 1 · Legs A');
    expect(meta.changes.map((ch) => ch.from), containsAll(['barbell-back-squat', 'smith-squat']));
    expect(plan.dirty, isTrue);
    expect(Repository.decodeBlocks((await repo.plannedById(pastId))!.blocksJson).first.items.first.exerciseId,
        'barbell-back-squat', reason: 'past plans are history');
    final entry = (await repo.activeFeedback()).single;
    expect((entry.kind, entry.region, entry.severity), ('pain', 'neck', 2));
    expect(entry.note, isNotEmpty);
  });

  test('equipment and preference reports update the gym and preferences', () async {
    final c = _container();
    final repo = c.read(repositoryProvider);
    final coach = c.read(coachServiceProvider);
    await coach.reportIssue(kind: 'unavailable', exerciseId: 'leg-press', equipmentId: 'leg_press');
    await coach.reportIssue(kind: 'dislike', exerciseId: 'smith-squat');
    expect((await repo.getEquipment())['leg_press'], isFalse);
    expect((await repo.getPreferences())['smith-squat'], 'disliked');
    expect(await repo.feedbackForExercise('leg-press'), hasLength(1));
  });

  test('pre-generation keeps the rules plan and never throws offline', () async {
    final api = OfflineApi();
    final c = _container(api: api);
    final coach = c.read(coachServiceProvider);

    await coach.pregenerateNext();

    final plan = await c.read(repositoryProvider).plannedForDate(await coach.nextTrainingDate());
    expect(plan, isNotNull);
    expect(plan!.source, 'rules');
    expect(PlanMeta.decode(plan.metaJson).program, isNotEmpty);
    expect(api.calls, 1);
    expect(c.read(coachPreparingProvider), isNull);
    await coach.pregenerateNext();
    expect(api.calls, 1, reason: 'one AI attempt per date');
  });

  group('coach changes stick', () {
    test('a coach-changed plan that was not trained moves to the next training day', () async {
      final c = _container();
      final coach = c.read(coachServiceProvider);
      final repo = c.read(repositoryProvider);
      final missedDay = DateTime.now().subtract(const Duration(days: 1));
      final today = DateTime.now();
      final id = await coach.generateWithRules(missedDay, day: DayType.push);
      final original = (await repo.plannedById(id))!;
      // The coach adjusted it (as /ai/adjust does) – then the athlete skipped that day.
      await repo.savePlanned(
        id: id,
        date: missedDay,
        day: DayType.push,
        title: 'Coach plan',
        source: 'ai',
        coachNote: 'Lighter shoulders as you asked.',
        blocks: Repository.decodeBlocks(original.blocksJson),
      );

      final next = await coach.ensurePlan(today);
      expect(next.id, id, reason: 'the coach-changed plan is kept, not replaced by a fresh rules plan');
      expect(next.title, 'Coach plan');
      expect(next.date, dateKey(today));
      expect(PlanMeta.decode(next.metaJson).rationale.first, startsWith('Moved from'));
      expect(await repo.plannedForDate(missedDay), isNull);
    });

    test('a missed plan of another day type is not carried over', () async {
      final c = _container();
      final coach = c.read(coachServiceProvider);
      final missedDay = DateTime.now().subtract(const Duration(days: 1));
      final id = await coach.generateWithRules(missedDay, day: DayType.legs); // rotation says push next
      final next = await coach.ensurePlan(DateTime.now());
      expect(next.id, isNot(id));
      expect(next.dayType, 'push');
    });

    test('a background AI refinement never overwrites a newer change to the same plan', () async {
      final api = _GatedApi();
      final c = _container(api: api);
      final coach = c.read(coachServiceProvider);
      final repo = c.read(repositoryProvider);
      final date = DateTime.now().add(const Duration(days: 1));
      final id = await coach.generateWithRules(date, day: DayType.push);
      final plan = (await repo.plannedById(id))!;
      api.blocks = jsonDecode(plan.blocksJson) as List;

      final refining = coach.generateWithAi(date, day: DayType.push, replaceId: id);
      await api.started.future;
      // Meanwhile the athlete asks the coach for a change, which is saved first.
      await repo.savePlanned(
        id: id,
        date: date,
        day: DayType.push,
        title: 'Coach plan',
        source: 'ai',
        coachNote: 'As you asked.',
        blocks: Repository.decodeBlocks(plan.blocksJson),
      );
      api.release.complete();
      await refining;

      expect((await repo.plannedById(id))!.title, 'Coach plan', reason: 'the older background result is dropped');
    });
  });
}

/// API whose workout call waits until [release] completes and then returns [blocks] unchanged.
class _GatedApi extends ApiClient {
  _GatedApi() : super(const ApiConfig(baseUrl: 'https://fake.test', apiKey: 'key'));

  final started = Completer<void>();
  final release = Completer<void>();
  List<dynamic> blocks = const [];

  @override
  Future<Map<String, dynamic>> post(String path, Object body, {Duration timeout = const Duration(seconds: 60)}) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return {
      'workout': {'id': 'ai-1', 'title': 'Background AI plan', 'coachNote': '', 'blocks': blocks, 'meta': <String, dynamic>{}},
    };
  }
}
