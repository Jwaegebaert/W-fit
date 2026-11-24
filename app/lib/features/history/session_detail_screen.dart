import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
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

/// Corrections to sets of a finished workout.
extension on Repository {
  /// Everything that shows sets refreshes when a finished session changes.
  Future<void> touchSession(String id) => (db.update(db.workoutSessions)..where((t) => t.id.equals(id)))
      .write(WorkoutSessionsCompanion(updatedAt: Value(DateTime.now().toUtc()), dirty: const Value(true)));

  Future<void> correctSet(String id, {double? weightKg, int? reps, int? durationSeconds}) =>
      (db.update(db.setLogs)..where((t) => t.id.equals(id))).write(SetLogsCompanion(
        weightKg: Value(weightKg),
        reps: Value(reps),
        durationSeconds: Value(durationSeconds),
        updatedAt: Value(DateTime.now().toUtc()),
        dirty: const Value(true),
      ));
}

/// What was done in one workout: the work first, warm-up and cool-down folded; tap an exercise to correct its sets.
class SessionDetailScreen extends ConsumerWidget {
  const SessionDetailScreen({super.key, required this.sessionId});

  final String sessionId;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirmDestructive(context,
        title: 'Delete this workout?', message: 'All its sets are removed from your history.', action: 'Delete');
    if (!ok) return;
    await ref.read(repositoryProvider).discardSession(sessionId);
    ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    if (context.mounted) context.pop();
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, List<SetLog> sets) async {
    final changed = await showAppSheet<bool>(context, builder: (_) => _EditSets(sets: sets));
    if (changed != true) return;
    await ref.read(repositoryProvider).touchSession(sessionId);
    ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_detailProvider(sessionId));
    final session = data.value?.$1;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: AppBarTitle.toolbarHeight,
        title: AppBarTitle(session?.title ?? 'Workout',
            subtitle: Text(session == null ? '' : DateFormat('EEE d MMMM yyyy, HH:mm').format(session.startedAt.toLocal()))),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) => _delete(context, ref),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'delete',
                  child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete workout'))),
            ],
          ),
        ],
      ),
      body: AsyncView(
        value: data,
        builder: (d) {
          final (session, sets) = d;
          if (session == null) return const EmptyState(icon: Icons.help_outline, title: 'Workout not found');
          final done = sets.where((s) => s.completed).toList();
          final byExercise = <String, List<SetLog>>{};
          for (final s in done) {
            byExercise.putIfAbsent('${s.exerciseOrder}|${s.exerciseId}', () => []).add(s);
          }
          bool extra(List<SetLog> g) =>
              g.first.section == Section.warmup.name || g.first.section == Section.cooldown.name;
          final work = byExercise.values.where((g) => !extra(g)).toList();
          final rest = byExercise.values.where(extra).toList();
          final seconds = session.durationSeconds;
          final t = Theme.of(context);
          final facts = [
            if (seconds != null) '${(seconds / 60).round()} min',
            '${done.length} sets',
            if (session.perceivedEffort != null) 'effort ${session.perceivedEffort}/10',
            if (session.avgHeartRate != null)
              '${session.avgHeartRate} bpm${session.maxHeartRate == null ? '' : ' (max ${session.maxHeartRate})'}',
          ];
          return ListView(padding: pagePadding(context), children: [
            Text(facts.join(' · '), style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            if (session.notes.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('"${session.notes}"')),
            const SizedBox(height: Gap.md),
            if (byExercise.isEmpty) const Card(child: ListTile(title: Text('No sets were logged'))),
            if (work.isNotEmpty)
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final g in work) _ExerciseTile(sets: g, onTap: () => _edit(context, ref, g)),
                ]),
              ),
            if (rest.isNotEmpty)
              Card(
                margin: const EdgeInsets.only(top: Gap.item),
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  shape: const Border(),
                  initiallyExpanded: work.isEmpty,
                  title: const Text('Warm-up & cool-down', style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${rest.length} exercise${rest.length == 1 ? '' : 's'}'),
                  children: [for (final g in rest) _ExerciseTile(sets: g, onTap: () => _edit(context, ref, g))],
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class _ExerciseTile extends ConsumerWidget {
  const _ExerciseTile({required this.sets, required this.onTap});

  final List<SetLog> sets;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = sets.first.exerciseId;
    final e = ref.watch(catalogProvider).exercise(id);
    final loads = ref.watch(loadModelProvider);
    // Consecutive sets with the same load share it: "25 kg × 10, 10 · 27.5 kg × 8".
    final parts = <(String, List<String>)>[];
    for (final s in sets) {
      final kg = loads.totalKg(id, s.weightKg) ?? 0;
      final load = kg > 0
          ? '${formatKg(kg)} kg'
          : (s.weightKg ?? 0) > 0
              ? '${formatKg(s.weightKg)} kg assist'
              : '';
      final amount = s.durationSeconds != null && s.reps == null ? formatSeconds(s.durationSeconds!) : '${s.reps ?? '–'}';
      if (parts.isNotEmpty && parts.last.$1 == load) {
        parts.last.$2.add(amount);
      } else {
        parts.add((load, [amount]));
      }
    }
    return ListTile(
      onTap: onTap,
      leading: ExerciseAvatar(exercise: e, size: 36),
      title: Text(e?.name ?? id, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text([
        for (final (load, amounts) in parts) load.isEmpty ? amounts.join(', ') : '$load × ${amounts.join(', ')}',
      ].join(' · ')),
      trailing: const Icon(Icons.edit_outlined, size: 20),
    );
  }
}

/// Weight and reps (or seconds) of each logged set of one exercise. Pops true when something was saved.
class _EditSets extends ConsumerStatefulWidget {
  const _EditSets({required this.sets});

  final List<SetLog> sets;

  @override
  ConsumerState<_EditSets> createState() => _EditSetsState();
}

class _EditSetsState extends ConsumerState<_EditSets> {
  late final _weight = [for (final s in widget.sets) TextEditingController(text: s.weightKg == null ? '' : formatKg(s.weightKg))];
  late final _amount = [
    for (final s in widget.sets)
      TextEditingController(text: _timed(s) ? '${s.durationSeconds ?? ''}' : s.reps?.toString() ?? ''),
  ];
  final _removed = <int>{};

  static bool _timed(SetLog s) => s.durationSeconds != null && s.reps == null;

  @override
  void dispose() {
    for (final c in [..._weight, ..._amount]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(repositoryProvider);
    for (final (i, s) in widget.sets.indexed) {
      if (_removed.contains(i)) {
        await repo.deleteSet(s.id);
        continue;
      }
      final amount = int.tryParse(_amount[i].text);
      await repo.correctSet(
        s.id,
        weightKg: double.tryParse(_weight[i].text.replaceAll(',', '.')),
        reps: _timed(s) ? null : amount,
        durationSeconds: _timed(s) ? amount : s.durationSeconds,
      );
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final id = widget.sets.first.exerciseId;
    final e = ref.watch(catalogProvider).exercise(id);
    final timed = _timed(widget.sets.first);
    final showWeight = !timed && (e?.logsWeight ?? true);
    final weightLabel = switch (e?.load) {
      LoadType.assist => 'Assist kg',
      LoadType.optional => 'Extra kg',
      _ => e?.bar != null ? 'Plates kg' : 'kg',
    };
    Widget field(TextEditingController c, String label) => TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.center,
          decoration: InputDecoration(labelText: label, isDense: true),
        );
    return SingleChildScrollView(
      padding: sheetPadding(context),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(e?.name ?? id, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.md),
        for (final (i, s) in widget.sets.indexed)
          if (!_removed.contains(i))
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(children: [
                SizedBox(width: 28, child: Text('${s.setNumber}', style: t.textTheme.titleSmall)),
                if (showWeight) ...[Expanded(child: field(_weight[i], weightLabel)), const SizedBox(width: Gap.sm)],
                Expanded(child: field(_amount[i], timed ? 'Seconds' : 'Reps')),
                IconButton(
                  tooltip: 'Remove set ${s.setNumber}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _removed.add(i)),
                ),
              ]),
            ),
        const SizedBox(height: Gap.sm),
        FilledButton(
          onPressed: _save,
          child: Text(_removed.isEmpty ? 'Save' : 'Save and remove ${_removed.length}'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            context.push('/exercise/$id');
          },
          child: const Text('About this exercise'),
        ),
      ]),
    );
  }
}
