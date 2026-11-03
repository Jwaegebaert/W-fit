import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/db/database.dart';
import '../data/repositories/repository.dart';
import '../domain/catalog.dart';
import '../domain/plan.dart';
import '../domain/progression.dart';
import '../domain/rule_engine.dart';
import '../domain/stats.dart';
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
    this.generatedAt,
  });

  factory Insights.fromJson(Map<String, dynamic> j) => Insights(
        summary: j['summary'] as String? ?? '',
        highlights: (j['highlights'] as List? ?? const []).cast<String>(),
        recommendations: (j['recommendations'] as List? ?? const []).cast<String>(),
        nextFocus: j['nextFocus'] as String? ?? '',
        source: j['source'] as String? ?? 'ai',
        generatedAt: j['generatedAt'] == null ? null : DateTime.tryParse(j['generatedAt'] as String),
      );

  final String summary;
  final List<String> highlights;
  final List<String> recommendations;
  final String nextFocus;
  final String source;
  final DateTime? generatedAt;
}

/// Coordinates the rule engine, progression and the optional AI backend.
class CoachService {
  CoachService(this.ref);

  final Ref ref;

  Repository get _repo => ref.read(repositoryProvider);
  Catalog get _catalog => ref.read(catalogProvider);
  ApiClient get _api => ref.read(apiClientProvider);

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

  Future<TrainingContext> trainingContext({DayType? day, Set<String>? occupied}) async {
    final profile = await _repo.getProfile();
    final recent = <String>{};
    if (day != null) {
      final sessions = await _repo.completedSessions();
      for (final s in sessions.where((s) => s.dayType == day.name).take(2)) {
        final sets = await _repo.setsForSession(s.id);
        recent.addAll(sets.where((x) => x.section == Section.main.name).map((x) => x.exerciseId));
      }
    }
    return TrainingContext(
      catalog: _catalog,
      equipmentAvailability: await _repo.getEquipment(),
      occupiedEquipment: occupied ?? ref.read(occupiedEquipmentProvider),
      preferences: await _repo.getPreferences(),
      experience: profile.experience,
      recentExerciseIds: recent,
    );
  }

  /// Returns the open plan for [date], creating a rule-based one if none exists.
  Future<PlannedWorkout> ensurePlan(DateTime date) async {
    final existing = await _repo.plannedForDate(date);
    if (existing != null) return existing;
    final id = await generateWithRules(date);
    return (await _repo.plannedById(id))!;
  }

  Future<String> generateWithRules(DateTime date, {DayType? day}) async {
    final profile = await _repo.getProfile();
    final dayType = day ?? await nextDayType();
    final ctx = await trainingContext(day: dayType);
    final weights = <String, double?>{};
    for (final e in _catalog.exercises.where((e) => e.isWeighted && e.fitsDay(dayType))) {
      final history = await _repo.exerciseHistory(e.id, maxSessions: 2);
      if (history.isNotEmpty) weights[e.id] = adviseProgression(e, history).weightKg;
    }
    final w = RuleEngine(ctx).generate(
      day: dayType,
      sessionMinutes: profile.sessionMinutes,
      includeCore: profile.includeCore,
      suggestWeight: (e) => weights[e.id],
    );
    return _repo.savePlanned(
      date: date,
      day: dayType,
      title: w.title,
      source: 'rules',
      coachNote: w.coachNote,
      blocks: w.blocks,
      estimatedMinutes: w.estimatedMinutes,
    );
  }

  /// Asks the AI coach for a workout. Throws [ApiException] so the UI can explain and keep the rules plan.
  Future<String> generateWithAi(DateTime date, {DayType? day, String note = ''}) async {
    final profile = await _repo.getProfile();
    final dayType = day ?? await nextDayType();
    // Make sure the server has the latest history, equipment and preferences.
    await ref.read(syncControllerProvider.notifier).syncNow();
    final res = await _api.generateWorkout({
      'dayType': dayType.name,
      'date': dateKey(date),
      'sessionMinutes': profile.sessionMinutes,
      'includeCore': profile.includeCore,
      'occupiedEquipment': ref.read(occupiedEquipmentProvider).toList(),
      'userNote': note,
    });
    final w = res['workout'] as Map<String, dynamic>;
    final blocks = <PlanBlock>[];
    for (final raw in (w['blocks'] as List? ?? const [])) {
      final b = PlanBlock.fromJson(raw as Map<String, dynamic>);
      final items = <PlanItem>[];
      for (final i in b.items) {
        final e = _catalog.exercise(i.exerciseId);
        if (e == null) continue;
        if (i.targetWeightKg == null && e.isWeighted) {
          // Fill in progression-based weights where the AI didn't set any.
          final h = await _repo.exerciseHistory(e.id, maxSessions: 2);
          items.add(h.isEmpty ? i : i.copyWith(targetWeightKg: adviseProgression(e, h).weightKg));
        } else {
          items.add(i);
        }
      }
      if (items.isNotEmpty) blocks.add(PlanBlock(section: b.section, items: items));
    }
    if (!blocks.any((b) => b.section == Section.main)) {
      throw ApiException('ai_unavailable', 'The AI coach returned an unusable workout.');
    }
    return _repo.savePlanned(
      id: w['id'] as String?,
      date: date,
      day: DayType.parse(w['dayType'] as String? ?? dayType.name),
      title: w['title'] as String? ?? '${dayType.label} day',
      source: 'ai',
      coachNote: w['coachNote'] as String? ?? '',
      blocks: blocks,
    );
  }

  Future<ProgressionAdvice> advice(String exerciseId, PlanItem item, {String? excludeSessionId}) async {
    final e = _catalog.exercise(exerciseId);
    if (e == null) return const ProgressionAdvice(message: '');
    final history = await _repo.exerciseHistory(exerciseId, excludeSessionId: excludeSessionId);
    return adviseProgression(e, history, repMin: item.repMin, repMax: item.repMax);
  }

  // ---------------- swaps ----------------
  Future<List<SwapSuggestion>> ruleSwaps(
    String exerciseId, {
    required DayType day,
    Set<String> exclude = const {},
    Set<String> extraUnavailable = const {},
  }) async {
    final original = _catalog.exercise(exerciseId);
    if (original == null) return const [];
    var ctx = await trainingContext();
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
    await ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    final res = await _api.swap({
      'exerciseId': exerciseId,
      'reason': reason,
      'dayType': day.name,
      'section': section.name,
      'excludeExerciseIds': exclude.toList(),
      'occupiedEquipment': ref.read(occupiedEquipmentProvider).toList(),
      'note': note,
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
  Future<Insights> aiInsights({bool force = false}) async {
    await ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    return Insights.fromJson(await _api.insights(force: force));
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

    return Insights(
      summary: '${sessions.length} workouts logged.'
          '${weeks.last.volume > 0 ? ' This week: ${weeks.last.volume.toStringAsFixed(0)} kg total volume.' : ''}',
      highlights: highlights,
      recommendations: recs,
      nextFocus: avgWeekly < target ? 'Hit $target sessions this week.' : 'Progressive overload on your main lifts.',
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
