import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/catalog.dart' show LoadModel;
import '../../domain/muscles.dart' show MuscleFocus;
import '../db/database.dart';
import 'api_client.dart';

String _iso(DateTime d) => d.toUtc().toIso8601String();
DateTime _dt(dynamic v) => DateTime.parse(v as String).toUtc();
DateTime? _dtn(dynamic v) => v == null ? null : DateTime.parse(v as String).toUtc();
double? _d(dynamic v) => (v as num?)?.toDouble();
int? _i(dynamic v) => (v as num?)?.toInt();

class SyncResult {
  const SyncResult({required this.pushed, required this.pulled, required this.at});
  final int pushed;
  final int pulled;
  final DateTime at;
}

/// Pushes dirty local rows and pulls remote changes in a single `/sync` round-trip (last-write-wins).
class SyncService {
  SyncService(this.db);

  final AppDatabase db;
  static const sinceKey = 'sync_since';
  static const lastSyncKey = 'sync_last_success';
  static const maxBatch = 1500;
  bool _running = false;

  Future<DateTime?> lastSuccess() async {
    final v = await db.getValue(lastSyncKey);
    return v == null ? null : DateTime.parse(v);
  }

  Future<int> pendingCount() async {
    var n = 0;
    n += await _count(db.profiles, db.profiles.dirty);
    n += await _count(db.equipmentStatuses, db.equipmentStatuses.dirty);
    n += await _count(db.exercisePreferences, db.exercisePreferences.dirty);
    n += await _count(db.plannedWorkouts, db.plannedWorkouts.dirty);
    n += await _count(db.workoutSessions, db.workoutSessions.dirty);
    n += await _count(db.setLogs, db.setLogs.dirty);
    n += await _count(db.bodyMetrics, db.bodyMetrics.dirty);
    n += await _count(db.feedbackEntries, db.feedbackEntries.dirty);
    return n;
  }

  Future<int> _count(TableInfo table, GeneratedColumn<bool> dirty) async {
    final c = countAll(filter: dirty.equals(true));
    final row = await (db.selectOnly(table)..addColumns([c])).getSingle();
    return row.read(c) ?? 0;
  }

  Future<SyncResult?> sync(ApiClient api) async {
    if (_running || !api.config.isConfigured) return null;
    _running = true;
    try {
      final profile = await (db.select(db.profiles)..where((t) => t.dirty.equals(true))).getSingleOrNull();
      final equipment = await (db.select(db.equipmentStatuses)..where((t) => t.dirty.equals(true))).get();
      final prefs = await (db.select(db.exercisePreferences)..where((t) => t.dirty.equals(true))).get();
      final planned = await (db.select(db.plannedWorkouts)..where((t) => t.dirty.equals(true))..limit(200)).get();
      final sessions = await (db.select(db.workoutSessions)..where((t) => t.dirty.equals(true))..limit(200)).get();
      final sets = await (db.select(db.setLogs)..where((t) => t.dirty.equals(true))..limit(maxBatch)).get();
      final body = await (db.select(db.bodyMetrics)..where((t) => t.dirty.equals(true))..limit(200)).get();
      final feedback = await (db.select(db.feedbackEntries)..where((t) => t.dirty.equals(true))..limit(200)).get();

      final since = await db.getValue(sinceKey);
      final response = await api.sync({
        'since': since,
        'changes': {
          'profile': profile == null ? null : profileToJson(profile),
          'equipment': equipment.map(equipmentToJson).toList(),
          'exercisePreferences': prefs.map(preferenceToJson).toList(),
          'plannedWorkouts': planned.map(plannedToJson).toList(),
          'sessions': sessions.map(sessionToJson).toList(),
          'sets': sets.map(setToJson).toList(),
          'bodyMetrics': body.map(bodyToJson).toList(),
          'feedbackEntries': feedback.map(feedbackToJson).toList(),
        },
      });

      final pushed = (profile == null ? 0 : 1) +
          equipment.length + prefs.length + planned.length + sessions.length + sets.length + body.length +
          feedback.length;

      var pulled = 0;
      await db.transaction(() async {
        // Mark pushed rows clean unless they were modified again while the request was in flight.
        if (profile != null) {
          await (db.update(db.profiles)..where((t) => t.id.equals(profile.id) & t.updatedAt.equals(profile.updatedAt)))
              .write(const ProfilesCompanion(dirty: Value(false)));
        }
        for (final r in equipment) {
          await (db.update(db.equipmentStatuses)
                ..where((t) => t.equipmentId.equals(r.equipmentId) & t.updatedAt.equals(r.updatedAt)))
              .write(const EquipmentStatusesCompanion(dirty: Value(false)));
        }
        for (final r in prefs) {
          await (db.update(db.exercisePreferences)
                ..where((t) => t.exerciseId.equals(r.exerciseId) & t.updatedAt.equals(r.updatedAt)))
              .write(const ExercisePreferencesCompanion(dirty: Value(false)));
        }
        for (final r in planned) {
          await (db.update(db.plannedWorkouts)..where((t) => t.id.equals(r.id) & t.updatedAt.equals(r.updatedAt)))
              .write(const PlannedWorkoutsCompanion(dirty: Value(false)));
        }
        for (final r in sessions) {
          await (db.update(db.workoutSessions)..where((t) => t.id.equals(r.id) & t.updatedAt.equals(r.updatedAt)))
              .write(const WorkoutSessionsCompanion(dirty: Value(false)));
        }
        for (final r in sets) {
          await (db.update(db.setLogs)..where((t) => t.id.equals(r.id) & t.updatedAt.equals(r.updatedAt)))
              .write(const SetLogsCompanion(dirty: Value(false)));
        }
        for (final r in body) {
          await (db.update(db.bodyMetrics)..where((t) => t.id.equals(r.id) & t.updatedAt.equals(r.updatedAt)))
              .write(const BodyMetricsCompanion(dirty: Value(false)));
        }
        for (final r in feedback) {
          await (db.update(db.feedbackEntries)..where((t) => t.id.equals(r.id) & t.updatedAt.equals(r.updatedAt)))
              .write(const FeedbackEntriesCompanion(dirty: Value(false)));
        }

        pulled = await applyRemoteChanges(response['changes'] as Map<String, dynamic>? ?? const {});
        await db.setValue(sinceKey, response['serverTime'] as String);
        await db.setValue(lastSyncKey, DateTime.now().toUtc().toIso8601String());
      });

      return SyncResult(pushed: pushed, pulled: pulled, at: DateTime.now());
    } finally {
      _running = false;
    }
  }

  /// Applies server records unless a newer local edit is still waiting to be pushed.
  Future<int> applyRemoteChanges(Map<String, dynamic> changes) async {
    var n = 0;
    bool keepLocal(bool? dirty, DateTime? localUpdated, DateTime remoteUpdated) =>
        dirty == true && localUpdated != null && localUpdated.toUtc().isAfter(remoteUpdated);

    final p = changes['profile'] as Map<String, dynamic>?;
    if (p != null) {
      final local = await (db.select(db.profiles)..where((t) => t.id.equals('me'))).getSingleOrNull();
      if (!keepLocal(local?.dirty, local?.updatedAt, _dt(p['updatedAt']))) {
        await db.into(db.profiles).insertOnConflictUpdate(ProfilesCompanion.insert(
              id: const Value('me'),
              name: Value(p['name'] as String? ?? ''),
              experience: Value(p['experience'] as String? ?? 'beginner'),
              goals: Value(p['goals'] as String? ?? ''),
              trainingDays: Value(((p['trainingDays'] as List?) ?? const [1, 3, 5]).join(',')),
              sessionMinutes: Value(_i(p['sessionMinutes']) ?? 60),
              includeCore: Value(p['includeCore'] as bool? ?? true),
              heightCm: Value(_d(p['heightCm'])),
              birthYear: Value(_i(p['birthYear'])),
              injuries: Value(p['injuries'] as String? ?? ''),
              notes: Value(p['notes'] as String? ?? ''),
              restMode: Value(p['restMode'] as String? ?? 'normal'),
              cooldownStretches: Value(_i(p['cooldownStretches']) ?? 3),
              barWeightsJson: Value(p['barWeights'] is Map ? jsonEncode(p['barWeights']) : '{}'),
              muscleFocusJson: Value(p['muscleFocus'] is Map ? jsonEncode(p['muscleFocus']) : '{}'),
              updatedAt: _dt(p['updatedAt']),
              deleted: Value(p['deleted'] as bool? ?? false),
              dirty: const Value(false),
            ));
        n++;
      }
    }

    for (final r in (changes['equipment'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = r['equipmentId'] as String;
      final local = await (db.select(db.equipmentStatuses)..where((t) => t.equipmentId.equals(id))).getSingleOrNull();
      if (keepLocal(local?.dirty, local?.updatedAt, _dt(r['updatedAt']))) continue;
      await db.into(db.equipmentStatuses).insertOnConflictUpdate(EquipmentStatusesCompanion.insert(
            equipmentId: id,
            available: r['available'] as bool? ?? true,
            updatedAt: _dt(r['updatedAt']),
            deleted: Value(r['deleted'] as bool? ?? false),
            dirty: const Value(false),
          ));
      n++;
    }

    for (final r in (changes['exercisePreferences'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = r['exerciseId'] as String;
      final local = await (db.select(db.exercisePreferences)..where((t) => t.exerciseId.equals(id))).getSingleOrNull();
      if (keepLocal(local?.dirty, local?.updatedAt, _dt(r['updatedAt']))) continue;
      await db.into(db.exercisePreferences).insertOnConflictUpdate(ExercisePreferencesCompanion.insert(
            exerciseId: id,
            preference: r['preference'] as String? ?? 'neutral',
            note: Value(r['note'] as String? ?? ''),
            updatedAt: _dt(r['updatedAt']),
            deleted: Value(r['deleted'] as bool? ?? false),
            dirty: const Value(false),
          ));
      n++;
    }

    for (final r in (changes['plannedWorkouts'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = r['id'] as String;
      final local = await (db.select(db.plannedWorkouts)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (keepLocal(local?.dirty, local?.updatedAt, _dt(r['updatedAt']))) continue;
      await db.into(db.plannedWorkouts).insertOnConflictUpdate(plannedFromJson(r));
      n++;
    }

    for (final r in (changes['sessions'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = r['id'] as String;
      final local = await (db.select(db.workoutSessions)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (keepLocal(local?.dirty, local?.updatedAt, _dt(r['updatedAt']))) continue;
      await db.into(db.workoutSessions).insertOnConflictUpdate(WorkoutSessionsCompanion.insert(
            id: id,
            plannedWorkoutId: Value(r['plannedWorkoutId'] as String?),
            dayType: r['dayType'] as String? ?? 'push',
            title: r['title'] as String? ?? 'Workout',
            startedAt: _dt(r['startedAt']),
            endedAt: Value(_dtn(r['endedAt'])),
            durationSeconds: Value(_i(r['durationSeconds'])),
            rating: Value(_i(r['rating'])),
            perceivedEffort: Value(_i(r['perceivedEffort'])),
            notes: Value(r['notes'] as String? ?? ''),
            updatedAt: _dt(r['updatedAt']),
            deleted: Value(r['deleted'] as bool? ?? false),
            dirty: const Value(false),
          ));
      n++;
    }

    for (final r in (changes['sets'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = r['id'] as String;
      final local = await (db.select(db.setLogs)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (keepLocal(local?.dirty, local?.updatedAt, _dt(r['updatedAt']))) continue;
      await db.into(db.setLogs).insertOnConflictUpdate(SetLogsCompanion.insert(
            id: id,
            sessionId: r['sessionId'] as String,
            exerciseId: r['exerciseId'] as String,
            section: r['section'] as String? ?? 'main',
            exerciseOrder: _i(r['exerciseOrder']) ?? 0,
            setNumber: _i(r['setNumber']) ?? 1,
            weightKg: Value(_d(r['weightKg'])),
            reps: Value(_i(r['reps'])),
            durationSeconds: Value(_i(r['durationSeconds'])),
            rir: Value(_i(r['rir'])),
            completed: Value(r['completed'] as bool? ?? false),
            completedAt: Value(_dtn(r['completedAt'])),
            updatedAt: _dt(r['updatedAt']),
            deleted: Value(r['deleted'] as bool? ?? false),
            dirty: const Value(false),
          ));
      n++;
    }

    for (final r in (changes['bodyMetrics'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = r['id'] as String;
      final local = await (db.select(db.bodyMetrics)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (keepLocal(local?.dirty, local?.updatedAt, _dt(r['updatedAt']))) continue;
      await db.into(db.bodyMetrics).insertOnConflictUpdate(BodyMetricsCompanion.insert(
            id: id,
            date: r['date'] as String,
            weightKg: Value(_d(r['weightKg'])),
            bodyFatPct: Value(_d(r['bodyFatPct'])),
            waistCm: Value(_d(r['waistCm'])),
            chestCm: Value(_d(r['chestCm'])),
            armCm: Value(_d(r['armCm'])),
            thighCm: Value(_d(r['thighCm'])),
            hipsCm: Value(_d(r['hipsCm'])),
            notes: Value(r['notes'] as String? ?? ''),
            updatedAt: _dt(r['updatedAt']),
            deleted: Value(r['deleted'] as bool? ?? false),
            dirty: const Value(false),
          ));
      n++;
    }

    for (final r in (changes['feedbackEntries'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final id = r['id'] as String;
      final local = await (db.select(db.feedbackEntries)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (keepLocal(local?.dirty, local?.updatedAt, _dt(r['updatedAt']))) continue;
      await db.into(db.feedbackEntries).insertOnConflictUpdate(feedbackFromJson(r));
      n++;
    }
    return n;
  }
}

// ---------------- JSON mappers (contract: docs/API.md) ----------------
Map<String, dynamic> profileToJson(Profile p) => {
      'id': 'me',
      'name': p.name,
      'experience': p.experience,
      'goals': p.goals,
      'trainingDays': p.trainingDays.split(',').where((s) => s.isNotEmpty).map(int.parse).toList(),
      'sessionMinutes': p.sessionMinutes,
      'includeCore': p.includeCore,
      'heightCm': p.heightCm,
      'birthYear': p.birthYear,
      'injuries': p.injuries,
      'notes': p.notes,
      'restMode': p.restMode,
      'cooldownStretches': p.cooldownStretches,
      'barWeights': LoadModel.parseOverrides(p.barWeightsJson),
      'muscleFocus': MuscleFocus.decode(p.muscleFocusJson).toJson(),
      'updatedAt': _iso(p.updatedAt),
      'deleted': p.deleted,
    };

Map<String, dynamic> equipmentToJson(EquipmentStatus e) => {
      'equipmentId': e.equipmentId,
      'available': e.available,
      'updatedAt': _iso(e.updatedAt),
      'deleted': e.deleted,
    };

Map<String, dynamic> preferenceToJson(ExercisePreference e) => {
      'exerciseId': e.exerciseId,
      'preference': e.preference,
      'note': e.note,
      'updatedAt': _iso(e.updatedAt),
      'deleted': e.deleted,
    };

Map<String, dynamic> plannedToJson(PlannedWorkout p) => {
      'id': p.id,
      'date': p.date,
      'dayType': p.dayType,
      'title': p.title,
      'source': p.source,
      'status': p.status,
      'estimatedMinutes': p.estimatedMinutes,
      'coachNote': p.coachNote,
      'blocks': jsonDecode(p.blocksJson),
      'metaJson': p.metaJson,
      'updatedAt': _iso(p.updatedAt),
      'deleted': p.deleted,
    };

/// `metaJson` travels as a JSON string; an object is tolerated and re-encoded.
String _metaJson(dynamic v) => switch (v) {
      final String s when s.trim().isNotEmpty => s,
      final Map<String, dynamic> m => jsonEncode(m),
      _ => '{}',
    };

PlannedWorkoutsCompanion plannedFromJson(Map<String, dynamic> r, {bool dirty = false}) =>
    PlannedWorkoutsCompanion.insert(
      id: r['id'] as String,
      date: r['date'] as String,
      dayType: r['dayType'] as String? ?? 'push',
      title: r['title'] as String? ?? 'Workout',
      source: r['source'] as String? ?? 'ai',
      status: Value(r['status'] as String? ?? 'planned'),
      estimatedMinutes: Value(_i(r['estimatedMinutes']) ?? 60),
      coachNote: Value(r['coachNote'] as String? ?? ''),
      blocksJson: jsonEncode(r['blocks'] ?? const []),
      // Absent key (older backend) keeps the local value instead of wiping it.
      metaJson: r.containsKey('metaJson') ? Value(_metaJson(r['metaJson'])) : const Value.absent(),
      updatedAt: r['updatedAt'] == null ? DateTime.now().toUtc() : _dt(r['updatedAt']),
      deleted: Value(r['deleted'] as bool? ?? false),
      dirty: Value(dirty),
    );

Map<String, dynamic> sessionToJson(WorkoutSession s) => {
      'id': s.id,
      'plannedWorkoutId': s.plannedWorkoutId,
      'dayType': s.dayType,
      'title': s.title,
      'startedAt': _iso(s.startedAt),
      'endedAt': s.endedAt == null ? null : _iso(s.endedAt!),
      'durationSeconds': s.durationSeconds,
      'rating': s.rating,
      'perceivedEffort': s.perceivedEffort,
      'notes': s.notes,
      'updatedAt': _iso(s.updatedAt),
      'deleted': s.deleted,
    };

Map<String, dynamic> setToJson(SetLog s) => {
      'id': s.id,
      'sessionId': s.sessionId,
      'exerciseId': s.exerciseId,
      'section': s.section,
      'exerciseOrder': s.exerciseOrder,
      'setNumber': s.setNumber,
      'weightKg': s.weightKg,
      'reps': s.reps,
      'durationSeconds': s.durationSeconds,
      'rir': s.rir,
      'completed': s.completed,
      'completedAt': s.completedAt == null ? null : _iso(s.completedAt!),
      'updatedAt': _iso(s.updatedAt),
      'deleted': s.deleted,
    };

Map<String, dynamic> bodyToJson(BodyMetric b) => {
      'id': b.id,
      'date': b.date,
      'weightKg': b.weightKg,
      'bodyFatPct': b.bodyFatPct,
      'waistCm': b.waistCm,
      'chestCm': b.chestCm,
      'armCm': b.armCm,
      'thighCm': b.thighCm,
      'hipsCm': b.hipsCm,
      'notes': b.notes,
      'updatedAt': _iso(b.updatedAt),
      'deleted': b.deleted,
    };

Map<String, dynamic> feedbackToJson(FeedbackEntry f) => {
      'id': f.id,
      'createdAt': _iso(f.createdAt),
      'kind': f.kind,
      'region': f.region,
      'severity': f.severity,
      'exerciseId': f.exerciseId,
      'sessionId': f.sessionId,
      'note': f.note,
      'status': f.status,
      'reviewOn': f.reviewOn,
      'resolvedAt': f.resolvedAt == null ? null : _iso(f.resolvedAt!),
      'source': f.source,
      'updatedAt': _iso(f.updatedAt),
      'deleted': f.deleted,
    };

FeedbackEntriesCompanion feedbackFromJson(Map<String, dynamic> r, {bool dirty = false}) =>
    FeedbackEntriesCompanion.insert(
      id: r['id'] as String,
      createdAt: r['createdAt'] == null ? _dt(r['updatedAt']) : _dt(r['createdAt']),
      kind: r['kind'] as String? ?? 'note',
      region: Value(r['region'] as String?),
      severity: Value(_i(r['severity'])),
      exerciseId: Value(r['exerciseId'] as String?),
      sessionId: Value(r['sessionId'] as String?),
      note: Value(r['note'] as String? ?? ''),
      status: Value(r['status'] as String? ?? 'active'),
      reviewOn: Value(_dateOnly(r['reviewOn'])),
      resolvedAt: Value(_dtn(r['resolvedAt'])),
      source: Value(r['source'] as String? ?? 'user'),
      updatedAt: _dt(r['updatedAt']),
      deleted: Value(r['deleted'] as bool? ?? false),
      dirty: Value(dirty),
    );

/// Normalises a date (`yyyy-MM-dd`, possibly sent with a time part) to `yyyy-MM-dd`.
String? _dateOnly(dynamic v) {
  final s = v as String?;
  if (s == null || s.isEmpty) return null;
  return s.length > 10 ? s.substring(0, 10) : s;
}
