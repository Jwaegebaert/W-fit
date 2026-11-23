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
  Repository(this.db, {this.catalog});

  final AppDatabase db;

  /// Used to add bar weights to logged sets; optional so storage tests can run without it.
  final Catalog? catalog;

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

  /// Stores the user's empty-bar weight for [equipmentId] in the profile (synced with it).
  Future<void> setBarWeight(String equipmentId, double kg) async {
    final current = Map<String, double>.of(LoadModel.parseOverrides((await getProfile()).barWeightsJson));
    current[equipmentId] = kg;
    await saveProfile(ProfilesCompanion(barWeightsJson: Value(jsonEncode(current))));
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

  /// Newest open plan dated before [date] (and not before [since]): a workout that was planned but not trained.
  Future<PlannedWorkout?> latestMissedPlan(DateTime date, {required DateTime since}) async {
    final rows = await (db.select(db.plannedWorkouts)
          ..where((t) =>
              t.deleted.equals(false) &
              t.status.equals('planned') &
              t.date.isSmallerThanValue(dateKey(date)) &
              t.date.isBiggerOrEqualValue(dateKey(since)))
          ..orderBy([(t) => OrderingTerm.desc(t.date), (t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(1))
        .get();
    return rows.firstOrNull;
  }

  /// Moves an open plan to [date] (keeping its id, exercises and source) and supersedes other open plans there.
  Future<void> movePlanned(String id, DateTime date, {String? metaJson}) async {
    await (db.update(db.plannedWorkouts)
          ..where((t) =>
              t.date.equals(dateKey(date)) & t.status.equals('planned') & t.id.equals(id).not() & t.deleted.equals(false)))
        .write(PlannedWorkoutsCompanion(deleted: const Value(true), updatedAt: Value(_now), dirty: const Value(true)));
    await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(PlannedWorkoutsCompanion(
          date: Value(dateKey(date)),
          metaJson: metaJson == null ? const Value.absent() : Value(metaJson),
          updatedAt: Value(_now),
          dirty: const Value(true),
        ));
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
    String? metaJson,
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
          // Null keeps the stored meta when re-saving an existing id ('{}' for a new row).
          metaJson: metaJson == null ? const Value.absent() : Value(metaJson),
          updatedAt: _now,
          dirty: const Value(true),
        ));
    return pid;
  }

  Future<void> updatePlannedBlocks(String id, List<PlanBlock> blocks, {String? metaJson}) =>
      (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(PlannedWorkoutsCompanion(
        blocksJson: Value(jsonEncode(blocks.map((b) => b.toJson()).toList())),
        estimatedMinutes: Value(estimateMinutes(blocks)),
        metaJson: metaJson == null ? const Value.absent() : Value(metaJson),
        updatedAt: Value(_now),
        dirty: const Value(true),
      ));

  Future<void> updatePlannedMeta(String id, String metaJson) =>
      (db.update(db.plannedWorkouts)..where((t) => t.id.equals(id))).write(PlannedWorkoutsCompanion(
        metaJson: Value(metaJson),
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

  /// Non-deleted planned workouts of any status (planned, completed, …) dated within [from]..[to] (inclusive),
  /// newest first. Superseded plans are soft-deleted and therefore excluded.
  Future<List<PlannedWorkout>> plannedHistory({DateTime? from, DateTime? to, bool completedOnly = false, int? limit}) {
    final q = db.select(db.plannedWorkouts)..where((t) => t.deleted.equals(false));
    if (from != null) q.where((t) => t.date.isBiggerOrEqualValue(dateKey(from)));
    if (to != null) q.where((t) => t.date.isSmallerOrEqualValue(dateKey(to)));
    if (completedOnly) q.where((t) => t.status.equals('completed'));
    q.orderBy([(t) => OrderingTerm.desc(t.date), (t) => OrderingTerm.desc(t.updatedAt)]);
    if (limit != null) q.limit(limit);
    return q.get();
  }

  /// Planned workouts of the last [days] days up to and including today ([now]), newest first.
  Future<List<PlannedWorkout>> recentPlanned({int days = 84, DateTime? now, bool completedOnly = false}) {
    final today = now ?? DateTime.now();
    return plannedHistory(from: today.subtract(Duration(days: days)), to: today, completedOnly: completedOnly);
  }

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
    q.orderBy([
      OrderingTerm.desc(db.workoutSessions.startedAt),
      OrderingTerm.asc(db.setLogs.exerciseOrder),
      OrderingTerm.asc(db.setLogs.setNumber),
    ]);
    final rows = await q.get();
    final loads = await loadModel();
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
        section: s.section,
        rir: s.rir,
        barKg: loads?.barKgFor(s.exerciseId) ?? 0,
        assisted: loads?.isAssisted(s.exerciseId) ?? false,
      );
    }).toList();
  }

  /// Bar weights (catalog defaults + the user's overrides) and assisted machines; null without a catalog.
  Future<LoadModel?> loadModel() async {
    final c = catalog;
    if (c == null) return null;
    return LoadModel(c, LoadModel.parseOverrides((await getProfile()).barWeightsJson));
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

  /// Most recent recorded body weight (kg), or null when none was logged.
  Future<double?> latestBodyWeight() async {
    final row = await (db.select(db.bodyMetrics)
          ..where((t) => t.deleted.equals(false) & t.weightKg.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.date), (t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(1))
        .getSingleOrNull();
    return row?.weightKg;
  }

  // ---------------- feedback memory (docs/IMPROVEMENT-PLAN.md §4.3) ----------------
  static const feedbackActive = 'active';
  static const feedbackResolved = 'resolved';

  /// Kinds that describe a limitation and get periodic check-ins.
  static const checkInKinds = {'pain', 'discomfort'};
  static const maxFeedbackNote = 2000;

  /// Default check-in delay in days: pain 7, discomfort 14, otherwise none.
  static int? defaultReviewDays(String kind) => switch (kind) {
        'pain' => 7,
        'discomfort' => 14,
        _ => null,
      };

  static String _clampNote(String note) => note.length > maxFeedbackNote ? note.substring(0, maxFeedbackNote) : note;

  /// Records feedback and returns its id. Without [reviewOn], pain/discomfort get the default check-in date.
  Future<String> addFeedback({
    String? id,
    required String kind,
    String? region,
    int? severity,
    String? exerciseId,
    String? sessionId,
    String note = '',
    DateTime? reviewOn,
    String source = 'user',
    DateTime? createdAt,
  }) async {
    final fid = id ?? newId();
    final now = _now;
    final days = defaultReviewDays(kind);
    final review = reviewOn ?? (days == null ? null : DateTime.now().add(Duration(days: days)));
    await db.into(db.feedbackEntries).insertOnConflictUpdate(FeedbackEntriesCompanion.insert(
          id: fid,
          createdAt: (createdAt ?? now).toUtc(),
          kind: kind,
          region: Value(region),
          severity: Value(severity),
          exerciseId: Value(exerciseId),
          sessionId: Value(sessionId),
          note: Value(_clampNote(note)),
          status: const Value(feedbackActive),
          reviewOn: Value(review == null ? null : dateKey(review)),
          resolvedAt: const Value(null),
          source: Value(source),
          updatedAt: now,
          deleted: const Value(false),
          dirty: const Value(true),
        ));
    return fid;
  }

  /// Applies the present fields of [changes] to entry [id] (the id itself is never changed).
  Future<void> updateFeedback(String id, FeedbackEntriesCompanion changes) =>
      (db.update(db.feedbackEntries)..where((t) => t.id.equals(id))).write(changes.copyWith(
        id: const Value.absent(),
        note: changes.note.present ? Value(_clampNote(changes.note.value)) : const Value.absent(),
        updatedAt: Value(_now),
        dirty: const Value(true),
      ));

  Future<void> resolveFeedback(String id, {DateTime? at}) => updateFeedback(
      id,
      FeedbackEntriesCompanion(
        status: const Value(feedbackResolved),
        resolvedAt: Value((at ?? _now).toUtc()),
      ));

  /// "Still an issue": keeps the entry active and asks again on [until] (default: the kind's delay, else 7 days).
  Future<void> postponeCheckIn(String id, {DateTime? until}) async {
    final entry = await feedbackById(id);
    if (entry == null) return;
    final next = until ?? DateTime.now().add(Duration(days: defaultReviewDays(entry.kind) ?? 7));
    await updateFeedback(
        id,
        FeedbackEntriesCompanion(
          status: const Value(feedbackActive),
          resolvedAt: const Value(null),
          reviewOn: Value(dateKey(next)),
        ));
  }

  Future<void> deleteFeedback(String id) => (db.update(db.feedbackEntries)..where((t) => t.id.equals(id))).write(
      FeedbackEntriesCompanion(deleted: const Value(true), updatedAt: Value(_now), dirty: const Value(true)));

  Future<FeedbackEntry?> feedbackById(String id) =>
      (db.select(db.feedbackEntries)..where((t) => t.id.equals(id))).getSingleOrNull();

  SimpleSelectStatement<$FeedbackEntriesTable, FeedbackEntry> _activeFeedbackQuery() => db.select(db.feedbackEntries)
    ..where((t) => t.deleted.equals(false) & t.status.equals(feedbackActive))
    ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);

  /// Active (unresolved) entries of every kind, newest first.
  Stream<List<FeedbackEntry>> watchActiveFeedback() => _activeFeedbackQuery().watch();

  Future<List<FeedbackEntry>> activeFeedback() => _activeFeedbackQuery().get();

  /// Entries of every kind and status created at or after [since], newest first.
  Future<List<FeedbackEntry>> feedbackSince(DateTime since) => (db.select(db.feedbackEntries)
        ..where((t) => t.deleted.equals(false) & t.createdAt.isBiggerOrEqualValue(since))
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
      .get();

  /// Entries (any status unless [activeOnly]) about one exercise, newest first.
  Future<List<FeedbackEntry>> feedbackForExercise(String exerciseId, {bool activeOnly = false}) {
    final q = db.select(db.feedbackEntries)
      ..where((t) => t.deleted.equals(false) & t.exerciseId.equals(exerciseId))
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (activeOnly) q.where((t) => t.status.equals(feedbackActive));
    return q.get();
  }

  SimpleSelectStatement<$FeedbackEntriesTable, FeedbackEntry> _dueCheckInsQuery(DateTime today) =>
      db.select(db.feedbackEntries)
        ..where((t) =>
            t.deleted.equals(false) &
            t.status.equals(feedbackActive) &
            t.kind.isIn(checkInKinds) &
            t.reviewOn.isNotNull() &
            t.reviewOn.isSmallerOrEqualValue(dateKey(today)))
        ..orderBy([(t) => OrderingTerm.asc(t.reviewOn), (t) => OrderingTerm.asc(t.createdAt)]);

  /// Active pain/discomfort entries whose check-in date is on or before [today] (local date).
  Future<List<FeedbackEntry>> dueCheckIns(DateTime today) => _dueCheckInsQuery(today).get();

  Stream<List<FeedbackEntry>> watchDueCheckIns(DateTime today) => _dueCheckInsQuery(today).watch();
}
