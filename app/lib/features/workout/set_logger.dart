import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/workout_countdown.dart';
import '../../providers.dart';
import 'workout_timer.dart';

/// Writes sets to the active session, whether they come from an exercise card, a finished work countdown or the watch.
/// Lives outside the widgets so logging also works when no exercise card is on screen.
class SetLogger {
  SetLogger(this._ref);

  final Ref _ref;

  Repository get _repo => _ref.read(repositoryProvider);

  /// The stored row for one set of the plan, if any.
  Future<SetLog?> find(String sessionId, {required int order, required String exerciseId, required int set}) async =>
      (await _repo.setsForSession(sessionId))
          .where((s) => s.exerciseOrder == order && s.exerciseId == exerciseId && s.setNumber == set)
          .firstOrNull;

  /// Logs (or un-logs) a set and starts its rest.
  Future<void> log(
    SetRef set, {
    double? weightKg,
    int? reps,
    int? durationSeconds,
    bool completed = true,
    DateTime? at,
    bool startRest = true,
  }) async {
    final existing = await find(set.sessionId, order: set.order, exerciseId: set.exerciseId, set: set.set);
    await _repo.logSet(
      id: existing?.id,
      sessionId: set.sessionId,
      exerciseId: set.exerciseId,
      section: Section.parse(set.section),
      exerciseOrder: set.order,
      setNumber: set.set,
      weightKg: weightKg,
      reps: reps,
      durationSeconds: durationSeconds,
      rir: existing?.rir,
      completed: completed,
      at: at?.toUtc(),
    );
    if (completed && startRest && set.rest > 0) {
      _ref
          .read(workoutTimerProvider.notifier)
          .start(set.last ? Countdown.restNextLabel : Countdown.restLabel, set.rest, from: at);
    }
  }

  /// A timed set whose work countdown ended at [at]. The countdown starts the rest itself.
  Future<void> logTimed(SetRef set, {required DateTime at}) =>
      log(set, durationSeconds: set.seconds, at: at, startRest: false);
}

final setLoggerProvider = Provider<SetLogger>(SetLogger.new);
