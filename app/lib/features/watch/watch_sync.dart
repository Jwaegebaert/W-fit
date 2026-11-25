import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';
import '../../domain/watch_protocol.dart';
import '../../domain/workout_countdown.dart';
import '../../providers.dart';
import '../workout/set_logger.dart';
import '../workout/workout_timer.dart';
import 'watch_bridge.dart';

/// Exercise the user opened on the phone during a session; the watch jumps to it.
class OpenExercise extends Notifier<({String sessionId, int order})?> {
  @override
  ({String sessionId, int order})? build() => null;

  void open(String sessionId, int order) => state = (sessionId: sessionId, order: order);
  void clear() => state = null;
}

final openExerciseProvider = NotifierProvider<OpenExercise, ({String sessionId, int order})?>(OpenExercise.new);

/// Last set that came in from the watch, so an open exercise card can show its values.
class WatchSetNotifier extends Notifier<SetLog?> {
  @override
  SetLog? build() => null;

  void show(SetLog log) => state = log;
}

final watchSetProvider = NotifierProvider<WatchSetNotifier, SetLog?>(WatchSetNotifier.new);

/// Ids of the watch events handled last (newest at the end).
class _AckedEvents extends Notifier<List<String>> {
  static const _keep = 100;

  @override
  List<String> build() => const [];

  void add(String id) {
    if (state.contains(id)) return;
    final all = [...state, id];
    state = all.length > _keep ? all.sublist(all.length - _keep) : all;
  }
}

final _ackedProvider = NotifierProvider<_AckedEvents, List<String>>(_AckedEvents.new);

final _setsProvider =
    StreamProvider.autoDispose.family<List<SetLog>, String>((ref, id) => ref.watch(repositoryProvider).watchSets(id));

final _planProvider = StreamProvider.autoDispose
    .family<PlannedWorkout?, String>((ref, id) => ref.watch(repositoryProvider).watchPlanned(id));

/// Exercises of a plan with progression advice, recomputed only when the plan changes (not on every set).
final _plannedProvider = FutureProvider.autoDispose.family<List<_Planned>, (String, String)>((ref, key) async {
  final (sessionId, planId) = key;
  final blocksJson = ref.watch(_planProvider(planId).select((p) => p.value?.blocksJson));
  if (blocksJson == null) return const [];
  final coach = ref.read(coachServiceProvider);
  return [
    for (final b in Repository.decodeBlocks(blocksJson))
      for (final item in b.items)
        (
          section: b.section,
          item: item,
          advice: await coach.advice(item.exerciseId, item, excludeSessionId: sessionId),
        ),
  ];
});

typedef _Planned = ({Section section, PlanItem item, ProgressionAdvice advice});

/// A session nobody finished should not stay on the watch for days.
const _sessionMaxAge = Duration(hours: 8);

/// What the watch should show right now; null while something is still loading.
final watchSnapshotProvider = Provider.autoDispose<WatchSnapshot?>((ref) {
  final acked = ref.watch(_ackedProvider);
  ref.watch(workoutTimerProvider);
  final timer = ref.read(workoutTimerProvider.notifier).register;
  final open = ref.watch(openExerciseProvider);
  final loads = ref.watch(loadModelProvider);
  final catalog = ref.watch(catalogProvider);

  final active = ref.watch(activeSessionProvider);
  if (!active.hasValue) return null;
  final session = active.value;
  if (session == null || DateTime.now().toUtc().difference(session.startedAt.toUtc()) > _sessionMaxAge) {
    return WatchSnapshot(acked: acked);
  }
  final planId = session.plannedWorkoutId;
  final planned = planId == null ? const <_Planned>[] : ref.watch(_plannedProvider((session.id, planId))).value;
  final sets = ref.watch(_setsProvider(session.id)).value;
  if (planned == null || sets == null) return null;
  return WatchSnapshot(
    sessionId: session.id,
    title: session.title,
    startedAt: session.startedAt.millisecondsSinceEpoch,
    current: open?.sessionId == session.id ? open!.order : null,
    timer: timer,
    acked: acked,
    exercises: [
      for (final (order, p) in planned.indexed)
        WatchExercise.from(
          order: order,
          item: p.item,
          section: p.section,
          exercise: catalog.exercise(p.item.exerciseId),
          loads: loads,
          advice: p.advice,
          logged: [
            for (final s in sets)
              if (s.completed && s.exerciseOrder == order && s.exerciseId == p.item.exerciseId)
                WatchSet(
                  set: s.setNumber,
                  weight: s.weightKg,
                  reps: s.reps,
                  seconds: s.durationSeconds,
                  at: (s.completedAt ?? s.updatedAt).millisecondsSinceEpoch,
                ),
          ],
        ),
    ],
  );
});

/// Keeps the watch up to date and applies what happens on it. The database stays the owner of the session.
class WatchSync {
  WatchSync(this._ref, this._bridge);

  final Ref _ref;
  final WatchBridge _bridge;
  String? _published;
  bool _started = false;
  Future<void> _queue = Future.value();

  Future<void> start() async {
    if (_started || !await _bridge.available() || !_ref.mounted) return;
    _started = true;
    _bridge.listen(receive);
    // Listens on the container: a provider nobody listens to (like this one) has its own subscriptions paused.
    final sub = _ref.container.listen(watchSnapshotProvider, (_, next) {
      if (next != null) _publish(next.encode());
    }, fireImmediately: true);
    _ref.onDispose(sub.close);
    await catchUp();
  }

  /// Handles messages that arrived while the app was not running.
  Future<void> catchUp() async {
    if (!_started) return;
    for (final json in await _bridge.pending()) {
      receive(json);
    }
    await _queue;
  }

  Future<void> openOnWatch() async {
    if (_started) await _bridge.openOnWatch();
  }

  /// Messages are handled one at a time: two events for the same set must not both insert a row.
  Future<void> receive(String json) =>
      _queue = _queue.then((_) => _handle(json)).catchError((Object _) {}); // one bad message must not block the rest

  void _publish(String json) {
    if (json == _published) return;
    _published = json;
    unawaited(_bridge.publish(json));
  }

  Future<void> _handle(String json) async {
    if (!_ref.mounted) return;
    final message = parseWatchMessage(json);
    if (message is Countdown) _ref.read(workoutTimerProvider.notifier).adopt(message);
    if (message is WatchEvent) {
      await _apply(message);
      if (_ref.mounted) _ref.read(_ackedProvider.notifier).add(message.id);
    }
  }

  Future<void> _apply(WatchEvent e) async {
    final repo = _ref.read(repositoryProvider);
    final session = await repo.sessionById(e.sessionId);
    if (session == null || session.deleted) return; // workout discarded
    final logger = _ref.read(setLoggerProvider);
    final existing = await logger.find(e.sessionId, order: e.order, exerciseId: e.exerciseId, set: e.set);
    final at = DateTime.fromMillisecondsSinceEpoch(e.at);
    // The newest entry wins. The database keeps whole seconds.
    if (existing != null && existing.updatedAt.millisecondsSinceEpoch ~/ 1000 > e.at ~/ 1000) return;
    // An undo for an unknown set is stored too (not completed), in case the log it undoes arrives after it.
    // Same rules as the exercise card: no kg without a weight field, and no "0 kg" for bodyweight exercises.
    final exercise = _ref.read(catalogProvider).exercise(e.exerciseId);
    final noWeight = exercise != null && (!exercise.logsWeight || (!exercise.isWeighted && e.weight == 0));
    await logger.log(
      SetRef(
        sessionId: e.sessionId,
        order: e.order,
        exerciseId: e.exerciseId,
        section: e.section,
        set: e.set,
        seconds: e.seconds ?? 0,
        rest: 0, // the watch sends its own countdown
        last: false,
      ),
      weightKg: e.isLog ? (noWeight ? null : e.weight) : existing?.weightKg,
      reps: e.isLog ? e.reps : existing?.reps,
      durationSeconds: e.isLog ? e.seconds : existing?.durationSeconds,
      completed: e.isLog,
      at: at,
      startRest: false,
    );
    final saved = await logger.find(e.sessionId, order: e.order, exerciseId: e.exerciseId, set: e.set);
    if (!_ref.mounted) return;
    if (saved != null && saved.completed) _ref.read(watchSetProvider.notifier).show(saved);
    if (session.endedAt != null) unawaited(_ref.read(syncControllerProvider.notifier).syncNow());
  }
}

/// Wearable Data Layer bridge (overridden with a fake in tests).
final watchBridgeProvider = Provider<WatchBridge>((ref) => const WatchBridge());

final watchSyncProvider = Provider<WatchSync>((ref) => WatchSync(ref, ref.watch(watchBridgeProvider)));
