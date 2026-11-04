import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/progression.dart';
import '../../domain/stats.dart';
import '../../providers.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';

class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(completedSessionsProvider).value ?? const [];
    final setsAsync = ref.watch(allLoggedSetsProvider);
    final profile = ref.watch(profileProvider).value;
    final body = ref.watch(bodyMetricsProvider).value ?? const [];
    final catalog = ref.watch(catalogProvider);
    final target = parseDays(profile?.trainingDays ?? '1,3,5').length;
    final t = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Progress'), actions: [
        IconButton(tooltip: 'Body', icon: const Icon(Icons.monitor_weight_outlined), onPressed: () => context.push('/body')),
      ]),
      body: AsyncView(
        value: setsAsync,
        builder: (sets) {
          if (sessions.isEmpty) {
            return EmptyState(
              icon: Icons.insights,
              title: 'Your progress starts here',
              message: 'Complete a workout to see strength trends, consistency and personal records.',
              action: OutlinedButton.icon(
                onPressed: () => context.push('/body'),
                icon: const Icon(Icons.monitor_weight_outlined),
                label: const Text('Log body weight'),
              ),
            );
          }
          final weeks = weeklyStats(sessions.map((s) => s.startedAt.toLocal()), sets, weeks: 12);
          final weekLabels = weeks.map((w) => DateFormat('d/M').format(w.weekStart)).toList();
          final streak = weekStreak(weeks, target);
          final bests = computeBests(sets).values.toList()
            ..sort((a, b) => b.bestE1rm.compareTo(a.bestE1rm));
          final thisMonth = sessions.where((s) {
            final d = s.startedAt.toLocal();
            final now = DateTime.now();
            return d.year == now.year && d.month == now.month;
          }).length;
          final recentSets = sets.where((s) => s.date.isAfter(DateTime.now().subtract(const Duration(days: 28))));
          final muscleSets = <String, int>{};
          for (final s in recentSets) {
            final e = catalog.exercise(s.exerciseId);
            if (e == null || !(e.category == 'strength' || e.category == 'power')) continue;
            for (final m in e.primary) {
              muscleSets[m] = (muscleSets[m] ?? 0) + 1;
            }
          }
          final muscles = muscleSets.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
          final maxMuscle = muscles.isEmpty ? 1 : muscles.first.value;
          final weights = body.where((b) => b.weightKg != null).toList().reversed.toList();

          return ListView(padding: pagePadding(context), children: [
            StatRow(children: [
              StatTile(label: 'workouts total', value: '${sessions.length}', icon: Icons.fitness_center),
              StatTile(label: 'this month', value: '$thisMonth', icon: Icons.calendar_month),
            ]),
            const SizedBox(height: Gap.item),
            StatRow(children: [
              StatTile(label: 'week streak', value: '$streak', icon: Icons.local_fire_department, color: Colors.orange.shade700),
              StatTile(
                  label: 'exercises tracked',
                  value: '${bests.length}',
                  icon: Icons.emoji_events_outlined,
                  color: Colors.amber.shade700),
            ]),
            SectionTitle('Consistency', trailing: Text('target $target / week', style: t.textTheme.bodySmall)),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                child: WeeklyBarChart(
                  values: weeks.map((w) => w.sessions.toDouble()).toList(),
                  labels: weekLabels,
                  target: target.toDouble(),
                ),
              ),
            ),
            const SectionTitle('Weekly training volume (kg)'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                child: TrendLineChart(values: weeks.map((w) => w.volume).toList(), labels: weekLabels, unit: ' kg', minYZero: true),
              ),
            ),
            const SectionTitle('Personal records'),
            Card(
              child: Column(children: [
                for (final b in bests.take(12))
                  ListTile(
                    onTap: () => context.push('/progress/${b.exerciseId}'),
                    leading: ExerciseAvatar(exercise: catalog.exercise(b.exerciseId), size: 36),
                    title: Text(catalog.exerciseName(b.exerciseId), style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(b.bestE1rm > 0
                        ? 'Best ${formatKg(b.heaviest?.weightKg)} kg × ${b.heaviest?.reps} · e1RM ${formatKg(b.bestE1rm)} kg'
                        : 'Best ${b.mostReps?.reps} reps'),
                    trailing: const Icon(Icons.chevron_right),
                  ),
              ]),
            ),
            if (muscles.isNotEmpty) ...[
              const SectionTitle('Muscle focus (last 4 weeks, sets)'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    for (final m in muscles.take(10))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          SizedBox(width: 100, child: Text(prettyMuscle(m.key), style: t.textTheme.bodySmall)),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(value: m.value / maxMuscle, minHeight: 10),
                            ),
                          ),
                          SizedBox(width: 32, child: Text('${m.value}', textAlign: TextAlign.end, style: t.textTheme.bodySmall)),
                        ]),
                      ),
                  ]),
                ),
              ),
            ],
            SectionTitle('Body weight',
                trailing: TextButton(onPressed: () => context.push('/body'), child: const Text('Open'))),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                child: weights.length < 2
                    ? const SizedBox(height: 80, child: Center(child: Text('Log your weight at least twice to see a trend.')))
                    : TrendLineChart(
                        values: weights.map((b) => b.weightKg!).toList(),
                        labels: weights.map((b) => DateFormat('d/M').format(parseDateKey(b.date))).toList(),
                        unit: ' kg',
                        color: t.colorScheme.tertiary,
                      ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
