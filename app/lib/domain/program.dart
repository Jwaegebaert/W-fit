/// Program state: 6-week blocks (5 accumulation weeks + 1 deload), A/B variants per day type, target RIR and
/// deload triggers (docs/IMPROVEMENT-PLAN.md §4.7). Derived by replaying the session history, so it needs no
/// stored state beyond the sessions (and, when available, the plan meta of each session).
library;

import 'catalog.dart';
import 'plan.dart';
import 'stats.dart';
import 'templates.dart';
import 'training_load.dart';

/// Storage-agnostic summary of one completed session.
class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.date,
    required this.dayType,
    this.rating,
    this.effort,
    this.mainExerciseIds = const [],
    this.meta,
  });

  final String id;
  final DateTime date;
  final DayType dayType;

  /// 1–5 session rating.
  final int? rating;

  /// 1–10 perceived effort.
  final int? effort;

  /// Exercise ids performed in the main block, in order.
  final List<String> mainExerciseIds;

  /// Meta of the plan the session followed (variant / deload are trusted when present).
  final PlanMeta? meta;
}

/// A past session annotated with its program position.
class ProgramSession {
  const ProgramSession({
    required this.session,
    required this.block,
    required this.blockWeek,
    required this.variant,
    required this.deload,
    required this.weekStart,
  });

  final SessionInfo session;
  final int block;
  final int blockWeek;
  final String variant;
  final bool deload;
  final DateTime weekStart;

  String get id => session.id;
  DayType get day => session.dayType;
  DateTime get date => session.date;
  List<String> get mainExerciseIds => session.mainExerciseIds;
}

/// Where the athlete stands in the programme on [date].
class ProgramState {
  const ProgramState({
    required this.date,
    required this.day,
    required this.blockNumber,
    required this.blockWeek,
    this.blockLength = defaultBlockLength,
    this.deload = false,
    this.deloadReason,
    this.variants = const {},
    this.completedSessions = 0,
    this.weeksTraining = 0,
    this.history = const [],
  });

  /// Block 1, week 1, all variants A.
  factory ProgramState.initial(DayType day, DateTime date) =>
      ProgramState(date: dateOnly(date), day: day, blockNumber: 1, blockWeek: 1);

  static const int defaultBlockLength = 6;

  /// A gap of at least this many days starts a new block.
  static const int gapDays = 14;

  /// Day the state was computed for (the plan date).
  final DateTime date;

  /// Day type the state is focused on (the next session's day type by default).
  final DayType day;
  final int blockNumber;
  final int blockWeek;
  final int blockLength;
  final bool deload;

  /// Why this is a deload (planned week or early fatigue trigger); null when not deloading.
  final String? deloadReason;

  /// Next variant ("A"/"B") per day type.
  final Map<DayType, String> variants;
  final int completedSessions;

  /// Distinct ISO weeks with at least one session.
  final int weeksTraining;

  /// Past sessions with their program position, oldest first.
  final List<ProgramSession> history;

  String variantFor(DayType d) => variants[d] ?? 'A';
  String get variant => variantFor(day);
  String get phase => deload ? 'deload' : 'accumulation';

  /// Target reps in reserve: week 1 → 3, weeks 2–3 → 2, weeks 4–5 → 1 (1–2), deload → 3 (3–4).
  int get targetRir => deload || blockWeek <= 1 ? 3 : (blockWeek <= 3 ? 2 : 1);
  String get rirLabel => deload ? '3–4' : (blockWeek <= 1 ? '3' : (blockWeek <= 3 ? '2' : '1–2'));

  /// "Block 2 · Week 3 · Push B".
  String labelFor(DayType d) => 'Block $blockNumber · Week $blockWeek · ${d.label} ${variantFor(d)}';
  String get label => labelFor(day);

  String focusFor(DayType d) => templateFor(d, variantFor(d)).focus;
  String get variantFocus => focusFor(day);

  ProgramState forDay(DayType d) => d == day ? this : _copy(day: d);

  /// Same position with [variant] forced for [d] (e.g. the user asks for "Push B" now); [d] becomes the focus day.
  ProgramState copyVariant(DayType d, String variant) => _copy(day: d, variants: {...variants, d: variant});

  ProgramState _copy({DayType? day, Map<DayType, String>? variants}) => ProgramState(
        date: date,
        day: day ?? this.day,
        blockNumber: blockNumber,
        blockWeek: blockWeek,
        blockLength: blockLength,
        deload: deload,
        deloadReason: deloadReason,
        variants: variants ?? this.variants,
        completedSessions: completedSessions,
        weeksTraining: weeksTraining,
        history: history,
      );

  /// Week starts of past deload weeks (for `analyzeBalance(deloadWeeks: …)`).
  Set<DateTime> get deloadWeekStarts => {for (final s in history) if (s.deload) s.weekStart};

  /// Ids of past deload sessions (excluded from progression history).
  Set<String> get deloadSessionIds => {for (final s in history) if (s.deload) s.id};

  /// Past sessions of [block] (default: the current block), optionally filtered, most recent first.
  List<ProgramSession> sessionsIn({int? block, DayType? day, String? variant}) => history.reversed
      .where((s) =>
          s.block == (block ?? blockNumber) &&
          (day == null || s.day == day) &&
          (variant == null || s.variant == variant))
      .toList();

  /// `program` object of the coach brief (docs/IMPROVEMENT-PLAN.md §4.4).
  Map<String, dynamic> toBrief({DayType? day}) {
    final d = day ?? this.day;
    return {
      'blockNumber': blockNumber,
      'blockWeek': blockWeek,
      'blockLength': blockLength,
      'phase': phase,
      'deload': deload,
      'deloadReason': deloadReason,
      'variant': variantFor(d),
      'variantFocus': focusFor(d),
      'targetRir': targetRir,
      'completedSessions': completedSessions,
      'weeksTraining': weeksTraining,
    };
  }
}

/// Replays [sessions] and returns the program position for [now] (default today) and [day] (default: the next
/// day type in the Push → Pull → Legs rotation).
///
/// * A block lasts [blockLength] training weeks (ISO weeks with ≥ 1 session); a gap of ≥ 14 days, or the week
///   after a deload week, starts a new block (variants reset to A).
/// * Variants alternate per exposure of each day type (A, B, A, …); a session's `meta.variant` is trusted.
/// * Deload: planned in the last block week, or early (from block week 2, once per block) when the average effort of
///   the last 3 sessions is ≥ 8.5, the last two ratings are ≤ 2, or ≥ 2 anchor lifts are regressing ([trends];
///   anchors = first compound strength exercise of each session, which needs [catalog]). A deload lasts for the
///   rest of that ISO week; the next week starts a new block.
ProgramState computeProgramState(
  List<SessionInfo> sessions, {
  DateTime? now,
  DayType? day,
  Map<String, ExerciseTrend> trends = const {},
  Catalog? catalog,
  int blockLength = ProgramState.defaultBlockLength,
}) {
  final today = dateOnly(now ?? DateTime.now());
  final sorted = sessions.where((s) => !dateOnly(s.date).isAfter(today)).toList()
    ..sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.id.compareTo(b.id);
    });

  var block = 0;
  var weeks = <DateTime>[];
  DateTime? lastDate;
  DateTime? deloadWeek;
  final lastVariant = <DayType, String>{};
  final annotated = <ProgramSession>[];

  bool startsNewBlock(DateTime d) {
    if (block == 0 || lastDate == null) return true;
    if (daysBetween(lastDate, d) >= ProgramState.gapDays) return true;
    final ws = startOfWeek(d);
    if (weeks.contains(ws)) return false;
    if (deloadWeek != null) return true;
    return weeks.length >= blockLength;
  }

  for (final s in sorted) {
    final d = dateOnly(s.date);
    final ws = startOfWeek(d);
    if (startsNewBlock(d)) {
      block++;
      weeks = [];
      deloadWeek = null;
      lastVariant.clear();
    }
    if (!weeks.contains(ws)) weeks.add(ws);
    final week = weeks.indexOf(ws) + 1;
    final variant = switch (s.meta?.variant) {
      'A' => 'A',
      'B' => 'B',
      _ => lastVariant[s.dayType] == 'A' ? 'B' : 'A',
    };
    lastVariant[s.dayType] = variant;
    final meta = s.meta;
    final deload = meta != null && !meta.isEmpty ? meta.deload : week >= blockLength;
    if (deload) deloadWeek = ws;
    annotated.add(ProgramSession(
      session: s,
      block: block,
      blockWeek: week,
      variant: variant,
      deload: deload,
      weekStart: ws,
    ));
    lastDate = d;
  }

  final targetDay = day ?? (sorted.isEmpty ? DayType.push : sorted.last.dayType.next);
  final weeksTraining = {for (final s in annotated) s.weekStart}.length;
  final ws = startOfWeek(today);

  if (startsNewBlock(today)) {
    return ProgramState(
      date: today,
      day: targetDay,
      blockNumber: block + 1,
      blockWeek: 1,
      blockLength: blockLength,
      variants: const {},
      completedSessions: sorted.length,
      weeksTraining: weeksTraining,
      history: annotated,
    );
  }

  final week = weeks.contains(ws) ? weeks.indexOf(ws) + 1 : weeks.length + 1;
  final variants = {
    for (final d in DayType.values) d: lastVariant[d] == 'A' ? 'B' : 'A',
  };

  String? reason;
  if (deloadWeek == ws) {
    reason = week >= blockLength ? 'Planned deload (week $week of $blockLength)' : 'Deload week (fatigue)';
  } else if (week >= blockLength) {
    reason = 'Planned deload (week $week of $blockLength)';
  } else if (week >= 2) {
    final blockSessions = annotated.reversed.where((s) => s.block == block && !s.deload).toList();
    final efforts = blockSessions.map((s) => s.session.effort).whereType<int>().take(3).toList();
    final ratings = blockSessions.take(2).map((s) => s.session.rating).toList();
    if (efforts.length == 3 && efforts.reduce((a, b) => a + b) / 3 >= 8.5) {
      final avg = efforts.reduce((a, b) => a + b) / 3;
      reason = 'Early deload: average effort ${avg.toStringAsFixed(1)} over the last 3 sessions';
    } else if (ratings.length == 2 && ratings.every((r) => r != null && r <= 2)) {
      reason = 'Early deload: session rating ≤ 2 twice in a row';
    } else if (trends.isNotEmpty) {
      final latest = <String, ProgramSession>{};
      for (final s in blockSessions) {
        latest.putIfAbsent('${s.day.name}-${s.variant}', () => s);
      }
      final anchors = <String>{};
      for (final s in latest.values) {
        final a = _anchorOf(s.session, catalog);
        if (a != null) anchors.add(a);
      }
      final regressing = anchors.where((a) => trends[a] == ExerciseTrend.regressing).toList()..sort();
      if (regressing.length >= 2) {
        final names = regressing.map((id) => catalog?.exerciseName(id) ?? id).join(', ');
        reason = 'Early deload: ${regressing.length} anchor lifts regressing ($names)';
      }
    }
  }

  return ProgramState(
    date: today,
    day: targetDay,
    blockNumber: block,
    blockWeek: week,
    blockLength: blockLength,
    deload: reason != null,
    deloadReason: reason,
    variants: variants,
    completedSessions: sorted.length,
    weeksTraining: weeksTraining,
    history: annotated,
  );
}

String? _anchorOf(SessionInfo s, Catalog? catalog) {
  if (s.mainExerciseIds.isEmpty) return null;
  if (catalog == null) return s.mainExerciseIds.first;
  for (final id in s.mainExerciseIds) {
    final e = catalog.exercise(id);
    if (e != null && e.category == 'strength' && e.compound) return id;
  }
  return null;
}
