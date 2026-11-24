import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../domain/progression.dart';
import '../../domain/stats.dart';
import '../../providers.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';

final _exerciseSetsProvider = FutureProvider.family<List<LoggedSet>, String>((ref, id) async {
  await ref.watch(completedSessionsProvider.future);
  return ref.read(repositoryProvider).loggedSets(exerciseId: id);
});

class ExerciseProgressScreen extends ConsumerWidget {
  const ExerciseProgressScreen({super.key, required this.exerciseId});

  final String exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(catalogProvider).exercise(exerciseId);
    final data = ref.watch(_exerciseSetsProvider(exerciseId));
    return Scaffold(
      appBar: AppBar(title: Text(e?.name ?? 'Progress')),
      body: AsyncView(
        value: data,
        builder: (sets) {
          if (sets.isEmpty) {
            return const EmptyState(icon: Icons.show_chart, title: 'No sets logged yet', message: 'Log this exercise in a workout to see progress.');
          }
          // Group per session, oldest first.
          final sessions = <String, List<LoggedSet>>{};
          for (final s in sets.reversed) {
            sessions.putIfAbsent(s.sessionId, () => []).add(s);
          }
          final points = sessions.values.toList();
          final labels = points.map((p) => DateFormat('d/M').format(p.first.date.toLocal())).toList();
          final weighted = sets.any((s) => (s.loadKg ?? 0) > 0);
          final e1rm = points
              .map((p) => p.map((s) => estimatedOneRepMax(s.loadKg ?? 0, s.reps ?? 0)).fold<double>(0, math.max))
              .toList();
          final top = points.map((p) => p.map((s) => s.loadKg ?? 0).fold<double>(0, math.max)).toList();
          final reps = points.map((p) => p.map((s) => (s.reps ?? 0).toDouble()).fold<double>(0, math.max)).toList();
          final best = computeBests(sets)[exerciseId];
          final first = weighted ? e1rm.first : reps.first;
          final last = weighted ? e1rm.last : reps.last;
          final change = percentChange(first, last);
          final t = Theme.of(context);

          return ListView(padding: pagePadding(context), children: [
            StatRow(children: [
              StatTile(
                label: weighted ? 'est. 1-rep max' : 'best reps',
                value: weighted ? '${formatKg(best?.bestE1rm)} kg' : '${best?.mostReps?.reps ?? 0}',
                icon: Icons.emoji_events_outlined,
                color: t.colorScheme.gold,
              ),
              if (points.length > 2)
                StatTile(
                  label: 'since first session',
                  value: '${change >= 0 ? '+' : ''}${change.toStringAsFixed(0)}%',
                  icon: change >= 0 ? Icons.trending_up : Icons.trending_down,
                ),
              StatTile(label: 'sessions', value: '${points.length}', icon: Icons.event_repeat),
            ]),
            if (weighted) ...[
              const SizedBox(height: Gap.md),
              _WeightChart(e1rm: e1rm, top: top, labels: labels),
            ] else ...[
              const SectionTitle('Best set (reps)'),
              Card(child: Padding(padding: const EdgeInsets.fromLTRB(8, 16, 16, 8), child: TrendLineChart(values: reps, labels: labels))),
            ],
            const SectionTitle('Sessions'),
            Card(
              child: Column(children: [
                for (final p in points.reversed.take(15))
                  ListTile(
                    dense: true,
                    title: Text(DateFormat('EEE d MMM yyyy').format(p.first.date.toLocal())),
                    subtitle: Text(p
                        .map((s) => weighted ? '${formatKg(s.loadKg)}×${s.reps}' : '${s.reps ?? formatKgOrDash(s.durationSeconds)}')
                        .join('  ')),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

/// One chart, either the estimated one-rep max or the heaviest set.
class _WeightChart extends StatefulWidget {
  const _WeightChart({required this.e1rm, required this.top, required this.labels});

  final List<double> e1rm;
  final List<double> top;
  final List<String> labels;

  @override
  State<_WeightChart> createState() => _WeightChartState();
}

class _WeightChartState extends State<_WeightChart> {
  bool _topSet = true;

  @override
  Widget build(BuildContext context) => Column(children: [
        OptionBar<bool>(
          options: const {true: 'Heaviest set', false: 'Est. 1-rep max'},
          selected: _topSet,
          onSelected: (v) => setState(() => _topSet = v),
        ),
        const SizedBox(height: Gap.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: TrendLineChart(values: _topSet ? widget.top : widget.e1rm, labels: widget.labels, unit: ' kg'),
          ),
        ),
      ]);
}

String formatKgOrDash(int? v) => v == null ? '–' : '${v}s';
