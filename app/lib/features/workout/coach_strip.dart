import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';

/// Compact guidance at the top of an open exercise card:
///
/// * one row of chips – **Last** (previous session), **Today** (target weight) and **Aim** (target reps / time);
/// * one line with the most relevant note (the coach's note when the coach wrote one, otherwise the progression
///   advice), marked "Coach" when the coach changed or wrote this exercise;
/// * tapping the line reveals the rest: progression advice, why the coach changed it, and the form tip.
class CoachStrip extends StatefulWidget {
  const CoachStrip({
    super.key,
    required this.item,
    required this.exercise,
    required this.loads,
    this.advice,
    this.showProgress = true,
    this.fromCoach = false,
    this.change,
  });

  final PlanItem item;
  final Exercise? exercise;
  final LoadModel loads;
  final ProgressionAdvice? advice;

  /// Main-block exercises show Last / Today / Aim; warm-up and cool-down only the note line.
  final bool showProgress;

  /// The plan came from the AI coach, so [PlanItem.notes] is the coach's note.
  final bool fromCoach;

  /// The coach (or an instant adjustment) put this exercise in the plan; its reason is shown on expand.
  final PlanChange? change;

  @override
  State<CoachStrip> createState() => _CoachStripState();
}

class _CoachStripState extends State<CoachStrip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final item = widget.item;
    final e = widget.exercise;
    final advice = widget.advice;
    final note = item.notes.trim();
    final coachNote = widget.fromCoach && note.isNotEmpty;
    final coachy = coachNote || widget.change != null;

    // Line text: the coach's own words first, then the progression advice, then any plan note.
    final adviceText = widget.showProgress ? (advice?.message ?? '') : '';
    final headline = coachNote
        ? note
        : adviceText.isNotEmpty
            ? adviceText
            : note.isNotEmpty
                ? note
                : (e?.tip ?? '');
    final details = <(IconData, String)>[
      if (adviceText.isNotEmpty && adviceText != headline) (Icons.trending_up_rounded, adviceText),
      if (note.isNotEmpty && note != headline) (Icons.sticky_note_2_outlined, note),
      if (widget.change case final c? when c.reason.isNotEmpty) (Icons.swap_horiz_rounded, 'Changed: ${c.reason}'),
      if (e?.tip case final tip? when tip != headline) (Icons.lightbulb_outline_rounded, tip),
    ];

    final chips = widget.showProgress ? _chips(context) : const <Widget>[];
    if (chips.isEmpty && headline.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Gap.item),
      decoration: BoxDecoration(
        color: s.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Wrap(spacing: 6, runSpacing: 6, children: chips),
          ),
        if (headline.isNotEmpty)
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: details.isEmpty ? null : () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (coachy) ...[
                    _Badge(label: 'Coach', color: s.tertiary),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      headline,
                      maxLines: _open ? null : 1,
                      overflow: _open ? null : TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(color: s.onSecondaryContainer),
                    ),
                  ),
                  if (details.isNotEmpty)
                    Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: s.onSecondaryContainer),
                ]),
                if (_open)
                  for (final (icon, text) in details)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(icon, size: 16, color: s.onSecondaryContainer),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: s.onSecondaryContainer)),
                        ),
                      ]),
                    ),
              ]),
            ),
          )
        else
          const SizedBox(height: 10),
      ]),
    );
  }

  List<Widget> _chips(BuildContext context) {
    final item = widget.item;
    final advice = widget.advice;
    final weight = item.targetWeightKg ?? advice?.weightKg;
    final side = item.perSide || (widget.exercise?.unilateral ?? false) ? ' / side' : '';
    final aim = item.isTimed
        ? '${formatSeconds(item.durationSeconds ?? 30)}$side'
        : advice?.targetReps != null
            ? '${advice!.targetReps} reps$side'
            : item.repMin == null
                ? ''
                : '${item.repMin == item.repMax || item.repMax == null ? item.repMin : '${item.repMin}–${item.repMax}'} reps$side';
    return [
      if (advice?.lastSummary case final last?) _Chip(label: 'Last', value: last),
      if (weight != null) _Chip(label: 'Today', value: widget.loads.weightLabel(widget.exercise, weight), strong: true),
      if (aim.isNotEmpty) _Chip(label: 'Aim', value: aim),
    ];
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value, this.strong = false});

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: strong ? s.primaryContainer : s.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '$label ', style: TextStyle(color: s.onSurfaceVariant)),
          TextSpan(
            text: value,
            style: TextStyle(fontWeight: FontWeight.w700, color: strong ? s.onPrimaryContainer : s.onSurface),
          ),
        ]),
        style: t.textTheme.labelMedium,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome, size: 12, color: color),
          const SizedBox(width: 3),
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
        ]),
      );
}
