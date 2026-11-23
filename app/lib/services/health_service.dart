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

  /// Writes a strength-training session. [id] makes rewrites replace instead of duplicate.
  Future<bool> writeWorkout({required String id, required DateTime start, required DateTime end, required String title});

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
  }) async {
    final health = await _ready();
    Future<bool> write(HealthWorkoutActivityType type) => health.writeWorkoutData(
          activityType: type,
          start: start,
          end: end,
          title: title,
          recordingMethod: RecordingMethod.manual,
          clientRecordId: 'wfit-$id',
          clientRecordVersion: 1,
          startZoneOffset: start.toLocal().timeZoneOffset,
          endZoneOffset: end.toLocal().timeZoneOffset,
        );
    try {
      return await write(HealthWorkoutActivityType.STRENGTH_TRAINING);
    } on HealthException {
      return write(HealthWorkoutActivityType.WEIGHTLIFTING); // older Health Connect without strength training
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

/// Saves finished workouts to Health Connect (so they appear in Samsung Health) and reads the watch's heart rate
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

  /// Exports [s] (once) and fills its heart rate when available. Returns true when something changed.
  Future<bool> process(WorkoutSession s) async {
    final end = s.endedAt;
    if (end == null) return false;
    var changed = false;
    if (s.healthExportedAt == null) {
      final ok = await bridge.writeWorkout(id: s.id, start: s.startedAt, end: end, title: s.title);
      if (ok) {
        await repo.markHealthExported(s.id);
        changed = true;
      }
    }
    if (s.avgHeartRate == null) {
      final hr = summarize(await bridge.heartRate(s.startedAt, end));
      if (hr != null) {
        await repo.setSessionHeartRate(s.id, avg: hr.avg, max: hr.max);
        changed = true;
      }
    }
    return changed;
  }

  /// Runs [process] for recent sessions that still miss an export or heart rate (after a workout, on app start /
  /// resume). Returns how many sessions changed.
  Future<int> catchUp({DateTime? now}) async {
    try {
      if (!await isEnabled()) return 0;
      if (await bridge.availability() != HealthAvailability.available || !await bridge.hasAccess()) return 0;
      final since = (now ?? DateTime.now()).toUtc().subtract(const Duration(days: retryDays));
      var n = 0;
      for (final s in await repo.sessionsForHealth(since)) {
        try {
          if (await process(s)) n++;
        } catch (e) {
          debugPrint('Health Connect: session ${s.id} skipped ($e)');
        }
      }
      return n;
    } catch (e) {
      debugPrint('Health Connect unavailable: $e');
      return 0;
    }
  }
}
