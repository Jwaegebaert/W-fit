import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/workout_countdown.dart';
import 'set_logger.dart';

/// Current time in epoch milliseconds (replaced in tests).
final nowMsProvider = Provider<int Function()>((ref) => () => DateTime.now().millisecondsSinceEpoch);

/// Single countdown used for rest periods and timed exercises, shared with the watch. Survives rebuilds and app
/// backgrounding because the remaining time is derived from absolute end times.
class WorkoutTimer extends Notifier<Countdown?> {
  Timer? _ticker;

  /// Last change by a person on this phone or the watch, kept after the countdown ends or is skipped so an older
  /// message from the watch cannot bring it back.
  Countdown? _register;

  /// Phase whose end was signalled last, so every side and side switch of a one-sided hold is felt once.
  int _phase = 0;

  @override
  Countdown? build() {
    ref.onDispose(() => _ticker?.cancel());
    return null;
  }

  int _nowMs() => ref.read(nowMsProvider)();

  /// What the watch is told: the running or last stopped countdown.
  Countdown? get register => _register;

  /// Starts a rest countdown.
  void start(String label, int seconds, {DateTime? from}) {
    if (seconds <= 0) return;
    _run(Countdown.rest(label, seconds,
        from: from?.millisecondsSinceEpoch ?? _nowMs(), owner: CountdownOwner.phone));
  }

  /// Starts the work countdown of a timed set; the set is logged when it ends, then its rest starts.
  void startWork(String name, SetRef set, {required bool perSide}) {
    if (set.seconds <= 0) return;
    _run(Countdown.work(name, set, perSide: perSide, from: _nowMs(), owner: CountdownOwner.phone));
  }

  /// Takes over a countdown started, changed or stopped on the watch, unless this phone changed it later.
  void adopt(Countdown fromWatch) {
    final current = _register;
    if (current != null && fromWatch.changedAt <= current.changedAt) return;
    final running = state?.set;
    final next = fromWatch.at(_nowMs());
    if (identical(next, fromWatch)) {
      _run(fromWatch);
      return;
    }
    // Stopped, or ended while out of reach: catch up without a signal.
    _ticker?.cancel();
    _register = fromWatch;
    if (next == null) {
      state = null;
    } else {
      _run(next);
    }
    final set = fromWatch.set;
    if (fromWatch.isWork && fromWatch.owner == CountdownOwner.phone && set != null && running?.isSameSet(set) == true) {
      unawaited(ref.read(setLoggerProvider).logTimed(set, at: DateTime.fromMillisecondsSinceEpoch(fromWatch.endsAt)));
    }
  }

  void add(int seconds) {
    final s = state;
    if (s == null) return;
    _run(s.extend(seconds, _nowMs()));
  }

  void skip() {
    if (state == null) return;
    _run(Countdown.none(_nowMs(), CountdownOwner.phone));
  }

  void _run(Countdown c) {
    _register = c;
    _ticker?.cancel();
    final now = _nowMs();
    if (c.kind == CountdownKind.none) {
      state = null;
      return;
    }
    _phase = c.phaseIndex(now);
    state = c;
    if (c.isOver(now)) {
      _finish();
    } else {
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    }
  }

  void _tick() {
    final s = state;
    if (s == null) return;
    final now = _nowMs();
    if (s.isOver(now)) {
      _finish();
    } else if (s.phaseIndex(now) != _phase) {
      _phase = s.phaseIndex(now);
      _buzz();
    }
  }

  void _finish() {
    final done = state;
    _ticker?.cancel();
    if (done == null) return;
    _buzz();
    final next = done.at(_nowMs());
    if (next == null) {
      state = null;
    } else {
      _run(next);
    }
    final set = done.set;
    // A countdown from the watch is logged by the watch, also when it was stopped there while out of reach.
    if (set != null && done.isWork && done.owner == CountdownOwner.phone) {
      unawaited(ref.read(setLoggerProvider).logTimed(set, at: DateTime.fromMillisecondsSinceEpoch(done.endsAt)));
    }
  }

  void _buzz() {
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 250), HapticFeedback.heavyImpact);
  }
}

final workoutTimerProvider = NotifierProvider<WorkoutTimer, Countdown?>(WorkoutTimer.new);
