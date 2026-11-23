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

/// Platform boundary to Health Connect (faked in tests).
abstract class HealthBridge {
  Future<HealthAvailability> availability();
  Future<void> install();
  Future<bool> hasAccess();

  /// Shows Health Connect's permission dialog; true when every permission was granted.
  Future<bool> requestAccess();

  /// Writes a strength-training session; true when Health Connect accepted it. [id] makes a rewrite replace the earlier
  /// record instead of adding a copy, and a higher [version] makes it count as updated.
  Future<bool> writeWorkout({
    required String id,
    required DateTime start,
    required DateTime end,
    required String title,
    required int version,
  });

  /// Heart-rate samples between [start] and [end], from any source (e.g. Samsung Health / Galaxy Watch).
  Future<List<HeartRateSample>> heartRate(DateTime start, DateTime end);
}

/// [HealthBridge] backed by the `health` plugin (Google Health Connect).
class HealthConnectBridge implements HealthBridge {
  HealthConnectBridge();

  final _health = Health();
  bool _configured = false;

  static const _types = [HealthDataType.WORKOUT, HealthDataType.HEART_RATE];
  static const _access = [HealthDataAccess.READ_WRITE, HealthDataAccess.READ];

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
  Future<bool> requestAccess() async => (await _ready()).requestAuthorization(_types, permissions: _access);

  @override
  Future<bool> writeWorkout({
    required String id,
    required DateTime start,
    required DateTime end,
    required String title,
    required int version,
  }) async {
    final health = await _ready();
    Future<bool> write(HealthWorkoutActivityType type) => health.writeWorkoutData(
          activityType: type,
          start: start,
          end: end,
          title: title,
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

/// Outcome of a Health Connect pass: sessions that changed, and workouts Health Connect did not accept.
class HealthSyncResult {
  const HealthSyncResult({this.changed = 0, this.failed = 0, this.unavailable = false});

  final int changed;
  final int failed;

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

  /// Writes [s] to Health Connect; true when accepted. [again] writes it as an updated record: the copy already there is
  /// replaced and apps that import from Health Connect see a new change.
  Future<bool> _export(WorkoutSession s, {bool again = false}) async {
    final end = s.endedAt;
    if (end == null) return false;
    try {
      final ok = await bridge.writeWorkout(
        id: s.id,
        start: s.startedAt,
        end: end,
        title: s.title,
        version: again ? DateTime.now().millisecondsSinceEpoch : 1,
      );
      if (ok) await repo.markHealthExported(s.id);
      return ok;
    } catch (e) {
      debugPrint('Health Connect: workout ${s.id} not saved ($e)');
      return false;
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
  /// [onResult] reports every workout as it is done. Never throws.
  Future<HealthSyncResult> send(
    Iterable<WorkoutSession> sessions, {
    void Function(String sessionId, bool saved)? onResult,
  }) async {
    try {
      if (!await isEnabled() || !await _usable()) return const HealthSyncResult(unavailable: true);
      var changed = 0, failed = 0;
      for (final s in sessions) {
        final saved = await _export(s, again: true);
        saved ? changed++ : failed++;
        onResult?.call(s.id, saved);
        await _readHeartRate(s);
      }
      return HealthSyncResult(changed: changed, failed: failed);
    } catch (e) {
      debugPrint('Health Connect unavailable: $e');
      return const HealthSyncResult(unavailable: true);
    }
  }

  /// Saves recent sessions that were not exported yet and fills missing heart rates (after a workout, on app start /
  /// resume). Never throws.
  Future<HealthSyncResult> catchUp({DateTime? now}) async {
    try {
      if (!await isEnabled() || !await _usable()) return const HealthSyncResult(unavailable: true);
      final since = (now ?? DateTime.now()).toUtc().subtract(const Duration(days: retryDays));
      var changed = 0, failed = 0;
      for (final s in await repo.sessionsForHealth(since)) {
        var exported = false;
        if (s.healthExportedAt == null) {
          exported = await _export(s);
          if (!exported) failed++;
        }
        final heartRate = await _readHeartRate(s);
        if (exported || heartRate) changed++;
      }
      return HealthSyncResult(changed: changed, failed: failed);
    } catch (e) {
      debugPrint('Health Connect unavailable: $e');
      return const HealthSyncResult(unavailable: true);
    }
  }
}
