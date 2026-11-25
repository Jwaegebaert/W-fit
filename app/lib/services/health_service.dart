import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';

import '../data/db/database.dart';
import '../data/repositories/repository.dart';

/// Whether Health Connect can be used on this phone.
enum HealthAvailability {
  available,

  /// Installed, but the Health Connect app needs an update first (Android 13 and lower).
  needsUpdate,

  /// Not installed (Android 13 and lower; built into Android 14+).
  notInstalled,

  /// Not Android, or Health Connect is unavailable on this device.
  unsupported,
}

/// One heart-rate reading from Health Connect.
typedef HeartRateSample = ({DateTime time, double bpm});

/// A workout another app wrote to Health Connect. [cardio]: a type watches detect by themselves (walking, running,
/// cycling, …), which says nothing about a gym session at the same time.
typedef OtherWorkout = ({String app, DateTime start, DateTime end, bool cardio});

/// Platform boundary to Health Connect (faked in tests).
abstract class HealthBridge {
  Future<HealthAvailability> availability();
  Future<void> install();
  Future<bool> hasAccess();

  /// Shows Health Connect's permission dialog; true when workouts and heart rate are allowed afterwards (the calories
  /// permission is optional).
  Future<bool> requestAccess();

  /// Whether the estimated calories of a workout may be written.
  Future<bool> canWriteCalories();

  /// Writes a strength-training session; true when Health Connect accepted it. [id] makes a rewrite replace the earlier
  /// record instead of adding a copy, and a higher [version] makes it count as updated.
  Future<bool> writeWorkout({
    required String id,
    required DateTime start,
    required DateTime end,
    required String title,
    required int version,
    int? calories,
  });

  /// Removes the workout this app wrote with [id] (never another app's).
  Future<bool> deleteWorkout(String id);

  /// Workouts of other apps that start between [start] and [end].
  Future<List<OtherWorkout>> otherWorkouts(DateTime start, DateTime end);

  /// Heart-rate samples between [start] and [end], from any source (e.g. Samsung Health / Galaxy Watch).
  Future<List<HeartRateSample>> heartRate(DateTime start, DateTime end);
}

/// [HealthBridge] backed by the `health` plugin (Google Health Connect).
class HealthConnectBridge implements HealthBridge {
  HealthConnectBridge();

  final _health = Health();
  bool _configured = false;

  static const _package = 'com.jwaegebaert.wfit';
  static const _types = [HealthDataType.WORKOUT, HealthDataType.HEART_RATE];
  static const _access = [HealthDataAccess.READ_WRITE, HealthDataAccess.READ];
  static const _cardio = {
    HealthWorkoutActivityType.WALKING,
    HealthWorkoutActivityType.WALKING_TREADMILL,
    HealthWorkoutActivityType.RUNNING,
    HealthWorkoutActivityType.RUNNING_TREADMILL,
    HealthWorkoutActivityType.HIKING,
    HealthWorkoutActivityType.BIKING,
    HealthWorkoutActivityType.BIKING_STATIONARY,
    HealthWorkoutActivityType.ELLIPTICAL,
    HealthWorkoutActivityType.ROWING,
    HealthWorkoutActivityType.ROWING_MACHINE,
    HealthWorkoutActivityType.STAIR_CLIMBING,
    HealthWorkoutActivityType.STAIR_CLIMBING_MACHINE,
    HealthWorkoutActivityType.SWIMMING,
    HealthWorkoutActivityType.SWIMMING_POOL,
    HealthWorkoutActivityType.SWIMMING_OPEN_WATER,
  };

  Future<Health> _ready() async {
    if (!_configured) {
      await _health.configure();
      _configured = true;
    }
    return _health;
  }

  @override
  Future<HealthAvailability> availability() async {
    if (kIsWeb || !Platform.isAndroid) return HealthAvailability.unsupported;
    try {
      return switch (await (await _ready()).getHealthConnectSdkStatus()) {
        HealthConnectSdkStatus.sdkAvailable => HealthAvailability.available,
        HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired => HealthAvailability.needsUpdate,
        HealthConnectSdkStatus.sdkUnavailable => HealthAvailability.notInstalled,
        null => HealthAvailability.unsupported,
      };
    } catch (_) {
      return HealthAvailability.unsupported;
    }
  }

  @override
  Future<void> install() async => (await _ready()).installHealthConnect();

  @override
  Future<bool> hasAccess() async => await (await _ready()).hasPermissions(_types, permissions: _access) ?? false;

  @override
  Future<bool> requestAccess() async {
    await (await _ready()).requestAuthorization(
      const [..._types, HealthDataType.TOTAL_CALORIES_BURNED],
      permissions: const [..._access, HealthDataAccess.WRITE],
    );
    return hasAccess(); // the dialog's own answer is false when only the optional calories were refused
  }

  @override
  Future<bool> canWriteCalories() async =>
      await (await _ready()).hasPermissions(const [HealthDataType.TOTAL_CALORIES_BURNED],
          permissions: const [HealthDataAccess.WRITE]) ??
      false;

  @override
  Future<bool> deleteWorkout(String id) async {
    final health = await _ready();
    if (await canWriteCalories()) {
      await health.deleteByClientRecordId(
          dataTypeKey: HealthDataType.TOTAL_CALORIES_BURNED, clientRecordId: 'wfit-$id:calories');
    }
    return health.deleteByClientRecordId(dataTypeKey: HealthDataType.WORKOUT, clientRecordId: 'wfit-$id');
  }

  @override
  Future<List<OtherWorkout>> otherWorkouts(DateTime start, DateTime end) async {
    final points = await (await _ready())
        .getHealthDataFromTypes(types: const [HealthDataType.WORKOUT], startTime: start, endTime: end);
    return [
      for (final p in points)
        if (p.value case WorkoutHealthValue(:final workoutActivityType) when p.sourceName != _package)
          (app: p.sourceName, start: p.dateFrom, end: p.dateTo, cardio: _cardio.contains(workoutActivityType)),
    ];
  }

  @override
  Future<bool> writeWorkout({
    required String id,
    required DateTime start,
    required DateTime end,
    required String title,
    required int version,
    int? calories,
  }) async {
    final health = await _ready();
    Future<bool> write(HealthWorkoutActivityType type) => health.writeWorkoutData(
          activityType: type,
          start: start,
          end: end,
          title: title,
          totalEnergyBurned: calories,
          recordingMethod: RecordingMethod.manual,
          clientRecordId: 'wfit-$id',
          clientRecordVersion: version.toDouble(),
          startZoneOffset: start.toLocal().timeZoneOffset,
          endZoneOffset: end.toLocal().timeZoneOffset,
        );
    try {
      return await write(HealthWorkoutActivityType.STRENGTH_TRAINING);
    } on HealthException catch (e) {
      if (e.errorCode != HealthErrorCode.notSupported) rethrow;
      return write(HealthWorkoutActivityType.WEIGHTLIFTING); // no strength training on this platform
    }
  }

  @override
  Future<List<HeartRateSample>> heartRate(DateTime start, DateTime end) async {
    final points = await (await _ready())
        .getHealthDataFromTypes(types: const [HealthDataType.HEART_RATE], startTime: start, endTime: end);
    return [
      for (final p in points)
        if (p.value case NumericHealthValue(:final numericValue)) (time: p.dateFrom, bpm: numericValue.toDouble()),
    ];
  }
}

/// Average and maximum heart rate of a session.
class HeartRateSummary {
  const HeartRateSummary(this.avg, this.max, this.samples);

  final int avg;
  final int max;
  final int samples;
}

/// What happened to one workout: in Health Connect, left to the app that recorded it too, or not accepted.
enum HealthOutcome { saved, covered, failed }

/// Outcome of a Health Connect pass: sessions that changed, and workouts Health Connect did not accept.
class HealthSyncResult {
  const HealthSyncResult({this.changed = 0, this.failed = 0, this.covered = 0, this.unavailable = false});

  final int changed;
  final int failed;

  /// Workouts left out because another app (the watch) recorded them.
  final int covered;

  /// Health Connect could not be used (not enabled, not available or no access): nothing was tried.
  final bool unavailable;
}

/// Saves finished workouts to Health Connect (Samsung Health can import them) and reads the watch's heart rate
/// for each session. Opt-in (Settings → Samsung Health); does nothing until enabled and granted. Never throws.
class HealthSync {
  HealthSync(this.repo, this.bridge);

  final Repository repo;
  final HealthBridge bridge;

  static const enabledKey = 'health_connect_enabled';

  /// Sessions this recent are retried: Samsung Health may sync the watch's heart rate to Health Connect later.
  static const retryDays = 3;

  /// Fewer samples than this are not a usable workout heart rate.
  static const minSamples = 3;

  Future<bool> isEnabled() async => await repo.db.getValue(enabledKey) == '1';

  Future<void> setEnabled(bool on) => repo.db.setValue(enabledKey, on ? '1' : '0');

  /// Average / max of plausible readings (30–230 bpm); null when there are too few.
  static HeartRateSummary? summarize(Iterable<HeartRateSample> samples) {
    final bpm = [for (final s in samples) if (s.bpm >= 30 && s.bpm <= 230) s.bpm];
    if (bpm.length < minSamples) return null;
    final avg = bpm.reduce((a, b) => a + b) / bpm.length;
    return HeartRateSummary(avg.round(), bpm.reduce((a, b) => a > b ? a : b).round(), bpm.length);
  }

  /// Share of the workout another app must have recorded before it counts as the same workout.
  static const minCover = 0.5;

  /// Moderate resistance training (2011 Compendium of Physical Activities); includes resting energy.
  static const _met = 3.5;

  static String _coveredKey(String sessionId) => 'health_covered_$sessionId';

  /// The app (package name) that also recorded [sessionId], when that was found; null otherwise.
  Future<String?> coveredApp(String sessionId) async {
    final v = await repo.db.getValue(_coveredKey(sessionId));
    return v == null || v.isEmpty ? null : v;
  }

  /// The app that recorded at least [minCover] of [start]–[end], if any. Ignored: cardio a watch detects by itself, and
  /// an exact copy of our own workout (an app that imported it and published it again).
  static String? coveringApp(Iterable<OtherWorkout> others, DateTime start, DateTime end) {
    const exact = Duration(seconds: 2);
    final byApp = <String, int>{};
    for (final o in others) {
      final copy = o.start.difference(start).abs() <= exact && o.end.difference(end).abs() <= exact;
      if (o.cardio || copy) continue;
      final from = o.start.isAfter(start) ? o.start : start;
      final to = o.end.isBefore(end) ? o.end : end;
      final overlap = to.difference(from).inSeconds;
      if (overlap > 0) byApp[o.app] = (byApp[o.app] ?? 0) + overlap;
    }
    final needed = end.difference(start).inSeconds * minCover;
    String? best;
    for (final e in byApp.entries) {
      if (e.value >= needed && (best == null || e.value > byApp[best]!)) best = e.key;
    }
    return best;
  }

  /// Estimated energy of a strength workout in kcal; null without a body weight or for an implausible duration.
  static int? estimateCalories(Duration duration, double? bodyWeightKg) {
    final minutes = duration.inMinutes;
    if (bodyWeightKg == null || bodyWeightKg <= 0 || minutes < 5 || minutes > 240) return null;
    return (_met * bodyWeightKg * minutes / 60).round();
  }

  /// Brings Health Connect in line for [s]: leaves the workout to another app that recorded it (removing our own copy),
  /// otherwise writes it once. [again] writes it as an updated record: the copy already there is replaced and apps that
  /// import from Health Connect see a new change. Null when nothing had to be done.
  Future<HealthOutcome?> _export(WorkoutSession s, {bool again = false}) async {
    final end = s.endedAt;
    if (end == null) return null;
    try {
      final known = await coveredApp(s.id);
      String? app;
      try {
        // Read a wider window: Health Connect finds workouts by their start time.
        app = coveringApp(
          await bridge.otherWorkouts(
              s.startedAt.subtract(const Duration(hours: 6)), end.add(const Duration(hours: 1))),
          s.startedAt,
          end,
        );
      } catch (e) {
        debugPrint('Health Connect: other workouts not readable ($e)');
        app = known; // don't add a duplicate because of a failed read
      }
      if (app != null) {
        if (s.healthExportedAt != null) {
          if (!await bridge.deleteWorkout(s.id)) return HealthOutcome.failed;
          await repo.clearHealthExported(s.id);
        }
        await repo.db.setValue(_coveredKey(s.id), app);
        return again || known == null || s.healthExportedAt != null ? HealthOutcome.covered : null;
      }
      if (known != null) await repo.db.setValue(_coveredKey(s.id), '');
      if (s.healthExportedAt != null && !again) return null;
      final ok = await bridge.writeWorkout(
        id: s.id,
        start: s.startedAt,
        end: end,
        title: s.title,
        version: again ? DateTime.now().millisecondsSinceEpoch : 1,
        calories: await bridge.canWriteCalories()
            ? estimateCalories(end.difference(s.startedAt), await repo.latestBodyWeight())
            : null,
      );
      if (ok) await repo.markHealthExported(s.id);
      return ok ? HealthOutcome.saved : HealthOutcome.failed;
    } catch (e) {
      debugPrint('Health Connect: workout ${s.id} not saved ($e)');
      return HealthOutcome.failed;
    }
  }

  /// Fills the heart rate of [s] when Health Connect has enough readings; true when it changed.
  Future<bool> _readHeartRate(WorkoutSession s) async {
    final end = s.endedAt;
    if (end == null || s.avgHeartRate != null) return false;
    try {
      final hr = summarize(await bridge.heartRate(s.startedAt, end));
      if (hr == null) return false;
      await repo.setSessionHeartRate(s.id, avg: hr.avg, max: hr.max);
      return true;
    } catch (e) {
      debugPrint('Health Connect: no heart rate for ${s.id} ($e)');
      return false;
    }
  }

  Future<bool> _usable() async =>
      await bridge.availability() == HealthAvailability.available && await bridge.hasAccess();

  /// Writes the chosen [sessions] to Health Connect, also when they were sent before, and looks for their heart rate.
  /// Workouts another app recorded are left out. [onResult] reports every workout as it is done. Never throws.
  Future<HealthSyncResult> send(
    Iterable<WorkoutSession> sessions, {
    void Function(String sessionId, HealthOutcome outcome)? onResult,
  }) async {
    try {
      if (!await isEnabled() || !await _usable()) return const HealthSyncResult(unavailable: true);
      var changed = 0, failed = 0, covered = 0;
      for (final s in sessions) {
        final outcome = await _export(s, again: true) ?? HealthOutcome.failed;
        switch (outcome) {
          case HealthOutcome.saved:
            changed++;
          case HealthOutcome.covered:
            covered++;
          case HealthOutcome.failed:
            failed++;
        }
        onResult?.call(s.id, outcome);
        await _readHeartRate(s);
      }
      return HealthSyncResult(changed: changed, failed: failed, covered: covered);
    } catch (e) {
      debugPrint('Health Connect unavailable: $e');
      return const HealthSyncResult(unavailable: true);
    }
  }

  /// Saves recent sessions that were not exported yet, removes ones the watch turns out to have recorded (its workout can
  /// arrive later) and fills missing heart rates (after a workout, on app start / resume). Never throws.
  Future<HealthSyncResult> catchUp({DateTime? now}) async {
    try {
      if (!await isEnabled() || !await _usable()) return const HealthSyncResult(unavailable: true);
      final since = (now ?? DateTime.now()).toUtc().subtract(const Duration(days: retryDays));
      var changed = 0, failed = 0, covered = 0;
      for (final s in await repo.sessionsForHealth(since)) {
        final outcome = await _export(s);
        if (outcome == HealthOutcome.failed) failed++;
        if (outcome == HealthOutcome.covered) covered++;
        final heartRate = await _readHeartRate(s);
        if (outcome == HealthOutcome.saved || heartRate) changed++;
      }
      return HealthSyncResult(changed: changed, failed: failed, covered: covered);
    } catch (e) {
      debugPrint('Health Connect unavailable: $e');
      return const HealthSyncResult(unavailable: true);
    }
  }
}
