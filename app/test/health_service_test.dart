import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/api/sync_service.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/services/health_service.dart';

/// Stand-in for Health Connect: records writes and serves heart-rate samples.
class FakeHealthBridge implements HealthBridge {
  HealthAvailability available = HealthAvailability.available;
  bool access = true;
  bool failWrites = false;
  List<HeartRateSample> samples = const [];
  final written = <String>[];
  int reads = 0;

  @override
  Future<HealthAvailability> availability() async => available;
  @override
  Future<void> install() async {}
  @override
  Future<bool> hasAccess() async => access;
  @override
  Future<bool> requestAccess() async => access;

  @override
  Future<bool> writeWorkout({required String id, required DateTime start, required DateTime end, required String title}) async {
    if (failWrites) throw Exception('Health Connect busy');
    written.add(id);
    return true;
  }

  @override
  Future<List<HeartRateSample>> heartRate(DateTime start, DateTime end) async {
    reads++;
    return [for (final s in samples) if (!s.time.isBefore(start) && !s.time.isAfter(end)) s];
  }
}

void main() {
  late AppDatabase db;
  late Repository repo;
  late FakeHealthBridge bridge;
  late HealthSync health;

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    bridge = FakeHealthBridge();
    health = HealthSync(repo, bridge);
  });
  tearDown(() => db.close());

  /// A finished session from [start] lasting [minutes].
  Future<WorkoutSession> finished(DateTime start, {int minutes = 60}) async {
    final id = await repo.startSession(day: DayType.push, title: 'Push A');
    await (db.update(db.workoutSessions)..where((t) => t.id.equals(id))).write(WorkoutSessionsCompanion(
      startedAt: Value(start.toUtc()),
      endedAt: Value(start.add(Duration(minutes: minutes)).toUtc()),
      durationSeconds: Value(minutes * 60),
    ));
    return (await repo.sessionById(id))!;
  }

  List<HeartRateSample> hr(DateTime from, List<double> bpm) =>
      [for (var i = 0; i < bpm.length; i++) (time: from.add(Duration(minutes: 5 * i + 1)), bpm: bpm[i])];

  test('summarize: average and max of plausible readings, nothing for too few', () {
    final t = DateTime(2026, 11, 23, 18);
    final s = HealthSync.summarize(hr(t, [100, 120, 140, 250, 10]))!;
    expect(s.avg, 120);
    expect(s.max, 140);
    expect(s.samples, 3, reason: '250 and 10 bpm are dropped as implausible');
    expect(HealthSync.summarize(hr(t, [100, 120])), isNull);
  });

  test('does nothing until the athlete enables it', () async {
    final now = DateTime.now();
    await finished(now.subtract(const Duration(hours: 2)));
    expect(await health.catchUp(), 0);
    expect(bridge.written, isEmpty);
    expect(bridge.reads, 0);
  });

  test('exports each finished workout once and stores the watch heart rate', () async {
    await health.setEnabled(true);
    final start = DateTime.now().subtract(const Duration(hours: 2));
    final s = await finished(start);
    bridge.samples = hr(start, [95, 130, 150, 142]);

    expect(await health.catchUp(), 1);
    expect(bridge.written, [s.id]);
    final stored = (await repo.sessionById(s.id))!;
    expect(stored.avgHeartRate, 129);
    expect(stored.maxHeartRate, 150);
    expect(stored.healthExportedAt, isNotNull);
    expect(stored.dirty, isTrue, reason: 'heart rate syncs to the backend');
    expect(sessionToJson(stored)['avgHeartRate'], 129);

    expect(await health.catchUp(), 0, reason: 'nothing left to do');
    expect(bridge.written, [s.id], reason: 'never written twice');
  });

  test('heart rate that arrives later (watch sync) is filled on a later catch-up', () async {
    await health.setEnabled(true);
    final start = DateTime.now().subtract(const Duration(hours: 1));
    final s = await finished(start);

    expect(await health.catchUp(), 1, reason: 'exported, no heart rate yet');
    expect((await repo.sessionById(s.id))!.avgHeartRate, isNull);

    bridge.samples = hr(start, [110, 120, 130]);
    expect(await health.catchUp(), 1);
    expect((await repo.sessionById(s.id))!.avgHeartRate, 120);
    expect(bridge.written, hasLength(1));
  });

  test('ignores old sessions, missing access and Health Connect errors', () async {
    await health.setEnabled(true);
    await finished(DateTime.now().subtract(const Duration(days: HealthSync.retryDays + 1)));
    expect(await health.catchUp(), 0, reason: 'older than the retry window');

    final recent = await finished(DateTime.now().subtract(const Duration(hours: 3)));
    bridge.access = false;
    expect(await health.catchUp(), 0);
    bridge.access = true;
    bridge.failWrites = true;
    expect(await health.catchUp(), 0, reason: 'errors are swallowed, the session is retried later');
    expect((await repo.sessionById(recent.id))!.healthExportedAt, isNull);

    bridge.available = HealthAvailability.notInstalled;
    bridge.failWrites = false;
    expect(await health.catchUp(), 0);
  });
}
