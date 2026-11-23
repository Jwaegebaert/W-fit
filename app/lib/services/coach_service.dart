import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/api/sync_service.dart' show feedbackToJson;
import '../data/db/database.dart';
import '../data/repositories/repository.dart';
import '../domain/catalog.dart';
import '../domain/limitations.dart';
import '../domain/muscles.dart';
import '../domain/plan.dart';
import '../domain/program.dart';
import '../domain/progression.dart';
import '../domain/rule_engine.dart';
import '../domain/stats.dart';
import '../domain/training_load.dart';
import '../providers.dart';

class SwapSuggestion {
  const SwapSuggestion({required this.exercise, required this.why, this.item, required this.fromAi});

  final Exercise exercise;
  final String why;

  /// Prescription suggested by the AI (null for rule-based suggestions → catalog defaults).
  final PlanItem? item;
  final bool fromAi;
}

class Insights {
  const Insights({
    required this.summary,
    required this.highlights,
    required this.recommendations,
    required this.nextFocus,
    required this.source,
    this.focusMuscles = const [],
    this.generatedAt,
  });

  factory Insights.fromJson(Map<String, dynamic> j) => Insights(
        summary: j['summary'] as String? ?? '',
        highlights: (j['highlights'] as List? ?? const []).cast<String>(),
        recommendations: (j['recommendations'] as List? ?? const []).cast<String>(),
        nextFocus: j['nextFocus'] as String? ?? '',
        focusMuscles: (j['focusMuscles'] as List? ?? const []).whereType<String>().toList(),
        source: j['source'] as String? ?? 'ai',
        generatedAt: j['generatedAt'] == null ? null : DateTime.tryParse(j['generatedAt'] as String),
      );

  final String summary;
  final List<String> highlights;
  final List<String> recommendations;
  final String nextFocus;

  /// Tracked muscle ids the coach wants to emphasise next (≤ 3).
  final List<String> focusMuscles;
  final String source;
  final DateTime? generatedAt;
}

/// Everything the coach knows on [date]: shared by plan generation, the AI brief and the balance UI.
class CoachSnapshot {
  const CoachSnapshot({
    required this.date,
    required this.catalog,
    required this.profile,
    required this.equipment,
    required this.preferences,
    required this.feedback,
    required this.sessions,
    required this.sessionInfo,
    required this.sets,
    required this.bodyWeightKg,
    required this.program,
    required this.weeks,
    required this.balance,
    required this.policy,
    required this.trends,
    required this.history,
  });

  final DateTime date;
  final Catalog catalog;
  final Profile profile;
  final Map<String, bool> equipment;
  final Map<String, String> preferences;

  /// Active entries plus everything from the last 90 days.
  final List<FeedbackRecord> feedback;

  /// Completed sessions, newest first.
  final List<WorkoutSession> sessions;
  final List<SessionInfo> sessionInfo;

  /// Completed sets of the last 12 weeks.
  final List<LoggedSet> sets;
  final double? bodyWeightKg;
  final ProgramState program;
  final List<MuscleWeek> weeks;
  final BalanceReport balance;
  final LimitationPolicy policy;
  final Map<String, ExerciseTrend> trends;
  final Map<String, List<List<LoggedSet>>> history;

  TrainingContext context({Set<String> occupied = const {}}) => TrainingContext(
        catalog: catalog,
        equipmentAvailability: equipment,
        occupiedEquipment: occupied,
        preferences: preferences,
        experience: profile.experience,
        restScale: restScaleFor(profile.restMode),
        cooldownStretches: profile.cooldownStretches,
        limitations: policy,
        program: program,
        balance: balance,
        trends: trends,
        history: history,
      );
}

/// Result of [CoachService.reportIssue]: the instant on-device changes and, when the AI is configured, the coach's
/// reply (never throws; failures resolve to an explanatory sentence).
class IssueOutcome {
  const IssueOutcome({required this.feedbackId, required this.changes, this.coachReply});

  final String feedbackId;
  final List<PlanChange> changes;
  final Future<String>? coachReply;
}

/// Coordinates the training engine, the feedback memory and the optional (stateless) AI backend.
class CoachService {
  CoachService(this.ref);

  final Ref ref;

  static const insightsKey = 'ai_insights';

  Repository get _repo => ref.read(repositoryProvider);
  Catalog get _catalog => ref.read(catalogProvider);
  ApiClient get _api => ref.read(apiClientProvider);

  void _syncSoon() => unawaited(ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true));

  Future<DayType> nextDayType() async {
    final sessions = await _repo.completedSessions();
    if (sessions.isEmpty) return DayType.push;
    return DayType.parse(sessions.first.dayType).next;
  }

  /// Next training date (today if it's a training day and not trained yet).
  Future<DateTime> nextTrainingDate() async {
    final profile = await _repo.getProfile();
    final sessions = await _repo.completedSessions();
    final today = DateTime.now();
    final trainedToday = sessions.any((s) => dateKey(s.startedAt.toLocal()) == dateKey(today));
    final dates = upcomingTrainingDates(parseDays(profile.trainingDays), count: 2, from: today);
    if (trainedToday && dates.length > 1 && dateKey(dates.first) == dateKey(today)) return dates[1];
    return dates.first;
  }

  /// Loads profile, gym, preferences, feedback, sessions and 12 weeks of sets and derives the program position,
  /// muscle balance, limitations and trends for [date] (default today) and [day] (default: next in rotation).
  Future<CoachSnapshot> snapshot({DateTime? date, DayType? day}) async {
    final planDate = dateOnly(date ?? DateTime.now());
    final catalog = _catalog;
    final completed = await _repo.completedSessions();
    final sets = await _repo.loggedSets(since: addDays(planDate, -84));
    final plans = {for (final p in await _repo.plannedHistory()) p.id: p};
    final mainIds = <String, List<String>>{};
    for (final s in sets) {
      if (s.section != Section.main.name) continue;
      final ids = mainIds.putIfAbsent(s.sessionId, () => []);
      if (!ids.contains(s.exerciseId)) ids.add(s.exerciseId);
    }
    final infos = [
      for (final s in completed) _sessionInfo(s, s.plannedWorkoutId == null ? null : plans[s.plannedWorkoutId], mainIds[s.id]),
    ];
    final entries = {
      for (final f in await _repo.feedbackSince(addDays(planDate, -90))) f.id: f,
      for (final f in await _repo.activeFeedback()) f.id: f,
    };
    final records = [for (final f in entries.values) FeedbackRecord.fromJson(feedbackToJson(f))];

    final pre = computeProgramState(infos, now: planDate, day: day);
    final trends = exerciseTrends(sets, excludeSessionIds: pre.deloadSessionIds);
    final program = computeProgramState(infos, now: planDate, day: day, trends: trends, catalog: catalog);
    final weeks = weeklyMuscleVolume(sets, catalog, weeks: 8, now: planDate);
    return CoachSnapshot(
      date: planDate,
      catalog: catalog,
      profile: await _repo.getProfile(),
      equipment: await _repo.getEquipment(),
      preferences: await _repo.getPreferences(),
      feedback: records,
      sessions: completed,
      sessionInfo: infos,
      sets: sets,
      bodyWeightKg: await _repo.latestBodyWeight(),
      program: program,
      weeks: weeks,
      balance: analyzeBalance(weeks, sets, catalog, now: planDate, deloadWeeks: program.deloadWeekStarts),
      policy: LimitationPolicy.fromFeedback(records, catalog, now: planDate),
      trends: trends,
      history: groupHistory(sets),
    );
  }

  static SessionInfo _sessionInfo(WorkoutSession s, PlannedWorkout? plan, List<String>? mainIds) {
    final meta = plan == null ? null : PlanMeta.decode(plan.metaJson);
    return SessionInfo(
      id: s.id,
      date: s.startedAt.toLocal(),
      dayType: DayType.parse(s.dayType),
      rating: s.rating,
      effort: s.perceivedEffort,
      mainExerciseIds: mainIds ??
          [
            if (plan != null)
              for (final b in Repository.decodeBlocks(plan.blocksJson))
                if (b.section == Section.main) ...b.items.map((i) => i.exerciseId),
          ],
      meta: meta == null || meta.isEmpty ? null : meta,
    );
  }

  /// Coach brief (docs/IMPROVEMENT-PLAN.md §4.4) with the documented list limits.
  Map<String, dynamic> buildBrief(CoachSnapshot s, {DayType? day, Set<String> occupied = const {}}) {
    final p = s.profile;
    String clip(String v, int n) => v.length <= n ? v : v.substring(0, n);
    List<String> prefs(String v) => [for (final e in s.preferences.entries) if (e.value == v) e.key].take(100).toList();
    final limits = s.policy.toBrief(now: s.date);
    final balance = s.balance.toBrief();
    balance['priorities'] = (balance['priorities'] as List).take(8).toList();
    balance['notes'] = s.balance.notes.take(8).toList();
    final infoById = {for (final i in s.sessionInfo) i.id: i};
    final weekly = weeklyStats(s.sessions.map((x) => x.startedAt.toLocal()), s.sets, weeks: 8, now: s.date);
    return {
      'today': isoDate(s.date),
      'profile': {
        'experience': p.experience,
        'goals': clip(p.goals, 500),
        'sessionMinutes': p.sessionMinutes,
        'includeCore': p.includeCore,
        'restMode': p.restMode,
        'cooldownStretches': p.cooldownStretches,
        'trainingDays': parseDays(p.trainingDays),
        'age': p.birthYear == null ? null : s.date.year - p.birthYear!,
        'heightCm': p.heightCm,
        'bodyweightKg': s.bodyWeightKg,
        'injuries': clip(p.injuries, 1000),
        'notes': clip(p.notes, 500),
      },
      'equipment': {
        'unavailable': [for (final e in s.equipment.entries) if (!e.value) e.key].take(100).toList(),
        'occupied': occupied.take(100).toList(),
      },
      'preferences': {'liked': prefs('liked'), 'disliked': prefs('disliked'), 'banned': prefs('banned')},
      'limitations': (limits['limitations'] as List).take(20).toList(),
      'exerciseFeedback': (limits['exerciseFeedback'] as List).take(30).toList(),
      'program': s.program.toBrief(day: day),
      'balance': balance,
      'exerciseHistory': exerciseHistoryBrief(s.sets, catalog: s.catalog, now: s.date),
      'recentSessions': [
        for (final x in s.sessions.take(9))
          {
            'date': isoDate(x.startedAt),
            'dayType': x.dayType,
            'title': x.title,
            'rating': x.rating,
            'effort': x.perceivedEffort,
            'durationMin': x.durationSeconds == null ? null : (x.durationSeconds! / 60).round(),
            'notes': clip(x.notes, 500),
            'exercises': (infoById[x.id]?.mainExerciseIds ?? const <String>[]).take(15).toList(),
          },
      ],
      'weekly': [
        for (final w in weekly)
          {'weekStart': isoDate(w.weekStart), 'sessions': w.sessions, 'sets': w.sets, 'volumeKg': w.volume.round()},
      ],
    };
  }

  // ---------------- plans ----------------

  /// Returns the open plan for [date], creating a rule-based one if none exists.
  Future<PlannedWorkout> ensurePlan(DateTime date) async {
    final existing = await _repo.plannedForDate(date);
    if (existing != null) return existing;
    final id = await generateWithRules(date);
    return (await _repo.plannedById(id))!;
  }

  GeneratedWorkout _draft(CoachSnapshot s, DayType day, Set<String> occupied) =>
      RuleEngine(s.context(occupied: occupied)).generate(
        day: day,
        date: s.date,
        sessionMinutes: s.profile.sessionMinutes,
        includeCore: s.profile.includeCore,
      );

  Future<String> generateWithRules(DateTime date, {DayType? day}) async {
    final dayType = day ?? await nextDayType();
    final w = _draft(await snapshot(date: date, day: dayType), dayType, ref.read(occupiedEquipmentProvider));
    return _repo.savePlanned(
      date: date,
      day: dayType,
      title: w.title,
      source: 'rules',
      coachNote: w.coachNote,
      blocks: w.blocks,
      estimatedMinutes: w.estimatedMinutes,
      metaJson: w.meta.encode(),
    );
  }

  /// Asks the AI coach to refine the rule-engine draft. With [replaceId] the result overwrites that plan in place
  /// (skipped when it is no longer open). Throws [ApiException] so the UI can explain and keep the rules plan.
  Future<String> generateWithAi(DateTime date, {DayType? day, String note = '', String? replaceId}) async {
    final dayType = day ?? await nextDayType();
    final snap = await snapshot(date: date, day: dayType);
    final occupied = ref.read(occupiedEquipmentProvider);
    final draft = _draft(snap, dayType, occupied);
    final res = await _api.generateWorkout({
      'dayType': dayType.name,
      'date': dateKey(date),
      'sessionMinutes': snap.profile.sessionMinutes,
      'includeCore': snap.profile.includeCore,
      'userNote': note,
      'brief': buildBrief(snap, day: dayType, occupied: occupied),
      'draft': {
        'title': draft.title,
        'blocks': draft.blocks.map((b) => b.toJson()).toList(),
        'meta': draft.meta.toJson(),
      },
    });
    final w = res['workout'] as Map<String, dynamic>;
    final meta = _meta(w['meta']);
    final blocks = _cleanBlocks(w['blocks'], snap, deload: meta.deload);
    if (!blocks.any((b) => b.section == Section.main)) {
      throw ApiException('ai_unavailable', 'The AI coach returned an unusable workout.');
    }
    if (replaceId != null && !await _isOpen(replaceId)) return replaceId;
    final id = await _repo.savePlanned(
      id: replaceId ?? w['id'] as String?,
      date: date,
      day: dayType,
      title: w['title'] as String? ?? draft.title,
      source: 'ai',
      coachNote: w['coachNote'] as String? ?? '',
      blocks: blocks,
      metaJson: meta.encode(),
    );
    _syncSoon();
    return id;
  }

  /// After the "Rest between sets" or "Cool-down" setting changed: rescales the rest of every open plan and rebuilds
  /// its cool-down with the new number of stretches. Other exercises (also AI-chosen ones) stay as they are.
  Future<void> applyTrainingPrefs({required String oldRestMode, required int oldCooldownStretches}) async {
    final profile = await _repo.getProfile();
    final ratio = restScaleFor(profile.restMode) / restScaleFor(oldRestMode);
    final cooldownChanged = profile.cooldownStretches != oldCooldownStretches;
    if (ratio == 1 && !cooldownChanged) return;
    int rescale(int rest, Section section) {
      if (ratio == 1 || rest <= 0) return rest;
      final r = (rest * ratio / 5).round() * 5;
      return section == Section.main ? r.clamp(30, 240) : r.clamp(0, 180);
    }

    for (final p in await _repo.plannedHistory(from: DateTime.now())) {
      if (p.status != 'planned' || !await _isOpen(p.id)) continue;
      final date = parseDateKey(p.date);
      final day = DayType.parse(p.dayType);
      final blocks = [
        for (final b in Repository.decodeBlocks(p.blocksJson))
          if (!cooldownChanged || b.section != Section.cooldown)
            PlanBlock(section: b.section, items: [
              for (final i in b.items) i.copyWith(restSeconds: rescale(i.restSeconds, b.section)),
            ]),
      ];
      if (cooldownChanged) {
        final draft = _draft(await snapshot(date: date, day: day), day, const {});
        blocks.addAll(draft.blocks.where((b) => b.section == Section.cooldown));
      }
      await _repo.updatePlannedBlocks(p.id, blocks);
    }
    _syncSoon();
  }

  /// A plan that can still be changed: planned, not deleted and not being trained right now.
  Future<bool> _isOpen(String plannedId) async {
    final p = await _repo.plannedById(plannedId);
    if (p == null || p.deleted || p.status != 'planned') return false;
    final active = await _repo.watchActiveSession().first;
    return active?.plannedWorkoutId != plannedId;
  }

  static PlanMeta _meta(dynamic m) => m is Map ? PlanMeta.fromJson(m.cast<String, dynamic>()) : const PlanMeta();

  /// Keeps known exercises the local limitation policy allows and fills missing target weights from history.
  List<PlanBlock> _cleanBlocks(dynamic raw, CoachSnapshot s, {bool deload = false}) {
    final blocks = <PlanBlock>[];
    for (final r in (raw as List? ?? const []).whereType<Map<String, dynamic>>()) {
      final b = PlanBlock.fromJson(r);
      final items = <PlanItem>[];
      for (final i in b.items) {
        final e = s.catalog.exercise(i.exerciseId);
        if (e == null || s.policy.excludes(e)) continue;
        final h = s.history[e.id] ?? const [];
        final item = i.copyWith(perSide: e.unilateral);
        items.add(item.targetWeightKg == null && e.isWeighted && h.isNotEmpty
            ? item.copyWith(
                targetWeightKg: adviseProgression(e, h, repMin: i.repMin, repMax: i.repMax, deload: deload).weightKg)
            : item);
      }
      // The cool-down follows the athlete's setting (0 = no cool-down block).
      if (b.section == Section.cooldown) {
        final n = s.profile.cooldownStretches.clamp(0, RuleEngine.cooldownSize);
        if (items.length > n) items.removeRange(n, items.length);
      }
      if (items.isNotEmpty) blocks.add(PlanBlock(section: b.section, items: items));
    }
    return blocks;
  }

  /// After a finished workout: make sure the next session has a rules plan, then let the AI refine it in the
  /// background (once per date). Never throws.
  Future<void> pregenerateNext() async {
    try {
      final date = await nextTrainingDate();
      final plan = await ensurePlan(date);
      if (!_api.config.isConfigured || plan.source == 'ai') return;
      final key = 'pregen_${dateKey(date)}';
      if (await _repo.db.getValue(key) != null) return;
      await _repo.db.setValue(key, DateTime.now().toUtc().toIso8601String());
      ref.read(coachPreparingProvider.notifier).prepare(plan.date);
      try {
        final current = await _repo.plannedForDate(date) ?? plan;
        await generateWithAi(date, day: DayType.parse(current.dayType), replaceId: current.id);
      } finally {
        ref.read(coachPreparingProvider.notifier).prepare(null);
      }
    } catch (_) {
      // Best effort: the rules plan stays.
    }
  }

  // ---------------- feedback / report an issue ----------------

  /// Records a report, applies it instantly to every open plan from today on and, when the AI is configured, asks
  /// the coach to interpret it (more feedback entries and a refined plan for [plannedId] or the next plan).
  Future<IssueOutcome> reportIssue({
    required String kind,
    String? region,
    int? severity,
    String? exerciseId,
    String? equipmentId,
    String note = '',
    String? plannedId,
    String? sessionId,
  }) async {
    final painLike = kind == 'pain' || kind == 'discomfort';
    final text = note.trim().isEmpty ? _issueSentence(kind, region, severity, exerciseId, equipmentId) : note.trim();
    final id = await _repo.addFeedback(
      kind: kind,
      region: painLike ? region : null,
      severity: painLike ? (severity ?? (kind == 'pain' ? 2 : 1)) : null,
      exerciseId: exerciseId,
      sessionId: sessionId,
      note: text,
    );
    await _applyFeedbackSideEffects(kind, exerciseId, equipmentId);
    final changes = await _adjustOpenPlans();
    _syncSoon();
    final reply = _api.config.isConfigured
        ? _coachReview(message: text, exerciseId: exerciseId, plannedId: plannedId, inSession: sessionId != null)
        : null;
    return IssueOutcome(feedbackId: id, changes: changes, coachReply: reply);
  }

  String _issueSentence(String kind, String? region, int? severity, String? exerciseId, String? equipmentId) {
    final exercise = exerciseId == null ? null : _catalog.exerciseName(exerciseId);
    final where = region == null ? (exercise == null ? '' : ' during $exercise') : ' in my ${prettyRegion(region).toLowerCase()}';
    final level = switch (severity) { 1 => 'Mild', 3 => 'Severe', _ => 'Moderate' };
    return switch (kind) {
      'pain' || 'discomfort' => '$level $kind$where${region != null && exercise != null ? ' ($exercise)' : ''}.',
      'unavailable' =>
        '${equipmentId == null ? exercise ?? 'Equipment' : _catalog.equipmentById(equipmentId)?.name ?? equipmentId} is unavailable.',
      'too_easy' => '${exercise ?? 'The exercise'} felt too easy.',
      'too_hard' => '${exercise ?? 'The exercise'} felt too hard.',
      'dislike' => "${exercise ?? 'The exercise'} doesn't feel right.",
      'like' => 'I like ${exercise ?? 'this exercise'}.',
      _ => 'Note${exercise == null ? '' : ' about $exercise'}.',
    };
  }

  Future<void> _applyFeedbackSideEffects(String kind, String? exerciseId, String? equipmentId) async {
    if (exerciseId != null && (kind == 'like' || kind == 'dislike')) {
      final current = (await _repo.getPreferences())[exerciseId];
      if (current != 'banned') await _repo.setPreference(exerciseId, kind == 'like' ? 'liked' : 'disliked');
    }
    if (kind == 'unavailable' && equipmentId != null) await markUnavailable([equipmentId]);
  }

  /// Re-evaluates every open plan from today on against the current limitations and equipment.
  Future<List<PlanChange>> _adjustOpenPlans() async {
    final plans = [
      for (final p in await _repo.plannedHistory(from: DateTime.now()))
        if (p.status == 'planned') p,
    ];
    if (plans.isEmpty) return const [];
    final engine = RuleEngine((await snapshot()).context());
    final all = <PlanChange>[];
    for (final p in plans) {
      final adj = engine.adjustForLimitations(Repository.decodeBlocks(p.blocksJson), DayType.parse(p.dayType));
      if (!adj.changed) continue;
      await _repo.updatePlannedBlocks(p.id, adj.blocks,
          metaJson: PlanMeta.decode(p.metaJson).withChanges(adj.changes).encode());
      all.addAll(adj.changes);
    }
    final seen = <String>{};
    return [for (final c in all) if (seen.add('${c.from}>${c.to}')) c];
  }

  Future<String> _coachReview({
    required String message,
    String? exerciseId,
    String? plannedId,
    required bool inSession,
  }) async {
    try {
      final target = plannedId != null
          ? await _repo.plannedById(plannedId)
          : await _repo.plannedForDate(await nextTrainingDate());
      final open = target != null && !target.deleted && target.status == 'planned';
      final date = open ? parseDateKey(target.date) : null;
      final day = open ? DayType.parse(target.dayType) : null;
      final snap = await snapshot(date: date, day: day);
      final res = await _api.adjust({
        'message': message,
        'exerciseId': exerciseId,
        'sessionInProgress': inSession,
        'plan': open
            ? {
                'id': target.id,
                'date': target.date,
                'dayType': target.dayType,
                'title': target.title,
                'blocks': jsonDecode(target.blocksJson),
                'meta': PlanMeta.decode(target.metaJson).toJson(),
              }
            : null,
        'brief': buildBrief(snap, day: day),
      });
      if (await _applyCoachFeedback(res['feedback'])) await _adjustOpenPlans();
      final plan = res['plan'];
      if (open && plan is Map<String, dynamic>) {
        final meta = _meta(plan['meta']);
        final blocks = _cleanBlocks(plan['blocks'], await snapshot(date: date, day: day), deload: meta.deload);
        final current = await _repo.plannedById(target.id);
        if (blocks.any((b) => b.section == Section.main) && current != null && current.status == 'planned') {
          await _repo.savePlanned(
            id: target.id,
            date: date!,
            day: day!,
            title: plan['title'] as String? ?? current.title,
            source: 'ai',
            coachNote: plan['coachNote'] as String? ?? current.coachNote,
            blocks: blocks,
            metaJson: meta.encode(),
          );
        }
      }
      _syncSoon();
      final reply = (res['reply'] as String? ?? '').trim();
      return reply.isEmpty ? 'Your coach reviewed the report.' : reply;
    } on ApiException catch (e) {
      return 'The coach could not review this right now (${e.message}). Your plans were already adjusted.';
    } catch (_) {
      return 'The coach could not review this right now. Your plans were already adjusted.';
    }
  }

  /// Stores feedback interpreted by the coach (skipping duplicates of active entries). Returns true if any was new.
  Future<bool> _applyCoachFeedback(dynamic list) async {
    final active = await _repo.activeFeedback();
    var added = false;
    for (final f in (list as List? ?? const []).whereType<Map<String, dynamic>>()) {
      final kind = f['kind'] as String? ?? 'note';
      final region = f['region'] as String?;
      final exerciseId = f['exerciseId'] as String?;
      final equipmentId = f['equipmentId'] as String?;
      if (!active.any((a) => a.kind == kind && a.region == region && a.exerciseId == exerciseId)) {
        final days = (f['reviewInDays'] as num?)?.toInt();
        await _repo.addFeedback(
          kind: kind,
          region: region,
          severity: (f['severity'] as num?)?.toInt(),
          exerciseId: exerciseId,
          note: f['note'] as String? ?? '',
          source: 'coach',
          reviewOn: days == null ? null : DateTime.now().add(Duration(days: days)),
        );
        added = true;
      }
      await _applyFeedbackSideEffects(kind, exerciseId, equipmentId);
      if (equipmentId != null) added = true;
    }
    return added;
  }

  Future<void> resolveIssue(String id) async {
    await _repo.resolveFeedback(id);
    _syncSoon();
  }

  Future<void> keepIssue(String id) async {
    await _repo.postponeCheckIn(id);
    _syncSoon();
  }

  // ---------------- progression & swaps ----------------

  Future<ProgressionAdvice> advice(String exerciseId, PlanItem item, {String? excludeSessionId}) async {
    final e = _catalog.exercise(exerciseId);
    if (e == null) return const ProgressionAdvice(message: '');
    final history = await _repo.exerciseHistory(exerciseId, excludeSessionId: excludeSessionId);
    return adviseProgression(e, history, repMin: item.repMin, repMax: item.repMax);
  }

  Future<List<SwapSuggestion>> ruleSwaps(
    String exerciseId, {
    required DayType day,
    Set<String> exclude = const {},
    Set<String> extraUnavailable = const {},
  }) async {
    final original = _catalog.exercise(exerciseId);
    if (original == null) return const [];
    var ctx = (await snapshot(day: day)).context(occupied: ref.read(occupiedEquipmentProvider));
    if (extraUnavailable.isNotEmpty) {
      ctx = ctx.copyWith(equipmentAvailability: {
        ...ctx.equipmentAvailability,
        for (final id in extraUnavailable) id: false,
      });
    }
    return RuleEngine(ctx)
        .rankSwaps(original, exclude: exclude, day: day)
        .map((c) => SwapSuggestion(exercise: c.exercise, why: c.why, fromAi: false))
        .toList();
  }

  Future<List<SwapSuggestion>> aiSwaps(
    String exerciseId, {
    required DayType day,
    required Section section,
    required String reason,
    Set<String> exclude = const {},
    String note = '',
  }) async {
    final occupied = ref.read(occupiedEquipmentProvider);
    final res = await _api.swap({
      'exerciseId': exerciseId,
      'reason': reason,
      'dayType': day.name,
      'section': section.name,
      'excludeExerciseIds': exclude.toList(),
      'occupiedEquipment': occupied.toList(),
      'note': note,
      'brief': buildBrief(await snapshot(day: day), day: day, occupied: occupied),
    });
    final list = (res['suggestions'] as List? ?? const []).cast<Map<String, dynamic>>();
    final fromAi = res['source'] == 'ai';
    return [
      for (final s in list)
        if (_catalog.exercise(s['exerciseId'] as String) case final e?)
          SwapSuggestion(
            exercise: e,
            why: s['why'] as String? ?? '',
            fromAi: fromAi,
            item: PlanItem(
              exerciseId: e.id,
              sets: (s['sets'] as num?)?.toInt() ?? e.sets,
              repMin: e.isTimed ? null : (s['repMin'] as num?)?.toInt() ?? e.repMin,
              repMax: e.isTimed ? null : (s['repMax'] as num?)?.toInt() ?? e.repMax,
              durationSeconds: e.durationSeconds,
              restSeconds: (s['restSeconds'] as num?)?.toInt() ?? e.rest,
              perSide: e.unilateral,
            ),
          ),
    ];
  }

  /// Replaces one item in a planned workout and persists it.
  Future<void> applySwap(String plannedId, int blockIndex, int itemIndex, SwapSuggestion s) async {
    final planned = await _repo.plannedById(plannedId);
    if (planned == null) return;
    final blocks = Repository.decodeBlocks(planned.blocksJson);
    var item = s.item ?? PlanItem.fromExercise(s.exercise);
    if (s.exercise.isWeighted) {
      final h = await _repo.exerciseHistory(s.exercise.id, maxSessions: 2);
      final w = h.isEmpty ? null : adviseProgression(s.exercise, h).weightKg;
      item = item.copyWith(targetWeightKg: w, clearWeight: w == null);
    } else {
      item = item.copyWith(clearWeight: true);
    }
    final items = [...blocks[blockIndex].items]..[itemIndex] = item;
    blocks[blockIndex] = PlanBlock(section: blocks[blockIndex].section, items: items);
    await _repo.updatePlannedBlocks(plannedId, blocks);
  }

  /// Removes one item from a planned workout.
  Future<void> removeItem(String plannedId, int blockIndex, int itemIndex) async {
    final planned = await _repo.plannedById(plannedId);
    if (planned == null) return;
    final blocks = Repository.decodeBlocks(planned.blocksJson);
    final items = [...blocks[blockIndex].items]..removeAt(itemIndex);
    blocks[blockIndex] = PlanBlock(section: blocks[blockIndex].section, items: items);
    await _repo.updatePlannedBlocks(plannedId, blocks);
  }

  /// Permanently marks equipment as unavailable (synced, respected by future AI and rule plans).
  Future<void> markUnavailable(Iterable<String> equipmentIds) async {
    for (final id in equipmentIds) {
      if (id == 'bodyweight') continue;
      await _repo.setEquipment(id, false);
    }
  }

  // ---------------- insights ----------------

  /// AI review of the brief, cached per day + brief fingerprint (the server doesn't cache).
  Future<Insights> aiInsights({bool force = false}) async {
    final snap = await snapshot();
    final brief = buildBrief(snap);
    final key = '${isoDate(snap.date)}|${_fingerprint(jsonEncode(brief))}';
    if (!force) {
      final cached = await _cachedInsights();
      if (cached != null && cached.$1 == key) return Insights.fromJson(cached.$2);
    }
    final res = await _api.insights(brief);
    await _repo.db.setValue(insightsKey, jsonEncode({'key': key, 'data': res}));
    return Insights.fromJson(res);
  }

  /// Most recent cached AI insights (any day), or null.
  Future<Insights?> cachedInsights() async {
    final cached = await _cachedInsights();
    return cached == null ? null : Insights.fromJson(cached.$2);
  }

  Future<(String, Map<String, dynamic>)?> _cachedInsights() async {
    final raw = await _repo.db.getValue(insightsKey);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (j['key'] as String, j['data'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// FNV-1a (32-bit): stable across runs, unlike `String.hashCode`.
  static String _fingerprint(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  /// Offline insights computed on-device.
  Future<Insights> localInsights() async {
    final profile = await _repo.getProfile();
    final sessions = await _repo.completedSessions();
    if (sessions.isEmpty) {
      return const Insights(
        summary: 'No workouts logged yet. Your first sessions set the baseline – start light and focus on form.',
        highlights: ['Your plan: Push / Pull / Legs, three times per week.'],
        recommendations: [
          'Pick weights you could lift ~3 more reps with.',
          'Log every set so W-fit can progress you automatically.',
        ],
        nextFocus: 'Complete your first week.',
        source: 'rules',
      );
    }

    final sets = await _repo.loggedSets(since: DateTime.now().subtract(const Duration(days: 56)));
    final weeks = weeklyStats(sessions.map((s) => s.startedAt.toLocal()), sets, weeks: 8);
    final target = parseDays(profile.trainingDays).length;
    final streak = weekStreak(weeks, target);
    final highlights = <String>['${weeks.last.sessions} of $target sessions done this week.'];
    if (streak > 0) highlights.add('$streak-week streak hitting your target.');

    final cutoff = DateTime.now().subtract(const Duration(days: 28));
    final bests = computeBests(sets);
    final older = computeBests(sets.where((s) => s.date.isBefore(cutoff)));
    final gains = <(String, double)>[];
    for (final b in bests.values) {
      final o = older[b.exerciseId];
      if (o == null || o.bestE1rm == 0) continue;
      final pct = percentChange(o.bestE1rm, b.bestE1rm);
      if (pct > 0) gains.add((b.exerciseId, pct));
    }
    gains.sort((a, b) => b.$2.compareTo(a.$2));
    for (final g in gains.take(2)) {
      highlights.add('${_catalog.exerciseName(g.$1)}: +${g.$2.toStringAsFixed(0)}% estimated strength in 4 weeks.');
    }

    final recs = <String>[];
    final pastWeeks = weeks.sublist(0, weeks.length - 1);
    final avgWeekly = pastWeeks.map((w) => w.sessions).fold<int>(0, (a, b) => a + b) / pastWeeks.length;
    if (avgWeekly < target - 0.5) {
      recs.add('Consistency beats intensity – aim for $target sessions every week before adding load.');
    } else {
      recs.add('Great consistency. Keep adding weight when you reach the top of the rep range.');
    }
    final effort = sessions.take(3).map((s) => s.perceivedEffort).whereType<int>().toList();
    if (effort.isNotEmpty && effort.reduce((a, b) => a + b) / effort.length >= 8.5) {
      recs.add('Recent sessions felt very hard – keep 2–3 reps in reserve and prioritise sleep.');
    }
    recs.add('Keep the badminton work (jumps, lunges, rotation) fast and crisp rather than tiring.');
    final priorities = (await snapshot()).balance.priorities;

    return Insights(
      summary: '${sessions.length} workouts logged.'
          '${weeks.last.volume > 0 ? ' This week: ${weeks.last.volume.toStringAsFixed(0)} kg total volume.' : ''}',
      highlights: highlights,
      recommendations: recs,
      nextFocus: avgWeekly < target ? 'Hit $target sessions this week.' : 'Progressive overload on your main lifts.',
      focusMuscles: priorities.take(3).map((p) => p.muscle).toList(),
      source: 'rules',
    );
  }

  Future<Map<String, dynamic>?> aiUsage() async {
    try {
      return await _api.usage();
    } catch (_) {
      return null;
    }
  }
}
