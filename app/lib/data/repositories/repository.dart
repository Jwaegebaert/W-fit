import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';
import '../db/database.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime parseDateKey(String s) {
  final p = s.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

List<int> parseDays(String csv) =>
    csv.split(',').where((s) => s.trim().isNotEmpty).map((s) => int.parse(s.trim())).toList()..sort();

/// All local persistence. Every mutation stamps `updatedAt` and marks the row dirty for sync.
class Repository {
  Repository(this.db);

  final AppDatabase db;

  DateTime get _now => DateTime.now().toUtc();

  // ---------------- profile ----------------
  Future<Profile> getProfile() async {
    final existing = await (db.select(db.profiles)..where((t) => t.id.equals('me'))).getSingleOrNull();
    if (existing != null) return existing;
    await db.into(db.profiles).insert(ProfilesCompanion.insert(
          updatedAt: DateTime.utc(2000),
          goals: const Value('Lean, strong, flexible; better badminton mobility, explosiveness and stability'),
          dirty: const Value(false),
        ));
    return (db.select(db.profiles)..where((t) => t.id.equals('me'))).getSingle();
  }

  Stream<Profile> watchProfile() async* {
    await getProfile();
    yield* (db.select(db.profiles)..where((t) => t.id.equals('me'))).watchSingle();
  }

  Future<void> saveProfile(ProfilesCompanion p) async {
    await getProfile();
    await (db.update(db.profiles)..where((t) => t.id.equals('me')))
        .write(p.copyWith(updatedAt: Value(_now), dirty: const Value(true)));
  }

  // ---------------- equipment ----------------
  Stream<Map<String, bool>> watchEquipment() => (db.select(db.equipmentStatuses)
        ..where((t) => t.deleted.equals(false)))
      .watch()
      .map((rows) => {for (final r in rows) r.equipmentId: r.available});

  Future<Map<String, bool>> getEquipment() async {
    final rows = await (db.select(db.equipmentStatuses)..where((t) => t.deleted.equals(false))).get();
    return {for (final r in rows) r.equipmentId: r.available};
  }

  Future<void> setEquipment(String equipmentId, bool available) =>
      db.into(db.equipmentStatuses).insertOnConflictUpdate(EquipmentStatusesCompanion.insert(
            equipmentId: equipmentId,
            available: available,
            updatedAt: _now,
            deleted: const Value(false),
            dirty: const Value(true),
          ));

  // ---------------- preferences ----------------
  Stream<Map<String, String>> watchPreferences() => (db.select(db.exercisePreferences)
        ..where((t) => t.deleted.equals(false)))
      .watch()
      .map((rows) => {for (final r in rows) r.exerciseId: r.preference});

  Future<Map<String, String>> getPreferences() async {
    final rows = await (db.select(db.exercisePreferences)..where((t) => t.deleted.equals(false))).get();
    return {for (final r in rows) r.exerciseId: r.preference};
  }

  Future<void> setPreference(String exerciseId, String preference) =>
      db.into(db.exercisePreferences).insertOnConflictUpdate(ExercisePreferencesCompanion.insert(
            exerciseId: exerciseId,
            preference: preference,
            updatedAt: _now,
            deleted: const Value(false),
            dirty: const Value(true),
          ));

  // ---------------- planned workouts ----------------
  Stream<List<PlannedWorkout>> watchPlannedFrom(DateTime from) => (db.select(db.plannedWorkouts)
        ..where((t) =>
            t.deleted.equals(false) &
            t.status.equals('planned') &
            t.date.isBiggerOrEqualValue(dateKey(from)))
        ..orderBy([(t) => OrderingTerm.asc(t.date), (t) => OrderingTerm.desc(t.updatedAt)]))
      .watch();

  Future<PlannedWorkout?> plannedForDate(DateTime date) async {
    final rows = await (db.select(db.plannedWorkouts)
          ..where((t) => t.deleted.equals(false) & t.status.equals('planned') & t.date.equals(dateKey(date)))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<PlannedWorkout?> plannedById(String id) =>
      (db.select(db.plannedWorkouts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<PlannedWorkout?> watchPlanned(String id) =>
      (db.select(db.plannedWorkouts)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<String> savePlanned({
    String? id,
    required DateTime date,
    required DayType day,
    required String title,
    required String source,
    required String coachNote,
    required List<PlanBlock> blocks,
    int? estimatedMinutes,
  }) async {
    final pid = id ?? newId();
    // Only one open plan per date: supersede any other planned workout on the same day.
    await (db.update(db.plannedWorkouts)
          ..where((t) =>
              t.date.equals(dateKey(date)) & t.status.equals('planned') & t.id.equals(pid).not() & t.deleted.equals(false)))
        .write(PlannedWorkoutsCompanion(deleted: const Value(true), updatedAt: Value(_now), dirty: const Value(true)));
    await db.into(db.plannedWorkouts).insertOnConflictUpdate(PlannedWorkoutsCompanion.insert(
          id: pid,
          date: dateKey(date),
          dayType: day.name,
          title: title,
          source: source,
          coachNote: Value(coachNote),
          estimatedMinutes: Value(estimatedMinutes ?? estimateMinutes(blocks)),
          blocksJson: jsonEncode(blocks.map((b) => b.toJson()).toList()),
          updatedAt: _now,
          dirty: const Value(true),
        ));
    return pid;
  }

  Future<void> updatePlannedBlocks(String id, List<PlanBlock> blocks) =>
      (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(PlannedWorkoutsCompanion(
        blocksJson: Value(jsonEncode(blocks.map((b) => b.toJson()).toList())),
        estimatedMinutes: Value(estimateMinutes(blocks)),
        updatedAt: Value(_now),
        dirty: const Value(true),
      ));

  Future<void> setPlannedStatus(String id, String status) =>
      (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(PlannedWorkoutsCompanion(
        status: Value(status),
        updatedAt: Value(_now),
        dirty: const Value(true),
      ));

  static List<PlanBlock> decodeBlocks(String json) =>
      (jsonDecode(json) as List).map((e) => PlanBlock.fromJson(e as Map<String, dynamic>)).toList();

  // ---------------- sessions ----------------
  Future<String> startSession({String? plannedWorkoutId, required DayType day, required String title}) async {
    final id = newId();
    await db.into(db.workoutSessions).insert(WorkoutSessionsCompanion.insert(
          id: id,
          plannedWorkoutId: Value(plannedWorkoutId),
          dayType: day.name,
          title: title,
          startedAt: _now,
          updatedAt: _now,
        ));
    return id;
  }

  Stream<WorkoutSession?> watchActiveSession() => (db.select(db.workoutSessions)
        ..where((t) => t.deleted.equals(false) & t.endedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
        ..limit(1))
      .watchSingleOrNull();

  Stream<WorkoutSession?> watchSession(String id) =>
      (db.select(db.workoutSessions)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<WorkoutSession?> sessionById(String id) =>
      (db.select(db.workoutSessions)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> finishSession(String id, {int? rating, int? effort, String notes = ''}) async {
    final s = await sessionById(id);
    if (s == null) return;
    final end = _now;
    await (db.update(db.workoutSessions)..where((t) => t.id.equals(id))).write(WorkoutSessionsCompanion(
      endedAt: Value(end),
      durationSeconds: Value(end.difference(s.startedAt.toUtc()).inSeconds),
      rating: Value(rating),
      perceivedEffort: Value(effort),
      notes: Value(notes),
      updatedAt: Value(end),
      dirty: const Value(true),
    ));
    if (s.plannedWorkoutId != null) await setPlannedStatus(s.plannedWorkoutId!, 'completed');
  }

  Future<void> discardSession(String id) async {
    await (db.update(db.workoutSessions)..where((t) => t.id.equals(id))).write(WorkoutSessionsCompanion(
      deleted: const Value(true),
      endedAt: Value(_now),
      updatedAt: Value(_now),
      dirty: const Value(true),
    ));
    await (db.update(db.setLogs)..where((t) => t.sessionId.equals(id))).write(
        SetLogsCompanion(deleted: const Value(true), updatedAt: Value(_now), dirty: const Value(true)));
  }

  Stream<List<WorkoutSession>> watchCompletedSessions() => (db.select(db.workoutSessions)
        ..where((t) => t.deleted.equals(false) & t.endedAt.isNotNull())
        ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
      .watch();

  Future<List<WorkoutSession>> completedSessions() => (db.select(db.workoutSessions)
        ..where((t) => t.deleted.equals(false) & t.endedAt.isNotNull())
        ..orderBy([(t) => OrderingTerm.desc(t.startedAt)]))
      .get();

  // ---------------- sets ----------------
  Stream<List<SetLog>> watchSets(String sessionId) => (db.select(db.setLogs)
        ..where((t) => t.sessionId.equals(sessionId) & t.deleted.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.exerciseOrder), (t) => OrderingTerm.asc(t.setNumber)]))
      .watch();

  Future<List<SetLog>> setsForSession(String sessionId) => (db.select(db.setLogs)
        ..where((t) => t.sessionId.equals(sessionId) & t.deleted.equals(false))
        ..orderBy([(t) => OrderingTerm.asc(t.exerciseOrder), (t) => OrderingTerm.asc(t.setNumber)]))
      .get();

  Future<void> logSet({
    String? id,
    required String sessionId,
    required String exerciseId,
    required Section section,
    required int exerciseOrder,
    required int setNumber,
    double? weightKg,
    int? reps,
    int? durationSeconds,
    int? rir,
    required bool completed,
  }) =>
      db.into(db.setLogs).insertOnConflictUpdate(SetLogsCompanion.insert(
            id: id ?? newId(),
            sessionId: sessionId,
            exerciseId: exerciseId,
            section: section.name,
            exerciseOrder: exerciseOrder,
            setNumber: setNumber,
            weightKg: Value(weightKg),
            reps: Value(reps),
            durationSeconds: Value(durationSeconds),
            rir: Value(rir),
            completed: Value(completed),
            completedAt: Value(completed ? _now : null),
            updatedAt: _now,
            deleted: const Value(false),
            dirty: const Value(true),
          ));

  Future<void> deleteSet(String id) => (db.update(db.setLogs)..where((t) => t.id.equals(id))).write(
      SetLogsCompanion(deleted: const Value(true), updatedAt: Value(_now), dirty: const Value(true)));

  /// Completed sets from finished sessions, joined with the session date.
  Future<List<LoggedSet>> loggedSets({String? exerciseId, DateTime? since, String? excludeSessionId}) async {
    final q = db.select(db.setLogs).join([
      innerJoin(db.workoutSessions, db.workoutSessions.id.equalsExp(db.setLogs.sessionId)),
    ])
      ..where(db.setLogs.deleted.equals(false) &
          db.setLogs.completed.equals(true) &
          db.workoutSessions.deleted.equals(false));
    if (exerciseId != null) q.where(db.setLogs.exerciseId.equals(exerciseId));
    if (since != null) q.where(db.workoutSessions.startedAt.isBiggerOrEqualValue(since));
    if (excludeSessionId != null) q.where(db.setLogs.sessionId.equals(excludeSessionId).not());
    q.orderBy([OrderingTerm.desc(db.workoutSessions.startedAt), OrderingTerm.asc(db.setLogs.setNumber)]);
    final rows = await q.get();
    return rows.map((r) {
      final s = r.readTable(db.setLogs);
      final w = r.readTable(db.workoutSessions);
      return LoggedSet(
        sessionId: s.sessionId,
        exerciseId: s.exerciseId,
        date: w.startedAt,
        weightKg: s.weightKg,
        reps: s.reps,
        durationSeconds: s.durationSeconds,
        completed: s.completed,
      );
    }).toList();
  }

  /// Sets for one exercise grouped by session, most recent first.
  Future<List<List<LoggedSet>>> exerciseHistory(String exerciseId, {String? excludeSessionId, int maxSessions = 6}) async {
    final sets = await loggedSets(exerciseId: exerciseId, excludeSessionId: excludeSessionId);
    final grouped = <String, List<LoggedSet>>{};
    for (final s in sets) {
      grouped.putIfAbsent(s.sessionId, () => []).add(s);
    }
    return grouped.values.take(maxSessions).toList();
  }

  // ---------------- body metrics ----------------
  Stream<List<BodyMetric>> watchBodyMetrics() => (db.select(db.bodyMetrics)
        ..where((t) => t.deleted.equals(false))
        ..orderBy([(t) => OrderingTerm.desc(t.date)]))
      .watch();

  Future<void> saveBodyMetric(BodyMetricsCompanion m) => db.into(db.bodyMetrics).insertOnConflictUpdate(
        m.copyWith(
          id: m.id.present ? m.id : Value(newId()),
          updatedAt: Value(_now),
          deleted: const Value(false),
          dirty: const Value(true),
        ),
      );

  Future<void> deleteBodyMetric(String id) => (db.update(db.bodyMetrics)..where((t) => t.id.equals(id))).write(
      BodyMetricsCompanion(deleted: const Value(true), updatedAt: Value(_now), dirty: const Value(true)));
}
