import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/workout_countdown.dart';
import '../../providers.dart';
import 'set_logger.dart';
import 'set_tick.dart';
import 'workout_timer.dart';

/// Warm-up or cool-down in the live workout: one line per exercise to tick off, with its timer, and one tick for all.
/// A line stands for all sets of its exercise; they are logged with the planned reps or time.
class SectionChecklist extends ConsumerWidget {
  const SectionChecklist({
    super.key,
    required this.sessionId,
    required this.section,
    required this.items,
    required this.logged,
    this.onSwap,
  });

  final String sessionId;
  final Section section;

  /// Exercises with their order in the session.
  final List<(int, PlanItem)> items;

  /// All sets of the session.
  final List<SetLog> logged;

  /// Swaps the line at this index of [items]; null when there is no plan.
  final void Function(int index)? onSwap;

  SetLog? _set(int order, PlanItem item, int n) => logged
      .where((s) => s.exerciseOrder == order && s.exerciseId == item.exerciseId && s.setNumber == n)
      .firstOrNull;

  int _done(int order, PlanItem item) =>
      [for (var n = 1; n <= item.sets; n++) _set(order, item, n)].where((s) => s?.completed ?? false).length;

  SetRef _setRef(int order, PlanItem item, int n) => SetRef(
        sessionId: sessionId,
        order: order,
        exerciseId: item.exerciseId,
        section: section.name,
        set: n,
        seconds: item.durationSeconds ?? 30,
        rest: 0, // no rest in a warm-up or cool-down
        last: n >= item.sets,
      );

  Future<void> _tick(SetLogger logger, int order, PlanItem item, bool completed) async {
    if (completed) HapticFeedback.lightImpact();
    for (var n = 1; n <= item.sets; n++) {
      final ref = _setRef(order, item, n);
      // Looked up again: it may have been logged since this list was built (a timer ran, the watch).
      final existing = await logger.find(sessionId, order: order, exerciseId: item.exerciseId, set: n);
      if ((existing?.completed ?? false) == completed) continue;
      await logger.log(
        ref,
        reps: item.isTimed ? null : (item.repMax ?? item.repMin),
        durationSeconds: item.isTimed ? item.durationSeconds : null,
        completed: completed,
      );
    }
  }

  Future<void> _tickAll(SetLogger logger) async {
    for (final (order, item) in items) {
      await _tick(logger, order, item, true);
    }
  }

  /// Runs the timer of the next open set (one per side when needed) and logs it at the end.
  void _start(WidgetRef ref, int order, PlanItem item, String name, {required bool perSide}) {
    final n = [for (var n = 1; n <= item.sets; n++) n].firstWhere((n) => !(_set(order, item, n)?.completed ?? false));
    ref.read(workoutTimerProvider.notifier).startWork(name, _setRef(order, item, n), perSide: perSide);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final catalog = ref.watch(catalogProvider);
    final open = items.where((x) => _done(x.$1, x.$2) < x.$2.sets).length;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.item),
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: open == 0 ? s.primaryContainer.withValues(alpha: 0.45) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Gap.tap),
              child: Row(children: [
                Expanded(
                  child: Text(section.label, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (open > 0) TextButton(onPressed: () => _tickAll(ref.read(setLoggerProvider)), child: const Text('All done')),
              ]),
            ),
          ),
          for (final (i, (order, item)) in items.indexed)
            Builder(builder: (context) {
              final e = catalog.exercise(item.exerciseId);
              final name = e?.name ?? item.exerciseId;
              final perSide = item.perSide || (e?.unilateral ?? false);
              final done = _done(order, item);
              final complete = done >= item.sets;
              return ListTile(
                contentPadding: const EdgeInsetsDirectional.only(start: Gap.sm, end: Gap.xs),
                horizontalTitleGap: Gap.sm,
                leading: SetTick(
                  label: complete ? 'Undo $name' : 'Done: $name',
                  done: complete,
                  onPressed: () => _tick(ref.read(setLoggerProvider), order, item, !complete),
                ),
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([
                  item.copyWith(perSide: perSide).targetLabel,
                  if (done > 0 && !complete) '$done done',
                ].join(' · ')),
                onTap: () => context.push('/exercise/${item.exerciseId}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (item.isTimed && !complete)
                    IconButton(
                      tooltip: 'Start timer: $name',
                      icon: const Icon(Icons.play_arrow_rounded),
                      onPressed: () => _start(ref, order, item, name, perSide: perSide),
                    ),
                  if (onSwap != null)
                    IconButton(
                        tooltip: 'Swap exercise', icon: const Icon(Icons.swap_horiz), onPressed: () => onSwap!(i)),
                ]),
              );
            }),
          const SizedBox(height: Gap.sm),
        ]),
      ),
    );
  }
}
