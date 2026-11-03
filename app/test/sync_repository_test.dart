import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/api/sync_service.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';

void main() {
  late AppDatabase db;
  late Repository repo;
  late SyncService sync;

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
}
