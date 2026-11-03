import 'catalog.dart';

/// One exercise prescription inside a planned workout block.
class PlanItem {
  const PlanItem({
    required this.exerciseId,
    required this.sets,
    this.repMin,
    this.repMax,
    this.durationSeconds,
    required this.restSeconds,
    this.targetWeightKg,
    this.notes = '',
  });

  factory PlanItem.fromJson(Map<String, dynamic> j) => PlanItem(
        exerciseId: j['exerciseId'] as String,
        sets: (j['sets'] as num?)?.toInt() ?? 1,
        repMin: (j['repMin'] as num?)?.toInt(),
        repMax: (j['repMax'] as num?)?.toInt(),
        durationSeconds: (j['durationSeconds'] as num?)?.toInt(),
        restSeconds: (j['restSeconds'] as num?)?.toInt() ?? 60,
        targetWeightKg: (j['targetWeightKg'] as num?)?.toDouble(),
        notes: j['notes'] as String? ?? '',
      );

  factory PlanItem.fromExercise(Exercise e, {double? targetWeightKg, String notes = ''}) => PlanItem(
        exerciseId: e.id,
        sets: e.sets,
        repMin: e.repMin,
        repMax: e.repMax,
        durationSeconds: e.durationSeconds,
        restSeconds: e.rest,
        targetWeightKg: targetWeightKg,
        notes: notes,
      );

  final String exerciseId;
  final int sets;
  final int? repMin;
  final int? repMax;
  final int? durationSeconds;
  final int restSeconds;
  final double? targetWeightKg;
  final String notes;

  bool get isTimed => durationSeconds != null && repMin == null;

  String get targetLabel {
    if (isTimed) return '$sets × ${formatSeconds(durationSeconds!)}';
    final reps = repMin == repMax || repMax == null ? '${repMin ?? '-'}' : '$repMin–$repMax';
    return '$sets × $reps';
  }

  PlanItem copyWith({
    String? exerciseId,
    int? sets,
    int? repMin,
    int? repMax,
    int? durationSeconds,
    int? restSeconds,
    double? targetWeightKg,
    bool clearWeight = false,
    String? notes,
  }) =>
      PlanItem(
        exerciseId: exerciseId ?? this.exerciseId,
        sets: sets ?? this.sets,
        repMin: repMin ?? this.repMin,
        repMax: repMax ?? this.repMax,
        durationSeconds: durationSeconds ?? this.durationSeconds,
        restSeconds: restSeconds ?? this.restSeconds,
        targetWeightKg: clearWeight ? null : (targetWeightKg ?? this.targetWeightKg),
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
        'exerciseId': exerciseId,
        'sets': sets,
        'repMin': repMin,
        'repMax': repMax,
        'durationSeconds': durationSeconds,
        'restSeconds': restSeconds,
        'targetWeightKg': targetWeightKg,
        'notes': notes,
      };

  /// Estimated seconds this item takes, including rest and setup.
  int estimateSeconds() {
    final work = durationSeconds ?? 40;
    final setup = isTimed ? 15 : 60;
    return sets * (work + restSeconds) + setup;
  }
}

class PlanBlock {
  const PlanBlock({required this.section, required this.items});

  factory PlanBlock.fromJson(Map<String, dynamic> j) => PlanBlock(
        section: Section.parse(j['section'] as String),
        items: (j['items'] as List)
            .map((e) => PlanItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  final Section section;
  final List<PlanItem> items;

  Map<String, dynamic> toJson() => {
        'section': section.name,
        'items': items.map((e) => e.toJson()).toList(),
      };
}

int estimateMinutes(List<PlanBlock> blocks) {
  final seconds = blocks.expand((b) => b.items).fold<int>(0, (s, i) => s + i.estimateSeconds());
  return (seconds / 60).round();
}

String formatSeconds(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return s == 0 ? '${m}min' : '$m:${s.toString().padLeft(2, '0')}';
}

String formatClock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
