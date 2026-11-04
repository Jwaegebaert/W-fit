import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/db/database.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

final _detailProvider = FutureProvider.family<(WorkoutSession?, List<SetLog>), String>((ref, id) async {
  ref.watch(completedSessionsProvider);
  final repo = ref.read(repositoryProvider);
  return (await repo.sessionById(id), await repo.setsForSession(id));
});

class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_detailProvider(sessionId));
    final catalog = ref.watch(catalogProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workout'),
        actions: [
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Delete this workout?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(repositoryProvider).discardSession(sessionId);
                ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
                if (context.mounted) context.pop();
              }
            },
          ),
        ],
      ),
      body: AsyncView(
        value: data,
        builder: (d) {
          final (session, sets) = d;
          if (session == null) return const EmptyState(icon: Icons.help_outline, title: 'Workout not found');
          final byExercise = <String, List<SetLog>>{};
          for (final s in sets.where((s) => s.completed)) {
            byExercise.putIfAbsent('${s.exerciseOrder}|${s.exerciseId}', () => []).add(s);
          }
          final volume = sets.where((s) => s.completed).fold<double>(0, (a, s) => a + (s.weightKg ?? 0) * (s.reps ?? 0));
          final t = Theme.of(context);
          return ListView(padding: pagePadding(context), children: [
            Text(session.title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            Text(DateFormat('EEEE d MMMM yyyy · HH:mm').format(session.startedAt.toLocal()), style: t.textTheme.bodyMedium),
            const SizedBox(height: 16),
            StatRow(children: [
              StatTile(
                  label: 'duration',
                  value: session.durationSeconds == null ? '–' : '${(session.durationSeconds! / 60).round()} min',
                  icon: Icons.timer_outlined),
              StatTile(label: 'sets', value: '${sets.where((s) => s.completed).length}', icon: Icons.checklist),
              StatTile(label: 'kg volume', value: volume.toStringAsFixed(0), icon: Icons.fitness_center),
            ]),
            if (session.rating != null || session.perceivedEffort != null || session.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: Icon(Icons.star_rounded, color: Colors.amber.shade600),
                  title: Text('Rating ${session.rating ?? '–'}/5 · Effort ${session.perceivedEffort ?? '–'}/10'),
                  subtitle: session.notes.isEmpty ? null : Text(session.notes),
                ),
              ),
            ],
            for (final entry in byExercise.entries) ...[
              Builder(builder: (context) {
                final exerciseId = entry.key.split('|')[1];
                final e = catalog.exercise(exerciseId);
                final section = Section.parse(entry.value.first.section);
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        InkWell(
                          onTap: () => context.push('/exercise/$exerciseId'),
                          child: Row(children: [
                            ExerciseAvatar(exercise: e, size: 36),
                            const SizedBox(width: 10),
                            Expanded(child: Text(e?.name ?? exerciseId, style: const TextStyle(fontWeight: FontWeight.w700))),
                            Text(section.label, style: t.textTheme.bodySmall),
                          ]),
                        ),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 6, children: [
                          for (final s in entry.value)
                            Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text(s.durationSeconds != null && s.reps == null
                                  ? formatSeconds(s.durationSeconds!)
                                  : '${s.weightKg != null && s.weightKg! > 0 ? '${formatKg(s.weightKg)} kg × ' : ''}${s.reps ?? '-'}'),
                            ),
                        ]),
                      ]),
                    ),
                  ),
                );
              }),
            ],
          ]);
        },
      ),
    );
  }
}
