import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TimerState {
  const TimerState({required this.label, required this.total, required this.endsAt, required this.isWork});

  final String label;
  final int total;
  final DateTime endsAt;
  final bool isWork;

  int get remaining {
    final ms = endsAt.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  double get progress => total == 0 ? 1 : 1 - remaining / total;
}

/// Single countdown used for rest periods and timed exercises. Survives rebuilds and app backgrounding
/// because the remaining time is derived from an absolute end time.
class WorkoutTimer extends Notifier<TimerState?> {
  Timer? _ticker;
  void Function()? _onDone;

  @override
  TimerState? build() {
    ref.onDispose(() => _ticker?.cancel());
    return null;
  }

  void start(String label, int seconds, {bool isWork = false, void Function()? onDone}) {
    if (seconds <= 0) return;
    _onDone = onDone;
    state = TimerState(
      label: label,
      total: seconds,
      endsAt: DateTime.now().add(Duration(seconds: seconds)),
      isWork: isWork,
    );
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final s = state;
      if (s == null) return;
      if (s.remaining <= 0) _finish();
    });
  }

  void add(int seconds) {
    final s = state;
    if (s == null) return;
    final endsAt = s.endsAt.add(Duration(seconds: seconds));
    if (endsAt.isBefore(DateTime.now())) {
      _finish();
      return;
    }
    state = TimerState(label: s.label, total: s.total + seconds, endsAt: endsAt, isWork: s.isWork);
  }

  void skip() {
    _ticker?.cancel();
    _onDone = null;
    state = null;
  }

  void _finish() {
    _ticker?.cancel();
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 250), HapticFeedback.heavyImpact);
    final cb = _onDone;
    _onDone = null;
    state = null;
    cb?.call();
  }
}

final workoutTimerProvider = NotifierProvider<WorkoutTimer, TimerState?>(WorkoutTimer.new);
