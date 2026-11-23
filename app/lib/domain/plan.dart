import 'dart:convert';

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
    this.perSide = false,
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
        perSide: j['perSide'] as bool? ?? false,
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
        perSide: e.unilateral,
      );

  final String exerciseId;
  final int sets;
  final int? repMin;
  final int? repMax;
  final int? durationSeconds;
  final int restSeconds;
  final double? targetWeightKg;
  final String notes;

  /// Reps / seconds count per side (unilateral exercise): every set covers both sides.
  final bool perSide;

  bool get isTimed => durationSeconds != null && repMin == null;

  String get targetLabel {
    final side = perSide ? ' / side' : '';
    if (isTimed) return '$sets × ${formatSeconds(durationSeconds!)}$side';
    final reps = repMin == repMax || repMax == null ? '${repMin ?? '-'}' : '$repMin–$repMax';
    return '$sets × $reps$side';
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
    bool? perSide,
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
        perSide: perSide ?? this.perSide,
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
        if (perSide) 'perSide': true,
      };

  /// Estimated seconds this item takes, including rest and setup. Per-side timed holds run twice (their duration is
  /// per side); rep sets keep the 40 s average either way – it already covers a one-sided set of 8–15 reps.
  int estimateSeconds() {
    final work = isTimed ? (durationSeconds ?? 30) * (perSide ? 2 : 1) : 40;
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

/// One exercise replacement (or removal when [to] is null) applied to a plan, e.g. after a pain report.
class PlanChange {
  const PlanChange({required this.from, this.to, required this.reason});

  factory PlanChange.fromJson(Map<String, dynamic> j) => PlanChange(
        from: j['from'] as String? ?? '',
        to: (j['to'] as String?)?.isEmpty ?? true ? null : j['to'] as String,
        reason: j['reason'] as String? ?? '',
      );

  final String from;

  /// Replacement exercise id; null when the exercise was removed without a replacement.
  final String? to;
  final String reason;

  Map<String, dynamic> toJson() => {'from': from, 'to': to, 'reason': reason};
}

/// Plan metadata stored in `PlannedWorkout.metaJson` (docs/IMPROVEMENT-PLAN.md §4.3):
/// `{"program":"Block 2 · Week 3 · Push B","variant":"B","deload":false,"focus":["biceps"],"rationale":["…"],
///   "changes":[{"from":"id","to":"id","reason":"…"}]}`.
class PlanMeta {
  const PlanMeta({
    this.program = '',
    this.variant,
    this.deload = false,
    this.focus = const [],
    this.rationale = const [],
    this.changes = const [],
  });

  factory PlanMeta.fromJson(Map<String, dynamic> j) => PlanMeta(
        program: j['program'] as String? ?? '',
        variant: j['variant'] as String?,
        deload: j['deload'] as bool? ?? false,
        focus: (j['focus'] as List? ?? const []).whereType<String>().toList(),
        rationale: (j['rationale'] as List? ?? const []).whereType<String>().toList(),
        changes: (j['changes'] as List? ?? const [])
            .whereType<Map>()
            .map((c) => PlanChange.fromJson(c.cast<String, dynamic>()))
            .toList(),
      );

  /// Decodes `metaJson`; returns an empty meta for null, blank or invalid input.
  static PlanMeta decode(String? json) {
    if (json == null || json.trim().isEmpty) return const PlanMeta();
    try {
      final v = jsonDecode(json);
      return v is Map ? PlanMeta.fromJson(v.cast<String, dynamic>()) : const PlanMeta();
    } on FormatException {
      return const PlanMeta();
    }
  }

  /// Program position label, e.g. "Block 2 · Week 3 · Push B".
  final String program;

  /// "A" or "B".
  final String? variant;
  final bool deload;

  /// Muscle ids this plan deliberately gives extra attention.
  final List<String> focus;

  /// Short, data-referencing reasons for the plan (≤ 6 lines).
  final List<String> rationale;
  final List<PlanChange> changes;

  bool get isEmpty => program.isEmpty && variant == null && focus.isEmpty && rationale.isEmpty && changes.isEmpty;

  PlanMeta copyWith({
    String? program,
    String? variant,
    bool? deload,
    List<String>? focus,
    List<String>? rationale,
    List<PlanChange>? changes,
  }) =>
      PlanMeta(
        program: program ?? this.program,
        variant: variant ?? this.variant,
        deload: deload ?? this.deload,
        focus: focus ?? this.focus,
        rationale: rationale ?? this.rationale,
        changes: changes ?? this.changes,
      );

  /// Appends [more] changes (e.g. from `RuleEngine.adjustForLimitations`).
  PlanMeta withChanges(Iterable<PlanChange> more) => copyWith(changes: [...changes, ...more]);

  Map<String, dynamic> toJson() => {
        'program': program,
        'variant': variant,
        'deload': deload,
        'focus': focus,
        'rationale': rationale,
        'changes': changes.map((c) => c.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());
}

/// Plans made before catalog v4 stored one-sided stretches as the total for both sides (60 s = 30 s per side) and the
/// suitcase carry as 40 s; the catalog and the timer now count per side. Returns [blocks] with those old times
/// converted, or null when nothing needs converting.
List<PlanBlock>? convertLegacyHolds(List<PlanBlock> blocks, Catalog catalog) {
  var changed = false;
  PlanItem convert(PlanItem i) {
    final e = catalog.exercise(i.exerciseId);
    final now = e?.durationSeconds;
    if (e == null || now == null || !e.unilateral || !e.isTimed) return i;
    final legacy = e.category == 'cooldown' ? now * 2 : (e.id == 'suitcase-carry' ? 40 : null);
    if (legacy == null || i.durationSeconds != legacy) return i;
    changed = true;
    return i.copyWith(durationSeconds: now, perSide: true);
  }

  final out = [for (final b in blocks) PlanBlock(section: b.section, items: b.items.map(convert).toList())];
  return changed ? out : null;
}

/// Rest multiplier for the profile's "Rest between sets" setting (short | normal | long).
double restScaleFor(String mode) => switch (mode) {
      'short' => 0.7,
      'long' => 1.3,
      _ => 1.0,
    };

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
