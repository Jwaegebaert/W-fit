/// Feedback memory → training limitations (docs/IMPROVEMENT-PLAN.md §4.3).
///
/// Storage-agnostic: the data layer maps `feedback_entries` rows to [FeedbackRecord]s, and
/// [LimitationPolicy.fromFeedback] turns the active ones into exclusions, penalties and progression adjustments
/// used by the rule engine, the swap sheet and the coach brief.
library;

import 'catalog.dart';
import 'muscles.dart';
import 'stats.dart';

enum FeedbackKind {
  pain('pain'),
  discomfort('discomfort'),
  tooEasy('too_easy'),
  tooHard('too_hard'),
  unavailable('unavailable'),
  dislike('dislike'),
  like('like'),
  note('note');

  const FeedbackKind(this.id);
  final String id;

  bool get isPainLike => this == FeedbackKind.pain || this == FeedbackKind.discomfort;

  static FeedbackKind parse(String? id) =>
      FeedbackKind.values.firstWhere((k) => k.id == id, orElse: () => FeedbackKind.note);
}

/// Storage-agnostic feedback entry (fields of the synced `feedback_entries` table).
class FeedbackRecord {
  const FeedbackRecord({
    required this.id,
    required this.createdAt,
    required this.kind,
    this.region,
    this.severity,
    this.exerciseId,
    this.sessionId,
    this.note = '',
    this.status = 'active',
    this.reviewOn,
    this.resolvedAt,
    this.source = 'user',
    this.updatedAt,
    this.deleted = false,
  });

  /// Parses the sync / API JSON shape (camelCase; `reviewOn` as `yyyy-MM-dd`).
  factory FeedbackRecord.fromJson(Map<String, dynamic> j) => FeedbackRecord(
        id: j['id'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        kind: FeedbackKind.parse(j['kind'] as String?),
        region: j['region'] as String?,
        severity: (j['severity'] as num?)?.toInt(),
        exerciseId: j['exerciseId'] as String?,
        sessionId: j['sessionId'] as String?,
        note: j['note'] as String? ?? '',
        status: j['status'] as String? ?? 'active',
        reviewOn: j['reviewOn'] == null ? null : DateTime.tryParse(j['reviewOn'] as String),
        resolvedAt: j['resolvedAt'] == null ? null : DateTime.tryParse(j['resolvedAt'] as String),
        source: j['source'] as String? ?? 'user',
        updatedAt: j['updatedAt'] == null ? null : DateTime.tryParse(j['updatedAt'] as String),
        deleted: j['deleted'] as bool? ?? false,
      );

  final String id;
  final DateTime createdAt;
  final FeedbackKind kind;

  /// Body region id (see `BodyRegion`); required for pain/discomfort without [exerciseId].
  final String? region;

  /// 1 mild, 2 moderate, 3 severe (pain/discomfort).
  final int? severity;
  final String? exerciseId;
  final String? sessionId;
  final String note;

  /// `active` | `resolved`
  final String status;

  /// Day the app asks "still an issue?".
  final DateTime? reviewOn;
  final DateTime? resolvedAt;

  /// `user` | `coach`
  final String source;
  final DateTime? updatedAt;
  final bool deleted;

  bool get isActive => status == 'active' && !deleted;

  /// Severity used by the engine: explicit value, else pain → 2, discomfort → 1.
  int get effectiveSeverity => (severity ?? (kind == FeedbackKind.pain ? 2 : 1)).clamp(1, 3);

  BodyRegion? get bodyRegion => BodyRegion.parse(region);

  /// Active entry whose review date has come (the app shows a check-in card).
  bool isDueForReview(DateTime now) => isActive && reviewOn != null && !dateOnly(reviewOn!).isAfter(dateOnly(now));

  /// Default review date: pain +7 days, discomfort +14 days, otherwise none.
  static DateTime? defaultReviewOn(FeedbackKind kind, DateTime createdAt) => switch (kind) {
        FeedbackKind.pain => addDays(dateOnly(createdAt), 7),
        FeedbackKind.discomfort => addDays(dateOnly(createdAt), 14),
        _ => null,
      };

  FeedbackRecord copyWith({String? status, DateTime? resolvedAt, DateTime? reviewOn, bool? deleted}) => FeedbackRecord(
        id: id,
        createdAt: createdAt,
        kind: kind,
        region: region,
        severity: severity,
        exerciseId: exerciseId,
        sessionId: sessionId,
        note: note,
        status: status ?? this.status,
        reviewOn: reviewOn ?? this.reviewOn,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        source: source,
        updatedAt: updatedAt,
        deleted: deleted ?? this.deleted,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'kind': kind.id,
        'region': region,
        'severity': severity,
        'exerciseId': exerciseId,
        'sessionId': sessionId,
        'note': note,
        'status': status,
        'reviewOn': reviewOn == null ? null : isoDate(reviewOn!),
        'resolvedAt': resolvedAt?.toUtc().toIso8601String(),
        'source': source,
        if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
        'deleted': deleted,
      };
}

/// An active pain / discomfort limitation, ready for display and the brief.
class Limitation {
  const Limitation({
    required this.id,
    required this.kind,
    this.region,
    required this.severity,
    this.exerciseId,
    this.note = '',
    required this.since,
    this.reviewOn,
    required this.effect,
    this.affectedExercises = 0,
  });

  final String id;
  final FeedbackKind kind;
  final String? region;
  final int severity;
  final String? exerciseId;
  final String note;
  final DateTime since;
  final DateTime? reviewOn;

  /// What the engine does about it, e.g. "Excludes exercises that load the neck".
  final String effect;

  /// Catalog exercises excluded or penalised because of this limitation.
  final int affectedExercises;

  String get severityLabel => switch (severity) { 1 => 'mild', 2 => 'moderate', _ => 'severe' };

  Map<String, dynamic> toBrief() => {
        'id': id,
        'kind': kind.id,
        'region': region,
        'severity': severity,
        'exerciseId': exerciseId,
        'note': note,
        'since': isoDate(since),
      };
}

/// Exercise-specific progression feedback (latest `too_hard` / `too_easy`).
class ExerciseFeedbackSummary {
  const ExerciseFeedbackSummary({required this.exerciseId, required this.kind, required this.date, this.note = ''});

  final String exerciseId;
  final FeedbackKind kind;
  final DateTime date;
  final String note;

  /// Weight increments to apply on the next exposure: too_hard → −1, too_easy → +1.
  int get incrementSteps => switch (kind) { FeedbackKind.tooHard => -1, FeedbackKind.tooEasy => 1, _ => 0 };
}

class _RegionRule {
  _RegionRule(this.region, this.severity, this.record);
  final BodyRegion region;
  int severity;
  FeedbackRecord record;
}

class _ExerciseRule {
  const _ExerciseRule({required this.excluded, required this.penalty, required this.reason});
  final bool excluded;
  final int penalty;
  final String reason;
}

/// Exclusions and penalties derived from active feedback (§4.3 semantics):
/// * region pain/discomfort severity 1 → exercises stressing the region get [mildRegionPenalty] (used only if
///   nothing else fits); severity 2 → excluded; severity 3 → excluded and direct work for the region's related
///   muscles (exercises with such a primary muscle) excluded too;
/// * exercise `pain` → excluded until resolved; `discomfort` → excluded for 4 weeks, then [discomfortPenalty];
/// * `too_hard` → −1 weight increment next time and easier (lower-difficulty) variations preferred by the engine;
///   `too_easy` → +1 increment allowed.
/// An entry with both a region and an exercise applies both rules. A pain entry without severity counts as 2,
/// discomfort as 1. `dislike` / `like` / `unavailable` act through the preference and equipment tables.
class LimitationPolicy {
  const LimitationPolicy.empty()
      : _regions = const {},
        _exerciseRules = const {},
        exerciseFeedback = const {},
        activeLimitations = const [],
        _records = const [],
        _now = null;

  LimitationPolicy._(this._regions, this._exerciseRules, this.exerciseFeedback, this.activeLimitations, this._records,
      this._now);

  factory LimitationPolicy.fromFeedback(Iterable<FeedbackRecord> records, Catalog catalog, {DateTime? now}) {
    final today = dateOnly(now ?? DateTime.now());
    final all = records.where((r) => !r.deleted).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final active = all.where((r) => r.isActive).toList();

    final regions = <String, _RegionRule>{};
    final exerciseRules = <String, _ExerciseRule>{};
    final feedback = <String, ExerciseFeedbackSummary>{};
    for (final r in active) {
      if (r.kind.isPainLike) {
        final region = r.bodyRegion;
        if (region != null) {
          final rule = regions[region.id];
          if (rule == null) {
            regions[region.id] = _RegionRule(region, r.effectiveSeverity, r);
          } else if (r.effectiveSeverity > rule.severity) {
            rule
              ..severity = r.effectiveSeverity
              ..record = r;
          }
        }
        final ex = r.exerciseId;
        if (ex != null) {
          final name = catalog.exerciseName(ex);
          if (r.kind == FeedbackKind.pain) {
            exerciseRules[ex] = _ExerciseRule(excluded: true, penalty: 0, reason: 'Excluded: $name caused pain');
          } else {
            final days = daysBetween(r.createdAt, today);
            final prev = exerciseRules[ex];
            if (prev == null || !prev.excluded) {
              exerciseRules[ex] = days < discomfortPauseDays
                  ? _ExerciseRule(excluded: true, penalty: 0, reason: 'Paused for 4 weeks: $name caused discomfort')
                  : _ExerciseRule(excluded: false, penalty: discomfortPenalty, reason: 'Used sparingly: $name caused discomfort');
            }
          }
        }
      } else if ((r.kind == FeedbackKind.tooHard || r.kind == FeedbackKind.tooEasy) && r.exerciseId != null) {
        if (daysBetween(r.createdAt, today) <= feedbackDays) {
          feedback[r.exerciseId!] =
              ExerciseFeedbackSummary(exerciseId: r.exerciseId!, kind: r.kind, date: r.createdAt, note: r.note);
        }
      }
    }

    final limitations = <Limitation>[];
    for (final r in active.reversed.where((r) => r.kind.isPainLike)) {
      final region = r.bodyRegion;
      final sev = r.effectiveSeverity;
      final effects = <String>[];
      var affected = 0;
      if (region != null) {
        final regionText = region.label.toLowerCase();
        effects.add(switch (sev) {
          1 => 'Limits exercises that load the $regionText',
          2 => 'Excludes exercises that load the $regionText',
          _ => 'Excludes exercises that load the $regionText and direct '
              '${region.relatedMuscles.where(trackedMuscles.containsKey).map(prettyMuscle).join(', ').toLowerCase()} work',
        });
        affected += catalog.exercises
            .where((e) => e.stress.contains(region.id) || (sev >= 3 && e.primary.any(region.relatedMuscles.contains)))
            .length;
      }
      if (r.exerciseId != null) {
        final rule = exerciseRules[r.exerciseId!];
        effects.add(rule == null
            ? 'Watching ${catalog.exerciseName(r.exerciseId!)}'
            : rule.excluded
                ? 'Excludes ${catalog.exerciseName(r.exerciseId!)}'
                : 'Uses ${catalog.exerciseName(r.exerciseId!)} only if nothing else fits');
        affected += region == null ? 1 : 0;
      }
      limitations.add(Limitation(
        id: r.id,
        kind: r.kind,
        region: region?.id,
        severity: sev,
        exerciseId: r.exerciseId,
        note: r.note,
        since: r.createdAt,
        reviewOn: r.reviewOn,
        effect: effects.join('; '),
        affectedExercises: affected,
      ));
    }
    return LimitationPolicy._(regions, exerciseRules, feedback, limitations, all, today);
  }

  /// Penalty for exercises stressing a region with mild (severity 1) pain – larger than any other score
  /// difference, so they are used only when nothing else fits.
  static const int mildRegionPenalty = 20;

  /// Penalty after the 4-week discomfort pause.
  static const int discomfortPenalty = 6;

  static const int discomfortPauseDays = 28;

  /// too_hard / too_easy entries older than this are ignored.
  static const int feedbackDays = 42;

  final Map<String, _RegionRule> _regions;
  final Map<String, _ExerciseRule> _exerciseRules;

  /// exerciseId → latest too_hard / too_easy feedback (last [feedbackDays] days, active).
  final Map<String, ExerciseFeedbackSummary> exerciseFeedback;

  /// Active pain / discomfort entries, newest first.
  final List<Limitation> activeLimitations;
  final List<FeedbackRecord> _records;
  final DateTime? _now;

  bool get isEmpty => _regions.isEmpty && _exerciseRules.isEmpty && exerciseFeedback.isEmpty;

  /// Highest active severity per region id.
  Map<String, int> get regionSeverity => {for (final r in _regions.values) r.region.id: r.severity};

  /// Muscles whose direct work is excluded (severity-3 regions).
  Set<String> get excludedMuscles => {
        for (final r in _regions.values)
          if (r.severity >= 3) ...r.region.relatedMuscles,
      };

  bool excludes(Exercise e) {
    if (_exerciseRules[e.id]?.excluded ?? false) return true;
    for (final r in _regions.values) {
      if (r.severity >= 2 && e.stress.contains(r.region.id)) return true;
      if (r.severity >= 3 && e.primary.any(r.region.relatedMuscles.contains)) return true;
    }
    return false;
  }

  /// Scoring penalty for eligible exercises (0 = none). Excluded exercises should be filtered with [excludes].
  /// (`too_hard` is not a penalty here: the engine prefers lower-difficulty variations and lowers the load.)
  int penalty(Exercise e) {
    var p = 0;
    for (final r in _regions.values) {
      if (r.severity == 1 && e.stress.contains(r.region.id)) p += mildRegionPenalty;
    }
    final rule = _exerciseRules[e.id];
    if (rule != null && !rule.excluded) p += rule.penalty;
    return p;
  }

  /// Short human reason why [e] is excluded or penalised (null when unaffected),
  /// e.g. "Avoids neck load (neck pain)".
  String? reason(Exercise e) {
    final rule = _exerciseRules[e.id];
    if (rule != null && rule.excluded) return rule.reason;
    for (final r in _regions.values) {
      final label = r.region.label.toLowerCase();
      final what = '${r.severity >= 3 ? 'severe ' : r.severity == 1 ? 'mild ' : ''}$label ${r.record.kind.id}';
      if (r.severity >= 2 && e.stress.contains(r.region.id)) return 'Avoids $label load ($what)';
      if (r.severity >= 3 && e.primary.any(r.region.relatedMuscles.contains)) {
        final muscles = e.primary.where(r.region.relatedMuscles.contains).map(prettyMuscle).join(', ').toLowerCase();
        return 'Avoids direct $muscles work ($what)';
      }
    }
    for (final r in _regions.values) {
      if (r.severity == 1 && e.stress.contains(r.region.id)) {
        final label = r.region.label.toLowerCase();
        return 'Limits $label load (mild $label ${r.record.kind.id})';
      }
    }
    if (rule != null) return rule.reason;
    if (exerciseFeedback[e.id]?.kind == FeedbackKind.tooHard) return 'Felt too hard last time';
    return null;
  }

  /// Active entries whose review date has come.
  List<FeedbackRecord> dueForReview(DateTime now) => _records.where((r) => r.isDueForReview(now)).toList();

  /// True when at least one active entry is due for a check-in.
  bool isDueForReview(DateTime now) => _records.any((r) => r.isDueForReview(now));

  /// `limitations` (active pain/discomfort) and `exerciseFeedback` (other exercise-linked entries of the last
  /// 90 days, newest first, ≤ 30) of the coach brief.
  Map<String, dynamic> toBrief({DateTime? now}) {
    final today = dateOnly(now ?? _now ?? DateTime.now());
    final limitationIds = activeLimitations.map((l) => l.id).toSet();
    final feedback = _records
        .where((r) =>
            r.exerciseId != null &&
            !limitationIds.contains(r.id) &&
            daysBetween(r.createdAt, today) <= 90 &&
            daysBetween(r.createdAt, today) >= 0)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return {
      'limitations': activeLimitations.map((l) => l.toBrief()).toList(),
      'exerciseFeedback': [
        for (final r in feedback.take(30))
          {'exerciseId': r.exerciseId, 'kind': r.kind.id, 'note': r.note, 'date': isoDate(r.createdAt)},
      ],
    };
  }
}
