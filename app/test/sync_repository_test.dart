import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/api/api_client.dart';
import 'package:wfit/data/api/sync_service.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';

/// In-memory stand-in for `POST /sync`: stores pushed records (last write wins) and returns everything it has.
class FakeSyncApi extends ApiClient {
  FakeSyncApi() : super(const ApiConfig(baseUrl: 'https://fake.test', apiKey: 'test-key'));

  static const _keys = {'equipment': 'equipmentId', 'exercisePreferences': 'exerciseId'};
  final store = <String, Map<String, Map<String, dynamic>>>{};
  final requests = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> sync(Map<String, dynamic> request) async {
    final req = jsonDecode(jsonEncode(request)) as Map<String, dynamic>; // same shape as on the wire
    requests.add(req);
    (req['changes'] as Map<String, dynamic>).forEach((name, value) {
      final records =
          value is List ? value.cast<Map<String, dynamic>>() : [if (value != null) value as Map<String, dynamic>];
      for (final r in records) {
        final key = r[_keys[name] ?? 'id'] as String;
        final existing = store[name]?[key];
        if (existing == null ||
            !DateTime.parse(existing['updatedAt'] as String).isAfter(DateTime.parse(r['updatedAt'] as String))) {
          store.putIfAbsent(name, () => {})[key] = r;
        }
      }
    });
    return {
      'serverTime': DateTime.now().toUtc().toIso8601String(),
      'changes': {
        for (final e in store.entries) e.key: e.key == 'profile' ? e.value.values.single : e.value.values.toList(),
      },
    };
  }
}

const _blocks = [
  PlanBlock(
      section: Section.main,
      items: [PlanItem(exerciseId: 'leg-press', sets: 3, repMin: 8, repMax: 12, restSeconds: 120)]),
];

void main() {
  late AppDatabase db;
  late Repository repo;
  late SyncService sync;

  // The round-trip test opens a second device database on purpose.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    sync = SyncService(db);
  });
  tearDown(() => db.close());

  test('local writes are dirty and counted as pending', () async {
    await repo.setEquipment('leg_press', false);
    final sid = await repo.startSession(day: DayType.push, title: 'Push day');
    await repo.logSet(
      sessionId: sid,
      exerciseId: 'push-up',
      section: Section.main,
      exerciseOrder: 0,
      setNumber: 1,
      reps: 10,
      completed: true,
    );
    expect(await sync.pendingCount(), 3);
  });

  test('remote changes apply, but newer dirty local edits win', () async {
    await repo.setEquipment('leg_press', false); // local, dirty, now
    final older = DateTime.utc(2020).toIso8601String();
    final newer = DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String();
    final n = await sync.applyRemoteChanges({
      'equipment': [
        {'equipmentId': 'leg_press', 'available': true, 'updatedAt': older, 'deleted': false},
        {'equipmentId': 'barbell', 'available': false, 'updatedAt': newer, 'deleted': false},
      ],
      'bodyMetrics': [
        {'id': 'b1', 'date': '2026-11-01', 'weightKg': 78.5, 'updatedAt': newer, 'deleted': false},
      ],
    });
    expect(n, 2);
    final eq = await repo.getEquipment();
    expect(eq['leg_press'], isFalse, reason: 'local edit is newer');
    expect(eq['barbell'], isFalse);
    final body = await repo.watchBodyMetrics().first;
    expect(body.single.weightKg, 78.5);
    expect(body.single.dirty, isFalse);
  });

  test('loggedSets joins session dates and excludes deleted sessions', () async {
    final s1 = await repo.startSession(day: DayType.legs, title: 'Legs');
    await repo.logSet(
        sessionId: s1, exerciseId: 'goblet-squat', section: Section.main, exerciseOrder: 0, setNumber: 1,
        weightKg: 16, reps: 10, completed: true);
    await repo.logSet(
        sessionId: s1, exerciseId: 'goblet-squat', section: Section.main, exerciseOrder: 0, setNumber: 2,
        weightKg: 16, reps: 9, completed: false);
    await repo.finishSession(s1, rating: 4, effort: 7);
    final s2 = await repo.startSession(day: DayType.push, title: 'Push');
    await repo.logSet(
        sessionId: s2, exerciseId: 'push-up', section: Section.main, exerciseOrder: 0, setNumber: 1,
        reps: 12, completed: true);
    await repo.discardSession(s2);

    final sets = await repo.loggedSets();
    expect(sets.length, 1);
    expect(sets.single.weightKg, 16);
    final history = await repo.exerciseHistory('goblet-squat');
    expect(history.single.length, 1);
    expect((await repo.completedSessions()).single.rating, 4);
  });

  test('saving a plan supersedes the previous plan for the same date', () async {
    final date = DateTime(2026, 11, 4);
    final a = await repo.savePlanned(
        date: date, day: DayType.push, title: 'A', source: 'rules', coachNote: '', blocks: const []);
    final b = await repo.savePlanned(
        date: date, day: DayType.push, title: 'B', source: 'ai', coachNote: '', blocks: const []);
    expect((await repo.plannedForDate(date))!.id, b);
    expect((await repo.plannedById(a))!.deleted, isTrue);
  });

  test('profile JSON mapping matches the API contract', () async {
    await repo.saveProfile(const ProfilesCompanion(name: Value('Alex'), trainingDays: Value('1,3,5')));
    final p = await repo.getProfile();
    final json = profileToJson(p);
    expect(json['id'], 'me');
    expect(json['trainingDays'], [1, 3, 5]);
    expect(json['updatedAt'], endsWith('Z'));
  });

  test('feedback entries, plan meta and set RIR round-trip through /sync to a second device', () async {
    final api = FakeSyncApi();
    final today = DateTime.now();
    final sid = await repo.startSession(day: DayType.legs, title: 'Legs');
    await repo.logSet(
        sessionId: sid, exerciseId: 'leg-press', section: Section.main, exerciseOrder: 0, setNumber: 1,
        weightKg: 100, reps: 10, rir: 2, completed: true);
    final neck = await repo.addFeedback(kind: 'pain', region: 'neck', severity: 2, sessionId: sid, note: 'stiff neck');
    final hard = await repo.addFeedback(kind: 'too_hard', exerciseId: 'leg-press', source: 'coach');
    await repo.resolveFeedback(hard);
    const meta = '{"program":"Block 1 · Week 1 · Legs A","variant":"A","deload":false,"focus":["quads"]}';
    final pid = await repo.savePlanned(
        date: today, day: DayType.legs, title: 'Legs A', source: 'rules', coachNote: '', blocks: _blocks,
        metaJson: meta);
    expect(await sync.pendingCount(), 5); // session, set, 2 feedback entries, plan

    final result = await sync.sync(api);
    expect(result!.pushed, 5);
    expect(await sync.pendingCount(), 0);

    final pushed = api.requests.single['changes'] as Map<String, dynamic>;
    final fb = (pushed['feedbackEntries'] as List).cast<Map<String, dynamic>>();
    expect(fb.length, 2);
    final neckJson = fb.firstWhere((f) => f['id'] == neck);
    expect(neckJson.keys.toSet(), {
      'id', 'createdAt', 'kind', 'region', 'severity', 'exerciseId', 'sessionId', 'note', 'status', 'reviewOn', //
      'resolvedAt', 'source', 'updatedAt', 'deleted',
    });
    expect(neckJson['kind'], 'pain');
    expect(neckJson['severity'], 2);
    expect(neckJson['sessionId'], sid);
    expect(neckJson['createdAt'], endsWith('Z'));
    expect(neckJson['reviewOn'], dateKey(today.add(const Duration(days: 7))));
    expect(neckJson['resolvedAt'], isNull);
    final hardJson = fb.firstWhere((f) => f['id'] == hard);
    expect(hardJson['status'], 'resolved');
    expect(hardJson['resolvedAt'], endsWith('Z'));
    expect(hardJson['source'], 'coach');
    expect(hardJson['reviewOn'], isNull);
    final planJson = (pushed['plannedWorkouts'] as List).single as Map<String, dynamic>;
    expect(planJson['metaJson'], meta);
    expect(((pushed['sets'] as List).single as Map<String, dynamic>)['rir'], 2);

    // A second device pulls everything from the server.
    final db2 = AppDatabase(NativeDatabase.memory());
    addTearDown(db2.close);
    final repo2 = Repository(db2);
    final pulled = await SyncService(db2).sync(api);
    expect(pulled!.pulled, greaterThanOrEqualTo(5));
    expect(await SyncService(db2).pendingCount(), 0);

    final active = await repo2.activeFeedback();
    expect(active.single.id, neck);
    expect(active.single.region, 'neck');
    expect(active.single.note, 'stiff neck');
    expect(active.single.dirty, isFalse);
    final resolved = (await repo2.feedbackById(hard))!;
    expect(resolved.status, 'resolved');
    expect(resolved.resolvedAt, isNotNull);
    expect(resolved.exerciseId, 'leg-press');
    expect((await repo2.plannedById(pid))!.metaJson, meta);
    expect((await repo2.setsForSession(sid)).single.rir, 2);
  });

  test('pulled feedback and plan meta follow last-write-wins and soft deletes', () async {
    final local = await repo.addFeedback(kind: 'pain', region: 'knee', severity: 1);
    final pid = await repo.savePlanned(
        date: DateTime(2026, 11, 9), day: DayType.push, title: 'Push', source: 'rules', coachNote: '',
        blocks: _blocks, metaJson: '{"variant":"A"}');
    final older = DateTime.utc(2020).toIso8601String();
    final newer = DateTime.now().toUtc().add(const Duration(minutes: 5)).toIso8601String();
    final n = await sync.applyRemoteChanges({
      'feedbackEntries': [
        // Older remote edit of a dirty local entry: local wins.
        {'id': local, 'createdAt': older, 'kind': 'pain', 'region': 'knee', 'severity': 1, 'status': 'resolved',
          'resolvedAt': older, 'updatedAt': older, 'deleted': false},
        {'id': 'r1', 'createdAt': newer, 'kind': 'discomfort', 'region': 'shoulder', 'severity': 1, 'note': 'press',
          'status': 'active', 'reviewOn': '2026-11-20T00:00:00', 'source': 'coach', 'updatedAt': newer,
          'deleted': false},
        {'id': 'r2', 'createdAt': newer, 'kind': 'pain', 'region': 'wrist', 'severity': 2, 'status': 'active',
          'updatedAt': newer, 'deleted': true},
      ],
    });
    expect(n, 2);
    expect((await repo.feedbackById(local))!.status, 'active');
    final r1 = (await repo.feedbackById('r1'))!;
    expect(r1.reviewOn, '2026-11-20');
    expect(r1.source, 'coach');
    expect(r1.dirty, isFalse);
    expect((await repo.activeFeedback()).map((f) => f.id), unorderedEquals([local, 'r1']));

    // A plan from a backend that doesn't know metaJson keeps the local meta; an explicit value replaces it.
    final plan = plannedToJson((await repo.plannedById(pid))!)..remove('metaJson');
    await sync.applyRemoteChanges({
      'plannedWorkouts': [
        {...plan, 'title': 'Push (remote)', 'updatedAt': newer},
      ],
    });
    var stored = (await repo.plannedById(pid))!;
    expect(stored.title, 'Push (remote)');
    expect(stored.metaJson, '{"variant":"A"}');
    final newest = DateTime.now().toUtc().add(const Duration(minutes: 6)).toIso8601String();
    await sync.applyRemoteChanges({
      'plannedWorkouts': [
        {...plan, 'metaJson': '{"variant":"B"}', 'updatedAt': newest},
        {...plan, 'id': 'p-new', 'date': '2026-11-11', 'updatedAt': newer},
      ],
    });
    stored = (await repo.plannedById(pid))!;
    expect(stored.metaJson, '{"variant":"B"}');
    expect((await repo.plannedById('p-new'))!.metaJson, '{}');
  });

  test('resolve, postpone, delete and due check-ins', () async {
    final today = DateTime(2026, 11, 9);
    final due = await repo.addFeedback(
        kind: 'discomfort', region: 'shoulder', severity: 1, reviewOn: DateTime(2026, 11, 8),
        createdAt: DateTime.utc(2026, 11, 1));
    final dueToday = await repo.addFeedback(
        kind: 'pain', region: 'neck', severity: 2, reviewOn: today, createdAt: DateTime.utc(2026, 11, 2));
    final later = await repo.addFeedback(
        kind: 'pain', region: 'knee', severity: 1, reviewOn: DateTime(2026, 11, 16),
        createdAt: DateTime.utc(2026, 11, 3));
    final exercise = await repo.addFeedback(
        kind: 'too_hard', exerciseId: 'leg-press', note: 'x' * 2500, createdAt: DateTime.utc(2026, 11, 4));
    final resolved = await repo.addFeedback(
        kind: 'pain', region: 'elbow', severity: 1, reviewOn: DateTime(2026, 11, 1),
        createdAt: DateTime.utc(2026, 10, 20));
    await repo.resolveFeedback(resolved);
    final gone = await repo.addFeedback(
        kind: 'pain', region: 'wrist', severity: 1, reviewOn: DateTime(2026, 11, 1),
        createdAt: DateTime.utc(2026, 11, 5));
    await repo.deleteFeedback(gone);

    expect((await repo.dueCheckIns(today)).map((f) => f.id), [due, dueToday]);
    expect((await repo.dueCheckIns(DateTime(2026, 11, 16))).map((f) => f.id), [due, dueToday, later]);
    expect(await repo.watchDueCheckIns(today).first, hasLength(2));

    final exerciseEntry = (await repo.feedbackById(exercise))!;
    expect(exerciseEntry.reviewOn, isNull, reason: 'only pain/discomfort get check-ins');
    expect(exerciseEntry.note.length, Repository.maxFeedbackNote);

    // Default review delay when no date is given.
    final pain = await repo.addFeedback(kind: 'pain', region: 'hip', severity: 1);
    expect((await repo.feedbackById(pain))!.reviewOn, dateKey(DateTime.now().add(const Duration(days: 7))));
    await repo.deleteFeedback(pain);

    // "Still an issue" pushes the check-in out by the kind's default (discomfort: 14 days).
    await repo.postponeCheckIn(due);
    expect((await repo.feedbackById(due))!.reviewOn, dateKey(DateTime.now().add(const Duration(days: 14))));
    await repo.postponeCheckIn(dueToday, until: DateTime(2026, 11, 12));
    expect(await repo.dueCheckIns(today), isEmpty);

    await repo.resolveFeedback(later, at: DateTime.utc(2026, 11, 10, 8));
    final laterEntry = (await repo.feedbackById(later))!;
    expect(laterEntry.status, 'resolved');
    expect(laterEntry.resolvedAt!.toUtc(), DateTime.utc(2026, 11, 10, 8));
    expect(laterEntry.dirty, isTrue);

    expect((await repo.activeFeedback()).map((f) => f.id), [exercise, dueToday, due]);
    expect(await repo.watchActiveFeedback().first, hasLength(3));
    expect((await repo.feedbackSince(DateTime.utc(2026, 11, 2))).map((f) => f.id), [exercise, later, dueToday]);
    expect((await repo.feedbackSince(DateTime.utc(2026, 1, 1))).map((f) => f.id), contains(resolved));
    expect((await repo.feedbackForExercise('leg-press')).single.kind, 'too_hard');
    expect(await repo.feedbackForExercise('leg-press', activeOnly: true), hasLength(1));

    await repo.updateFeedback(exercise, const FeedbackEntriesCompanion(note: Value('easier now'), severity: Value(1)));
    final updated = (await repo.feedbackById(exercise))!;
    expect(updated.note, 'easier now');
    expect(updated.severity, 1);
    expect(updated.id, exercise);
  });

  test('plan meta is kept unless replaced, and plan history covers past plans', () async {
    final today = DateTime(2026, 11, 9);
    final id = await repo.savePlanned(
        date: today, day: DayType.push, title: 'Push A', source: 'rules', coachNote: '', blocks: _blocks,
        metaJson: '{"variant":"A"}');
    await repo.savePlanned(
        id: id, date: today, day: DayType.push, title: 'Push A (AI)', source: 'ai', coachNote: 'c', blocks: _blocks);
    expect((await repo.plannedById(id))!.metaJson, '{"variant":"A"}');
    await repo.updatePlannedBlocks(id, _blocks);
    expect((await repo.plannedById(id))!.metaJson, '{"variant":"A"}');
    await repo.updatePlannedBlocks(id, _blocks, metaJson: '{"variant":"B"}');
    expect((await repo.plannedById(id))!.metaJson, '{"variant":"B"}');
    await repo.updatePlannedMeta(id, '{"variant":"B","deload":true}');
    final plan = (await repo.plannedById(id))!;
    expect(plan.metaJson, '{"variant":"B","deload":true}');
    expect(plan.dirty, isTrue);

    Future<String> planOn(int dayOffset, {String status = 'planned'}) async {
      final pid = await repo.savePlanned(
          date: today.add(Duration(days: dayOffset)), day: DayType.legs, title: 'D$dayOffset', source: 'rules',
          coachNote: '', blocks: const []);
      if (status != 'planned') await repo.setPlannedStatus(pid, status);
      return pid;
    }

    final done = await planOn(-10, status: 'completed');
    final skipped = await planOn(-3);
    await planOn(2); // future
    await planOn(-100); // too old
    expect((await repo.plannedById(done))!.metaJson, '{}');

    final recent = await repo.recentPlanned(days: 14, now: today);
    expect(recent.map((p) => p.id), [id, skipped, done]);
    expect((await repo.recentPlanned(days: 14, now: today, completedOnly: true)).map((p) => p.id), [done]);
    expect(await repo.plannedHistory(), hasLength(5));
    expect(await repo.plannedHistory(to: today, limit: 2), hasLength(2));

    // A superseded plan for the same date is soft-deleted and drops out of the history.
    final replacement = await planOn(-3);
    expect((await repo.recentPlanned(days: 14, now: today)).map((p) => p.id), [id, replacement, done]);
  });

  test('latestBodyWeight returns the most recent logged weight', () async {
    expect(await repo.latestBodyWeight(), isNull);
    await repo.saveBodyMetric(const BodyMetricsCompanion(date: Value('2026-11-01'), weightKg: Value(80.0)));
    await repo.saveBodyMetric(const BodyMetricsCompanion(date: Value('2026-11-03'), weightKg: Value(79.0)));
    await repo.saveBodyMetric(const BodyMetricsCompanion(date: Value('2026-11-05'), waistCm: Value(84.0)));
    expect(await repo.latestBodyWeight(), 79.0);
  });
}
