import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/api/api_client.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/muscles.dart';
import '../../domain/plan.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/report_issue_sheet.dart';
import '../dashboard/dashboard_screen.dart';
import 'swap_sheet.dart';
import 'workout_actions.dart';

class PlanScreen extends ConsumerStatefulWidget {
  const PlanScreen({super.key, required this.plannedId});

  final String plannedId;

  @override
  ConsumerState<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends ConsumerState<PlanScreen> {
  late String _id = widget.plannedId;
  bool _busy = false;
  bool _askingCoach = false;

  Future<void> _regenerate({required bool ai, DayType? day}) async {
    final plan = await ref.read(repositoryProvider).plannedById(_id);
    if (plan == null || !mounted) return;
    if (!ai) {
      final ok = await confirmDestructive(context,
          title: day == null ? 'Rebuild this plan?' : 'Switch to ${day.label} day?',
          message: 'The current plan is replaced, with the swaps and coach changes in it.',
          action: day == null ? 'Rebuild' : 'Switch',
          cancel: 'Keep plan');
      if (!ok || !mounted) return;
    }
    String note = '';
    if (ai) {
      final input = await _askNote();
      if (input == null) return;
      note = input;
    }
    setState(() {
      _busy = true;
      _askingCoach = ai;
    });
    final coach = ref.read(coachServiceProvider);
    final date = parseDateKey(plan.date);
    final dayType = day ?? DayType.parse(plan.dayType);
    try {
      final id = ai
          ? await coach.generateWithAi(date, day: dayType, note: note)
          : await coach.generateWithRules(date, day: dayType);
      if (!mounted) return;
      setState(() => _id = id);
      ref.invalidate(nextPlanProvider);
      showSnack(context, ai ? 'Your coach built a new workout.' : 'Workout rebuilt.');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, '${e.message} Your current plan is unchanged.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askNote() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_awesome),
        title: const Text('New plan from your coach'),
        content: TextField(
          controller: c,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Wishes for today (optional), like "short on time"',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Generate')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = ref.watch(plannedStreamProvider(_id)).value;
    final aiConfigured = ref.watch(apiConfigProvider).value?.isConfigured ?? false;
    if (plan == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final day = DayType.parse(plan.dayType);
    final blocks = Repository.decodeBlocks(plan.blocksJson);
    final usedIds = blocks.expand((b) => b.items).map((i) => i.exerciseId).toSet();
    final active = ref.watch(activeSessionProvider).value;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: AppBarTitle.toolbarHeight,
        title: Text(plan.title, style: const TextStyle(fontSize: 16), maxLines: 2),
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (v) => switch (v) {
              'ai' => _regenerate(ai: true),
              'rules' => _regenerate(ai: false),
              'pain' => showReportPain(context, plannedId: plan.id),
              'tell' => showTellCoach(context, plannedId: plan.id),
              final d => _regenerate(ai: false, day: DayType.parse(d)),
            },
            itemBuilder: (_) => [
              if (aiConfigured)
                const PopupMenuItem(value: 'ai', child: ListTile(leading: Icon(Icons.auto_awesome), title: Text('New plan from your coach'))),
              const PopupMenuItem(value: 'rules', child: ListTile(leading: Icon(Icons.refresh), title: Text('Rebuild plan'))),
              const PopupMenuItem(
                  value: 'pain', child: ListTile(leading: Icon(Icons.healing_outlined), title: Text('Report pain'))),
              const PopupMenuItem(
                  value: 'tell', child: ListTile(leading: Icon(Icons.edit_note), title: Text('Tell your coach'))),
              const PopupMenuDivider(),
              for (final d in DayType.values.where((d) => d != day))
                PopupMenuItem(value: d.name, child: ListTile(leading: Icon(d.icon), title: Text('Switch to ${d.label} day'))),
            ],
          ),
        ],
      ),
      body: Stack(children: [
        ListView(
          padding: Gap.page,
          children: [
            _PlanHeader(plan: plan, preparing: ref.watch(coachPreparingProvider) == plan.date),
            for (var b = 0; b < blocks.length; b++) ...[
              SectionTitle(
                blocks[b].section.label,
                trailing: Text('${(blocks[b].items.fold<int>(0, (s, i) => s + i.estimateSeconds()) / 60).round()} min',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              Card(
                child: Column(children: [
                  for (var i = 0; i < blocks[b].items.length; i++)
                    _PlanItemTile(
                      item: blocks[b].items[i],
                      section: blocks[b].section,
                      onSwap: () => showSwapSheet(
                        context,
                        plannedId: plan.id,
                        blockIndex: b,
                        itemIndex: i,
                        exerciseId: blocks[b].items[i].exerciseId,
                        day: day,
                        section: blocks[b].section,
                        excludeIds: usedIds,
                      ),
                      onRemove: blocks[b].items.length > 1
                          ? () => _remove(plan, blocks, b, i)
                          : null,
                      onReport: () =>
                          showReportPain(context, exerciseId: blocks[b].items[i].exerciseId, plannedId: plan.id),
                    ),
                ]),
              ),
            ],
          ],
        ),
        if (_busy)
          Container(
            color: Colors.black26,
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: Gap.md),
                    Text(_askingCoach ? 'Your coach is building the workout.\nThis can take a minute or two.' : 'Rebuilding…',
                        textAlign: TextAlign.center),
                  ]),
                ),
              ),
            ),
          ),
      ]),
      bottomNavigationBar: BottomActionBar(
        child: FilledButton.icon(
          key: const ValueKey('start-workout'),
          onPressed: _busy ? null : () => _start(plan),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(active != null
              ? 'Resume workout'
              : plan.date == dateKey(DateTime.now())
                  ? 'Start workout'
                  : 'Start early'),
        ),
      ),
    );
  }

  Future<void> _remove(PlannedWorkout plan, List<PlanBlock> blocks, int b, int i) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(repositoryProvider);
    final name = ref.read(catalogProvider).exerciseName(blocks[b].items[i].exerciseId);
    await ref.read(coachServiceProvider).removeItem(plan.id, b, i);
    showUndo(messenger, '$name removed', () => repo.updatePlannedBlocks(plan.id, blocks));
  }

  Future<void> _start(PlannedWorkout plan) async {
    await startWorkout(context, ref, plan);
  }
}

class _PlanItemTile extends ConsumerWidget {
  const _PlanItemTile(
      {required this.item, required this.section, required this.onSwap, required this.onReport, this.onRemove});

  final PlanItem item;
  final Section section;
  final VoidCallback onSwap;
  final VoidCallback onReport;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(catalogProvider).exercise(item.exerciseId);
    final weight =
        item.targetWeightKg != null ? ' · ${ref.watch(loadModelProvider).weightLabel(e, item.targetWeightKg!)}' : '';
    final target = item.copyWith(perSide: item.perSide || (e?.unilateral ?? false)).targetLabel;
    return ListTile(
      onTap: () => context.push('/exercise/${item.exerciseId}'),
      // The trailing menu brings its own padding; keep the title as wide as possible.
      contentPadding: const EdgeInsetsDirectional.only(start: Gap.md - 4, end: Gap.xs),
      horizontalTitleGap: Gap.md - 4,
      leading: ExerciseAvatar(exercise: e),
      title: Text(e?.name ?? item.exerciseId, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$target$weight'),
        if (item.notes.isNotEmpty) Text(item.notes, maxLines: 2, overflow: TextOverflow.ellipsis),
      ]),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => switch (v) {
          'swap' => onSwap(),
          'remove' => onRemove!(),
          _ => onReport(),
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'swap', child: Text('Swap')),
          const PopupMenuItem(value: 'report', child: Text('Report pain')),
          if (onRemove != null) const PopupMenuItem(value: 'remove', child: Text('Remove from today')),
        ],
      ),
    );
  }
}

/// Date and length on one line, then one line from the coach (or "Why this plan") that opens the reasons and changes.
class _PlanHeader extends StatefulWidget {
  const _PlanHeader({required this.plan, required this.preparing});

  final PlannedWorkout plan;

  /// The coach is refining this plan in the background.
  final bool preparing;

  @override
  State<_PlanHeader> createState() => _PlanHeaderState();
}

class _PlanHeaderState extends State<_PlanHeader> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final plan = widget.plan;
    final meta = PlanMeta.decode(plan.metaJson);
    final fromCoach = plan.source == 'ai';
    // The rules engine writes the same sentence every time; only its deload note says something new.
    final note = fromCoach || meta.deload ? plan.coachNote.trim() : '';
    // The program position is in the line above already.
    final reasons = [
      for (final r in meta.rationale) meta.program.isNotEmpty && r.startsWith('${meta.program}: ') ? r.substring(meta.program.length + 2) : r,
    ];
    final changes = [for (final c in meta.changes) if (c.from != c.to) c];
    final hasMore = reasons.isNotEmpty || changes.isNotEmpty || meta.focus.isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        [
          DateFormat('EEE d MMM').format(parseDateKey(plan.date)),
          '~${plan.estimatedMinutes} min',
          if (meta.program.isNotEmpty) meta.program,
          if (meta.deload) 'deload week',
        ].join(' · '),
        style: t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
      ),
      if (widget.preparing)
        Padding(
          padding: const EdgeInsets.only(top: Gap.sm),
          child: Row(children: [
            const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text('Coach is preparing a refined plan…', style: t.textTheme.bodySmall)),
          ]),
        ),
      if (note.isNotEmpty || hasMore)
        Card(
          margin: const EdgeInsets.only(top: Gap.item),
          color: fromCoach ? s.secondaryContainer : null,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, Gap.sm, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (fromCoach) ...[
                    Icon(Icons.auto_awesome, size: 20, color: s.gold),
                    const SizedBox(width: Gap.sm),
                  ],
                  Expanded(
                    child: Text(
                      note.isEmpty ? 'Why this plan' : note,
                      maxLines: _open ? null : 2,
                      overflow: _open ? null : TextOverflow.ellipsis,
                    ),
                  ),
                  if (changes.isNotEmpty && !_open) ...[
                    const SizedBox(width: Gap.sm),
                    Text('${changes.length} changed', style: t.textTheme.labelMedium),
                  ],
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                ]),
                if (_open) ...[
                  if (meta.focus.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.sm),
                      child: Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final m in meta.focus) Pill('Extra ${(trackedMuscles[m]?.label ?? prettyMuscle(m)).toLowerCase()}', color: s.primary),
                      ]),
                    ),
                  for (final r in reasons)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('•  '),
                        Expanded(child: Text(r, style: t.textTheme.bodyMedium)),
                      ]),
                    ),
                  for (final c in changes) ChangeLine(change: c),
                ],
              ]),
            ),
          ),
        ),
    ]);
  }
}
