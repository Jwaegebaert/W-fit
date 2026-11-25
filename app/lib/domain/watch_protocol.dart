import 'dart:convert';

import 'catalog.dart';
import 'plan.dart';
import 'progression.dart';
import 'workout_countdown.dart';

/// Messages between the phone and the watch app (`watch/`, `Protocol.kt`). The phone owns the session and sends
/// snapshots; the watch answers with events. The examples in `watch/fixtures` are tested on both sides.
const watchProtocolVersion = 1;

/// A set as the watch sees it.
class WatchSet {
  const WatchSet({required this.set, this.weight, this.reps, this.seconds, required this.at});

  final int set;
  final double? weight;
  final int? reps;
  final int? seconds;

  /// Epoch milliseconds.
  final int at;

  Map<String, dynamic> toJson() => {'set': set, 'weight': weight, 'reps': reps, 'seconds': seconds, 'at': at};
}

/// One exercise, with every label already worked out so the watch needs no catalog.
class WatchExercise {
  const WatchExercise({
    required this.order,
    required this.id,
    required this.name,
    required this.section,
    required this.sectionLabel,
    required this.target,
    required this.weightText,
    required this.sets,
    required this.targetReps,
    required this.seconds,
    required this.perSide,
    required this.rest,
    required this.weightLabel,
    required this.needsWeight,
    required this.weight,
    required this.step,
    required this.checklist,
    required this.logged,
  });

  /// Builds the entry for a plan item, following the same rules as the phone's exercise card.
  factory WatchExercise.from({
    required int order,
    required PlanItem item,
    required Section section,
    required Exercise? exercise,
    required LoadModel loads,
    required ProgressionAdvice? advice,
    required List<WatchSet> logged,
  }) {
    final perSide = item.perSide || (exercise?.unilateral ?? false);
    final checklist = section.isChecklist;
    final label = item.isTimed || checklist ? null : weightLabelFor(exercise);
    final weight = label == null ? null : item.targetWeightKg ?? advice?.weightKg;
    return WatchExercise(
      order: order,
      id: item.exerciseId,
      name: exercise?.name ?? item.exerciseId,
      section: section.name,
      sectionLabel: section.label,
      target: item.copyWith(perSide: perSide).targetLabel,
      weightText: weight == null ? null : loads.weightLabel(exercise, weight),
      sets: item.sets,
      targetReps: item.isTimed ? null : (checklist ? item.repMax ?? item.repMin : targetRepsFor(item, advice)),
      seconds: item.isTimed ? item.durationSeconds : null,
      perSide: perSide,
      rest: checklist ? 0 : item.restSeconds,
      weightLabel: label,
      needsWeight: label != null &&
          exercise != null &&
          exercise.isWeighted &&
          exercise.load != LoadType.optional,
      weight: weight,
      step: (exercise?.incrementKg ?? 0) > 0 ? exercise!.incrementKg : 2.5,
      checklist: checklist,
      logged: logged,
    );
  }

  final int order;
  final String id;
  final String name;
  final String section;
  final String sectionLabel;

  /// "3 × 6–8 / side".
  final String target;

  /// "40 kg plates (+20 bar)"; null without a target weight.
  final String? weightText;
  final int sets;
  final int? targetReps;

  /// Seconds per set (per side for one-sided holds); null for rep sets.
  final int? seconds;
  final bool perSide;
  final int rest;

  /// "Plates kg", "Assist kg", "Extra kg" or "kg"; null when the exercise has no weight field.
  final String? weightLabel;

  /// Working sets on weighted exercises cannot be logged without a weight.
  final bool needsWeight;
  final double? weight;
  final double step;

  /// Warm-up or cool-down: ticked off as a whole, all sets at once.
  final bool checklist;
  final List<WatchSet> logged;

  Map<String, dynamic> toJson() => {
        'order': order,
        'id': id,
        'name': name,
        'section': section,
        'sectionLabel': sectionLabel,
        'target': target,
        'weightText': weightText,
        'sets': sets,
        'targetReps': targetReps,
        'seconds': seconds,
        'perSide': perSide,
        'rest': rest,
        'weightLabel': weightLabel,
        'needsWeight': needsWeight,
        'weight': weight,
        'step': step,
        'checklist': checklist,
        'logged': [for (final s in logged) s.toJson()],
      };
}

/// Header of the weight field; null when the exercise has none.
String? weightLabelFor(Exercise? e) => switch (e?.load) {
      LoadType.none => null,
      LoadType.assist => 'Assist kg',
      LoadType.optional => 'Extra kg',
      _ => e?.bar != null ? 'Plates kg' : 'kg',
    };

/// Reps a set is logged with when nothing else was entered.
int targetRepsFor(PlanItem item, ProgressionAdvice? advice) =>
    advice?.targetReps ?? item.repMax ?? item.repMin ?? 10;

/// Everything the watch shows. [sessionId] is null when no workout is active; [acked] lists the events the phone has
/// handled, so the watch can stop repeating them.
class WatchSnapshot {
  const WatchSnapshot({
    this.sessionId,
    this.title = '',
    this.startedAt = 0,
    this.current,
    this.exercises = const [],
    this.timer,
    this.acked = const [],
  });

  final String? sessionId;
  final String title;

  /// Epoch milliseconds.
  final int startedAt;

  /// Exercise the user opened on the phone, if any.
  final int? current;
  final List<WatchExercise> exercises;
  final Countdown? timer;
  final List<String> acked;

  Map<String, dynamic> toJson() => {
        'v': watchProtocolVersion,
        'sessionId': sessionId,
        'title': title,
        'startedAt': startedAt,
        'current': current,
        'exercises': [for (final e in exercises) e.toJson()],
        'timer': timer?.toJson(),
        'acked': acked,
      };

  String encode() => jsonEncode(toJson());
}

/// A set logged or undone on the watch.
class WatchEvent {
  const WatchEvent({
    required this.id,
    required this.at,
    required this.sessionId,
    required this.type,
    required this.order,
    required this.exerciseId,
    required this.section,
    required this.set,
    this.weight,
    this.reps,
    this.seconds,
  });

  final String id;

  /// Epoch milliseconds on the watch.
  final int at;
  final String sessionId;

  /// `log` | `unlog`
  final String type;
  final int order;
  final String exerciseId;
  final String section;
  final int set;
  final double? weight;
  final int? reps;
  final int? seconds;

  bool get isLog => type == 'log';
}

/// Parses a message from the watch into a [WatchEvent] or a [Countdown]; null for anything unknown or damaged, so a
/// newer watch app never breaks the phone.
Object? parseWatchMessage(String json) {
  try {
    final j = jsonDecode(json) as Map<String, dynamic>;
    if (j['v'] != watchProtocolVersion) return null;
    switch (j['type']) {
      case 'timer':
        return Countdown.fromJson(j['timer'] as Map<String, dynamic>);
      case 'log' || 'unlog':
        return WatchEvent(
          id: j['id'] as String,
          at: (j['at'] as num).toInt(),
          sessionId: j['sessionId'] as String,
          type: j['type'] as String,
          order: (j['order'] as num).toInt(),
          exerciseId: j['exerciseId'] as String,
          section: j['section'] as String,
          set: (j['set'] as num).toInt(),
          weight: (j['weight'] as num?)?.toDouble(),
          reps: (j['reps'] as num?)?.toInt(),
          seconds: (j['seconds'] as num?)?.toInt(),
        );
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}
