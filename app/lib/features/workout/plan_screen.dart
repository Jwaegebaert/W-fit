import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/api/api_client.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
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
    if (plan == null) return;
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
        title: Text(plan.title),
        actions: [
          PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (v) => switch (v) {
              'ai' => _regenerate(ai: true),
              'rules' => _regenerate(ai: false),
              final d => _regenerate(ai: false, day: DayType.parse(d)),
            },
            itemBuilder: (_) => [
              if (aiConfigured)
                const PopupMenuItem(value: 'ai', child: ListTile(leading: Icon(Icons.auto_awesome), title: Text('Ask AI coach'))),
              const PopupMenuItem(value: 'rules', child: ListTile(leading: Icon(Icons.refresh), title: Text('Rebuild plan'))),
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
                          ? () => ref.read(coachServiceProvider).removeItem(plan.id, b, i)
                          : null,
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

  Future<void> _start(PlannedWorkout plan) async {
    await startWorkout(context, ref, plan);
  }
}

class _PlanItemTile extends ConsumerWidget {
  const _PlanItemTile({required this.item, required this.section, required this.onSwap, this.onRemove});

  final PlanItem item;
  final Section section;
  final VoidCallback onSwap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(catalogProvider).exercise(item.exerciseId);
    final weight = item.targetWeightKg != null ? ' · ${formatKg(item.targetWeightKg)} kg' : '';
    final rest = item.restSeconds > 0 && section != Section.cooldown ? ' · rest ${formatSeconds(item.restSeconds)}' : '';
    return ListTile(
      onTap: () => context.push('/exercise/${item.exerciseId}'),
      // Trailing icon buttons bring their own padding; keep the title as wide as possible.
      contentPadding: const EdgeInsetsDirectional.only(start: Gap.md - 4, end: Gap.xs),
      horizontalTitleGap: Gap.md - 4,
      leading: ExerciseAvatar(exercise: e),
      title: Text(e?.name ?? item.exerciseId, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${item.targetLabel}$weight$rest${item.notes.isNotEmpty ? '\n${item.notes}' : ''}'),
      isThreeLine: item.notes.isNotEmpty,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: 'Swap', icon: const Icon(Icons.swap_horiz), onPressed: onSwap),
        if (onRemove != null)
          PopupMenuButton<String>(
            onSelected: (_) => onRemove!(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Remove from today'))],
          ),
      ]),
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
