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
    setState(() => _busy = true);
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
      showSnack(context, ai ? 'Your AI coach built a new workout.' : 'Workout rebuilt.');
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
        title: const Text('Ask the AI coach'),
        content: TextField(
          controller: c,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Anything to consider today? e.g. "short on time", "knee feels sore", "more badminton work"',
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
    final t = Theme.of(context);

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
              'report' => showReportIssueSheet(context, plannedId: plan.id),
              final d => _regenerate(ai: false, day: DayType.parse(d)),
            },
            itemBuilder: (_) => [
              if (aiConfigured)
                const PopupMenuItem(value: 'ai', child: ListTile(leading: Icon(Icons.auto_awesome), title: Text('Ask AI coach'))),
              const PopupMenuItem(value: 'rules', child: ListTile(leading: Icon(Icons.refresh), title: Text('Rebuild plan'))),
              const PopupMenuItem(
                  value: 'report',
                  child: ListTile(leading: Icon(Icons.report_problem_outlined), title: Text('Report an issue'))),
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
            Wrap(spacing: 8, runSpacing: 8, children: [
              Pill(DateFormat('EEEE d MMM').format(parseDateKey(plan.date)), icon: Icons.event),
              Pill('~${plan.estimatedMinutes} min', icon: Icons.timer_outlined),
              Pill(plan.source == 'ai' ? 'AI coach' : 'Smart plan',
                  icon: plan.source == 'ai' ? Icons.auto_awesome : Icons.rule, color: t.colorScheme.tertiary),
            ]),
            if (plan.coachNote.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                color: t.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.tips_and_updates_outlined, color: t.colorScheme.onSecondaryContainer),
                    const SizedBox(width: 10),
                    Expanded(child: Text(plan.coachNote, style: TextStyle(color: t.colorScheme.onSecondaryContainer))),
                  ]),
                ),
              ),
            ],
            if (ref.watch(coachPreparingProvider) == plan.date)
              Padding(
                padding: const EdgeInsets.only(top: Gap.item),
                child: Row(children: [
                  const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: Gap.sm),
                  Expanded(child: Text('Coach is preparing a refined plan…', style: t.textTheme.bodySmall)),
                ]),
              ),
            _WhyCard(meta: PlanMeta.decode(plan.metaJson)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showReportIssueSheet(context, plannedId: plan.id),
                icon: const Icon(Icons.report_problem_outlined),
                label: const Text('Report an issue'),
              ),
            ),
            for (var b = 0; b < blocks.length; b++) ...[
              SectionTitle(
                blocks[b].section.label,
                trailing: Text('${(blocks[b].items.fold<int>(0, (s, i) => s + i.estimateSeconds()) / 60).round()} min',
                    style: t.textTheme.bodySmall),
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
                          showReportIssueSheet(context, exerciseId: blocks[b].items[i].exerciseId, plannedId: plan.id),
                    ),
                ]),
              ),
            ],
          ],
        ),
        if (_busy)
          Container(
            color: Colors.black26,
            child: const Center(child: Card(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))),
          ),
      ]),
      bottomNavigationBar: BottomActionBar(
        child: FilledButton.icon(
          onPressed: _busy ? null : () => _start(plan),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start workout'),
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
    final rest = item.restSeconds > 0 && section != Section.cooldown ? ' · rest ${formatSeconds(item.restSeconds)}' : '';
    return ListTile(
      onTap: () => context.push('/exercise/${item.exerciseId}'),
      // Trailing icon buttons bring their own padding; keep the title as wide as possible.
      contentPadding: const EdgeInsetsDirectional.only(start: Gap.md - 4, end: Gap.xs),
      horizontalTitleGap: Gap.md - 4,
      leading: ExerciseAvatar(exercise: e),
      title: Text(e?.name ?? item.exerciseId, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('$target$weight$rest${item.notes.isNotEmpty ? '\n${item.notes}' : ''}'),
      isThreeLine: item.notes.isNotEmpty,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: 'Swap', icon: const Icon(Icons.swap_horiz), onPressed: onSwap),
        PopupMenuButton<String>(
          onSelected: (v) => v == 'remove' ? onRemove!() : onReport(),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'report', child: Text('Report an issue')),
            if (onRemove != null) const PopupMenuItem(value: 'remove', child: Text('Remove from today')),
          ],
        ),
      ]),
    );
  }
}

/// "Why this plan": program position, deload, focus muscles, rationale and changes from the plan meta.
class _WhyCard extends ConsumerWidget {
  const _WhyCard({required this.meta});

  final PlanMeta meta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (meta.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: Gap.item),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Why this plan', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (meta.program.isNotEmpty) Pill(meta.program, icon: Icons.timeline),
            if (meta.deload) Pill('Deload week', icon: Icons.battery_charging_full, color: t.colorScheme.tertiary),
            for (final m in meta.focus)
              Pill(trackedMuscles[m]?.label ?? prettyMuscle(m), icon: Icons.center_focus_strong, color: t.colorScheme.primary),
          ]),
          for (final r in meta.rationale)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  '),
                Expanded(child: Text(r, style: t.textTheme.bodyMedium)),
              ]),
            ),
          for (final c in meta.changes) ChangeLine(change: c),
        ]),
      ),
    );
  }
}

/// Compact list of a workout's sections for read-only display.
class PlanSummary extends StatelessWidget {
  const PlanSummary({super.key, required this.blocks, required this.catalog});

  final List<PlanBlock> blocks;
  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final b in blocks)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(b.section.icon, size: 16, color: b.section.color(s)),
            const SizedBox(width: 6),
            Expanded(child: Text(b.items.map((i) => catalog.exerciseName(i.exerciseId)).join(' · '))),
          ]),
        ),
    ]);
  }
}
