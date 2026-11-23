import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';

/// Schema v1 exactly as drift created it (dumped from sqlite_master before the v2 change).
const _v1Schema = [
  '''CREATE TABLE "body_metrics" ("updated_at" INTEGER NOT NULL, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "id" TEXT NOT NULL, "date" TEXT NOT NULL, "weight_kg" REAL NULL, "body_fat_pct" REAL NULL, "waist_cm" REAL NULL, "chest_cm" REAL NULL, "arm_cm" REAL NULL, "thigh_cm" REAL NULL, "hips_cm" REAL NULL, "notes" TEXT NOT NULL DEFAULT '', PRIMARY KEY ("id"))''',
  '''CREATE TABLE "equipment_statuses" ("updated_at" INTEGER NOT NULL, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "equipment_id" TEXT NOT NULL, "available" INTEGER NOT NULL CHECK ("available" IN (0, 1)), PRIMARY KEY ("equipment_id"))''',
  '''CREATE TABLE "exercise_preferences" ("updated_at" INTEGER NOT NULL, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "exercise_id" TEXT NOT NULL, "preference" TEXT NOT NULL, "note" TEXT NOT NULL DEFAULT '', PRIMARY KEY ("exercise_id"))''',
  '''CREATE TABLE "key_values" ("key" TEXT NOT NULL, "value" TEXT NOT NULL, PRIMARY KEY ("key"))''',
  '''CREATE TABLE "planned_workouts" ("updated_at" INTEGER NOT NULL, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "id" TEXT NOT NULL, "date" TEXT NOT NULL, "day_type" TEXT NOT NULL, "title" TEXT NOT NULL, "source" TEXT NOT NULL, "status" TEXT NOT NULL DEFAULT 'planned', "estimated_minutes" INTEGER NOT NULL DEFAULT 60, "coach_note" TEXT NOT NULL DEFAULT '', "blocks_json" TEXT NOT NULL, PRIMARY KEY ("id"))''',
  '''CREATE TABLE "profiles" ("updated_at" INTEGER NOT NULL, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "id" TEXT NOT NULL DEFAULT 'me', "name" TEXT NOT NULL DEFAULT '', "experience" TEXT NOT NULL DEFAULT 'beginner', "goals" TEXT NOT NULL DEFAULT '', "training_days" TEXT NOT NULL DEFAULT '1,3,5', "session_minutes" INTEGER NOT NULL DEFAULT 60, "include_core" INTEGER NOT NULL DEFAULT 1 CHECK ("include_core" IN (0, 1)), "height_cm" REAL NULL, "birth_year" INTEGER NULL, "injuries" TEXT NOT NULL DEFAULT '', "notes" TEXT NOT NULL DEFAULT '', PRIMARY KEY ("id"))''',
  '''CREATE TABLE "set_logs" ("updated_at" INTEGER NOT NULL, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "id" TEXT NOT NULL, "session_id" TEXT NOT NULL, "exercise_id" TEXT NOT NULL, "section" TEXT NOT NULL, "exercise_order" INTEGER NOT NULL, "set_number" INTEGER NOT NULL, "weight_kg" REAL NULL, "reps" INTEGER NULL, "duration_seconds" INTEGER NULL, "rir" INTEGER NULL, "completed" INTEGER NOT NULL DEFAULT 0 CHECK ("completed" IN (0, 1)), "completed_at" INTEGER NULL, PRIMARY KEY ("id"))''',
  '''CREATE TABLE "workout_sessions" ("updated_at" INTEGER NOT NULL, "deleted" INTEGER NOT NULL DEFAULT 0 CHECK ("deleted" IN (0, 1)), "dirty" INTEGER NOT NULL DEFAULT 1 CHECK ("dirty" IN (0, 1)), "id" TEXT NOT NULL, "planned_workout_id" TEXT NULL, "day_type" TEXT NOT NULL, "title" TEXT NOT NULL, "started_at" INTEGER NOT NULL, "ended_at" INTEGER NULL, "duration_seconds" INTEGER NULL, "rating" INTEGER NULL, "perceived_effort" INTEGER NULL, "notes" TEXT NOT NULL DEFAULT '', PRIMARY KEY ("id"))''',
  'CREATE INDEX idx_planned_date ON planned_workouts (date)',
  'CREATE INDEX idx_sets_exercise ON set_logs (exercise_id)',
  'CREATE INDEX idx_sets_session ON set_logs (session_id)',
];

const _blocks =
    '[{"section":"main","items":[{"exerciseId":"leg-press","sets":3,"repMin":8,"repMax":12,"restSeconds":120}]}]';

/// A v1 database with representative data, as it exists on devices before the upgrade.
void _createV1(void Function(String sql) exec) {
  for (final sql in _v1Schema) {
    exec(sql);
  }
  const t = 1793750400; // 2026-11-04T00:00:00Z
  exec("INSERT INTO profiles (updated_at, dirty, name, injuries) VALUES ($t, 0, 'Alex', 'old knee')");
  exec("INSERT INTO equipment_statuses (updated_at, equipment_id, available) VALUES ($t, 'leg_press', 0)");
  exec("INSERT INTO exercise_preferences (updated_at, exercise_id, preference) VALUES ($t, 'push-up', 'disliked')");
  exec(
    'INSERT INTO planned_workouts (updated_at, dirty, id, date, day_type, title, source, status, blocks_json) '
    "VALUES ($t, 0, 'p1', '2026-11-04', 'legs', 'Legs', 'rules', 'completed', '$_blocks')",
  );
  exec(
    'INSERT INTO workout_sessions (updated_at, id, planned_workout_id, day_type, title, started_at, ended_at, '
    "rating) VALUES ($t, 's1', 'p1', 'legs', 'Legs', $t, ${t + 3600}, 4)",
  );
  exec(
    'INSERT INTO set_logs (updated_at, id, session_id, exercise_id, section, exercise_order, set_number, '
    "weight_kg, reps, rir, completed, completed_at) VALUES ($t, 'x1', 's1', 'leg-press', 'main', 0, 1, 100.0, 10, 2, 1, $t)",
  );
  exec("INSERT INTO body_metrics (updated_at, id, date, weight_kg) VALUES ($t, 'b1', '2026-11-04', 78.5)");
  exec("INSERT INTO key_values (key, value) VALUES ('sync_since', '2026-11-04T00:00:00Z')");
  exec('PRAGMA user_version = 1');
}

Future<List<Map<String, Object?>>> _tableInfo(AppDatabase db, String table) async =>
    (await db.customSelect('PRAGMA table_info("$table")').get()).map((r) => r.data).toList();

Future<Set<String>> _indexes(AppDatabase db) async =>
    (await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL").get())
        .map((r) => r.read<String>('name'))
        .toSet();

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('v1 -> v4 keeps all data and adds feedback_entries, planned_workouts.meta_json and profile settings', () async {
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) => _createV1(raw.execute)));
    addTearDown(db.close);
    final repo = Repository(db);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 4);
    await db.validateDatabaseSchema();

    // Existing data survives.
    final profile = await repo.getProfile();
    expect(profile.name, 'Alex');
    expect(profile.injuries, 'old knee');
    expect(profile.restMode, 'normal');
    expect(profile.cooldownStretches, 3);
    expect(profile.barWeightsJson, '{}');
    expect(profile.muscleFocusJson, '{}');
    expect(await repo.getEquipment(), {'leg_press': false});
    expect(await repo.getPreferences(), {'push-up': 'disliked'});
    final plan = (await repo.plannedById('p1'))!;
    expect(plan.status, 'completed');
    expect(plan.blocksJson, _blocks);
    expect(plan.metaJson, '{}');
    expect(Repository.decodeBlocks(plan.blocksJson).single.items.single.exerciseId, 'leg-press');
    final session = (await repo.sessionById('s1'))!;
    expect(session.rating, 4);
    final sets = await repo.setsForSession('s1');
    expect(sets.single.rir, 2);
    expect(sets.single.weightKg, 100.0);
    expect((await repo.loggedSets()).single.reps, 10);
    expect(await repo.latestBodyWeight(), 78.5);
    expect(await db.getValue('sync_since'), '2026-11-04T00:00:00Z');

    // New structures are usable.
    final fid = await repo.addFeedback(kind: 'pain', region: 'neck', severity: 2, note: 'stiff');
    expect((await repo.activeFeedback()).single.id, fid);
    await repo.updatePlannedMeta('p1', '{"variant":"A"}');
    expect((await repo.plannedById('p1'))!.metaJson, '{"variant":"A"}');

    expect(
      await _indexes(db),
      containsAll(['idx_sets_session', 'idx_sets_exercise', 'idx_planned_date', 'idx_feedback_status']),
    );
  });

  test('migrated schema matches a freshly created v4 database', () async {
    final migrated = AppDatabase(NativeDatabase.memory(setup: (raw) => _createV1(raw.execute)));
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(migrated.close);
    addTearDown(fresh.close);

    for (final table in fresh.allTables.map((t) => t.actualTableName)) {
      expect(await _tableInfo(migrated, table), await _tableInfo(fresh, table), reason: table);
    }
    expect(await _indexes(migrated), await _indexes(fresh));
    await fresh.validateDatabaseSchema();
  });
}
