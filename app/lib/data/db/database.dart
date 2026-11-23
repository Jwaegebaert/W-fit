import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// Columns shared by every synced table.
mixin SyncColumns on Table {
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
}

class Profiles extends Table with SyncColumns {
  TextColumn get id => text().withDefault(const Constant('me'))();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get experience => text().withDefault(const Constant('beginner'))();
  TextColumn get goals => text().withDefault(const Constant(''))();
  TextColumn get trainingDays => text().withDefault(const Constant('1,3,5'))();
  IntColumn get sessionMinutes => integer().withDefault(const Constant(60))();
  BoolColumn get includeCore => boolean().withDefault(const Constant(true))();
  RealColumn get heightCm => real().nullable()();
  IntColumn get birthYear => integer().nullable()();
  TextColumn get injuries => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();

  /// Rest between sets: short | normal | long (see `restScaleFor`); added in schema v3.
  TextColumn get restMode => text().withDefault(const Constant('normal'))();

  /// Stretches in the cool-down, 0–3 (0 = no cool-down); added in schema v3.
  IntColumn get cooldownStretches => integer().withDefault(const Constant(3))();

  /// Empty-bar weights set by the user as JSON ({"smith_machine": 15}); added in schema v3.
  TextColumn get barWeightsJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('EquipmentStatus')
class EquipmentStatuses extends Table with SyncColumns {
  TextColumn get equipmentId => text()();
  BoolColumn get available => boolean()();

  @override
  Set<Column> get primaryKey => {equipmentId};
}

class ExercisePreferences extends Table with SyncColumns {
  TextColumn get exerciseId => text()();
  TextColumn get preference => text()();
  TextColumn get note => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {exerciseId};
}

class PlannedWorkouts extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get date => text()();
  TextColumn get dayType => text()();
  TextColumn get title => text()();
  TextColumn get source => text()();
  TextColumn get status => text().withDefault(const Constant('planned'))();
  IntColumn get estimatedMinutes => integer().withDefault(const Constant(60))();
  TextColumn get coachNote => text().withDefault(const Constant(''))();
  TextColumn get blocksJson => text()();

  /// Plan metadata (program position, variant, focus, rationale, changes) as a JSON object; added in schema v2.
  TextColumn get metaJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {id};
}

class WorkoutSessions extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get plannedWorkoutId => text().nullable()();
  TextColumn get dayType => text()();
  TextColumn get title => text()();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  IntColumn get rating => integer().nullable()();
  IntColumn get perceivedEffort => integer().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

class SetLogs extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get exerciseId => text()();
  TextColumn get section => text()();
  IntColumn get exerciseOrder => integer()();
  IntColumn get setNumber => integer()();
  RealColumn get weightKg => real().nullable()();
  IntColumn get reps => integer().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  IntColumn get rir => integer().nullable()();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
  DateTimeColumn get completedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class BodyMetrics extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get date => text()();
  RealColumn get weightKg => real().nullable()();
  RealColumn get bodyFatPct => real().nullable()();
  RealColumn get waistCm => real().nullable()();
  RealColumn get chestCm => real().nullable()();
  RealColumn get armCm => real().nullable()();
  RealColumn get thighCm => real().nullable()();
  RealColumn get hipsCm => real().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Feedback memory (pain, discomfort, exercise feedback, check-ins); see docs/IMPROVEMENT-PLAN.md §4.3.
@DataClassName('FeedbackEntry')
class FeedbackEntries extends Table with SyncColumns {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();

  /// pain | discomfort | too_easy | too_hard | unavailable | dislike | like | note
  TextColumn get kind => text()();
  TextColumn get region => text().nullable()();

  /// 1 mild, 2 moderate, 3 severe (pain/discomfort only).
  IntColumn get severity => integer().nullable()();
  TextColumn get exerciseId => text().nullable()();
  TextColumn get sessionId => text().nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();

  /// active | resolved
  TextColumn get status => text().withDefault(const Constant('active'))();

  /// yyyy-MM-dd; when the app asks "still an issue?".
  TextColumn get reviewOn => text().nullable()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();

  /// user | coach
  TextColumn get source => text().withDefault(const Constant('user'))();

  @override
  Set<Column> get primaryKey => {id};
}

class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [
  Profiles,
  EquipmentStatuses,
  ExercisePreferences,
  PlannedWorkouts,
  WorkoutSessions,
  SetLogs,
  BodyMetrics,
  FeedbackEntries,
  KeyValues,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  static QueryExecutor _open() => driftDatabase(name: 'wfit');

  /// v1: initial schema. v2: `feedback_entries` table and `planned_workouts.meta_json`.
  /// v3: profile `rest_mode`, `cooldown_stretches` and `bar_weights_json`.
  @override
  int get schemaVersion => 3;

  static final _feedbackStatusIndex = Index('idx_feedback_status',
      'CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback_entries (status, deleted)');

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await m.createIndex(Index('idx_sets_session', 'CREATE INDEX idx_sets_session ON set_logs (session_id)'));
          await m.createIndex(Index('idx_sets_exercise', 'CREATE INDEX idx_sets_exercise ON set_logs (exercise_id)'));
          await m.createIndex(Index('idx_planned_date', 'CREATE INDEX idx_planned_date ON planned_workouts (date)'));
          await m.createIndex(_feedbackStatusIndex);
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(feedbackEntries);
            await m.createIndex(_feedbackStatusIndex);
            await m.addColumn(plannedWorkouts, plannedWorkouts.metaJson);
          }
          if (from < 3) {
            await m.addColumn(profiles, profiles.restMode);
            await m.addColumn(profiles, profiles.cooldownStretches);
            await m.addColumn(profiles, profiles.barWeightsJson);
          }
        },
      );

  // ---------- key/value ----------
  Future<String?> getValue(String key) async =>
      (await (select(keyValues)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setValue(String key, String value) =>
      into(keyValues).insertOnConflictUpdate(KeyValue(key: key, value: value));
}
