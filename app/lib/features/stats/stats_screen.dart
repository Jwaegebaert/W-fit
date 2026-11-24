import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/progression.dart';
import '../../domain/stats.dart';
import '../../domain/training_load.dart';
import '../../providers.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';
import '../../widgets/session_tile.dart';
import '../balance/balance_screen.dart';

/// Progress: lifts with their direction, consistency, muscle balance, recent workouts and body weight.
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(completedSessionsProvider).value ?? const [];
    final setsAsync = ref.watch(allLoggedSetsProvider);
    final profile = ref.watch(profileProvider).value;
    final body = ref.watch(bodyMetricsProvider).value ?? const [];
    final target = parseDays(profile?.trainingDays ?? '1,3,5').length;

    return Scaffold(
      appBar: AppBar(title: const Text('Progress'), actions: [
        IconButton(
            tooltip: 'Body weight',
            icon: const Icon(Icons.monitor_weight_outlined),
            onPressed: () => context.push('/body')),
      ]),
      body: AsyncView(
        value: setsAsync,
        builder: (sets) {
          if (sessions.isEmpty) {
            return EmptyState(
              icon: Icons.insights,
              title: 'Your progress starts here',
              message: 'Finish a workout to see your lifts, consistency and records.',
              action: OutlinedButton.icon(
                onPressed: () => context.push('/body'),
                icon: const Icon(Icons.monitor_weight_outlined),
                label: const Text('Log body weight'),
              ),
            );
          }
          final weeks = weeklyStats(sessions.map((s) => s.startedAt.toLocal()), sets, weeks: 12);
          final streak = weekStreak(weeks, target);
          final now = DateTime.now();
          final thisMonth = sessions.where((s) {
            final d = s.startedAt.toLocal();
            return d.year == now.year && d.month == now.month;
          }).length;
          final weights = body.where((b) => b.weightKg != null).toList().reversed.toList();
          final working = sets.where((s) => s.section != Section.warmup.name && s.section != Section.cooldown.name).toList();

          return ListView(padding: pagePadding(context), children: [
            if (working.any((s) => (s.reps ?? 0) > 0)) ...[
              const SectionTitle('Lifts', padding: SectionTitle.first),
              _Lifts(sets: working),
            ],
            SectionTitle('Consistency',
                trailing: Text('$target a week planned', style: Theme.of(context).textTheme.bodySmall)),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.sm, 14, Gap.sm, Gap.sm),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                    child: Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
                      if (streak > 0) _Count('$streak', streak == 1 ? 'week streak' : 'weeks streak', Icons.local_fire_department),
                      _Count('$thisMonth', 'this month'),
                      _Count('${sessions.length}', 'in total'),
                    ]),
                  ),
                  const SizedBox(height: Gap.sm),
                  WeeklyBarChart(
                    values: weeks.map((w) => w.sessions.toDouble()).toList(),
                    labels: weeks.map((w) => DateFormat('d/M').format(w.weekStart)).toList(),
                    target: target.toDouble(),
                    lastIsRunning: true,
                  ),
                ]),
              ),
            ),
            SectionTitle('Workouts',
                trailing: TextButton(onPressed: () => context.push('/history'), child: const Text('All'))),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (final s in sessions.take(3))
                  SessionTile(session: s, sets: sets.where((x) => x.sessionId == s.id).length),
              ]),
            ),
            const SizedBox(height: Gap.md),
            const BalanceSummaryCard(),
            SectionTitle('Body weight',
                trailing: TextButton(onPressed: () => context.push('/body'), child: const Text('Open'))),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                child: weights.length < 2
                    ? const Center(child: Padding(padding: EdgeInsets.all(Gap.md), child: Text('Log your weight twice to see a trend.')))
                    : TrendLineChart(
                        values: weights.map((b) => b.weightKg!).toList(),
                        labels: weights.map((b) => DateFormat('d/M').format(parseDateKey(b.date))).toList(),
                        unit: ' kg',
                      ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.value, this.label, [this.icon]);

  final String value;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) Icon(icon, size: 20, color: t.colorScheme.gold),
      Text(value, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(width: 4),
      Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }
}

/// Working lifts, most recently trained first: last and best set, and whether the lift moves.
class _Lifts extends ConsumerStatefulWidget {
  const _Lifts({required this.sets});

  /// Newest first, without warm-up and cool-down.
  final List<LoggedSet> sets;

  @override
  ConsumerState<_Lifts> createState() => _LiftsState();
}

class _LiftsState extends ConsumerState<_Lifts> {
  static const _short = 5;
  bool _all = false;

  static String _set(LoggedSet s) => (s.loadKg ?? 0) > 0 ? '${formatKg(s.loadKg)} kg × ${s.reps}' : '${s.reps} reps';

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    final trends = ref.watch(coachSnapshotProvider).value?.trends ?? const <String, ExerciseTrend>{};
    final bests = computeBests(widget.sets);
    final ids = <String>{for (final s in widget.sets) if ((s.reps ?? 0) > 0) s.exerciseId}.toList();

    // Best set of the last session of [id].
    LoggedSet last(String id) {
      final own = widget.sets.where((s) => s.exerciseId == id && (s.reps ?? 0) > 0).toList();
      final session = own.where((s) => s.sessionId == own.first.sessionId);
      return session.reduce((a, b) => estimatedOneRepMax(b.loadKg ?? 0, b.reps!) > estimatedOneRepMax(a.loadKg ?? 0, a.reps!) ||
              ((a.loadKg ?? 0) == 0 && b.reps! > a.reps!)
          ? b
          : a);
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final id in _all ? ids : ids.take(_short))
          Builder(builder: (context) {
            final l = last(id);
            final best = (bests[id]?.heaviest?.loadKg ?? 0) > 0 ? bests[id]!.heaviest! : bests[id]!.mostReps!;
            final isBest = _set(l) == _set(best);
            return ListTile(
              onTap: () => context.push('/progress/$id'),
              leading: ExerciseAvatar(exercise: catalog.exercise(id), size: 36),
              title: Text(catalog.exerciseName(id), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(isBest ? '${_set(l)} · your best' : '${_set(l)} · best ${_set(best)}'),
              trailing: _Trend(trends[id]),
            );
          }),
        if (ids.length > _short)
          TextButton(
            onPressed: () => setState(() => _all = !_all),
            child: Text(_all ? 'Show less' : 'All ${ids.length} lifts'),
          ),
      ]),
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend(this.trend);

  final ExerciseTrend? trend;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return switch (trend) {
      ExerciseTrend.progressing => Icon(Icons.trending_up_rounded, color: s.primary, semanticLabel: 'Going up'),
      ExerciseTrend.regressing => Icon(Icons.trending_down_rounded, color: s.attention, semanticLabel: 'Going down'),
      ExerciseTrend.stalled => Icon(Icons.trending_flat_rounded, color: s.onSurfaceVariant, semanticLabel: 'Steady'),
      _ => const SizedBox.shrink(),
    };
  }
}
