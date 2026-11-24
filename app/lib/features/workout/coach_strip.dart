import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';

/// Compact guidance at the top of an open exercise card:
///
/// * one line with the last session and today's aim (the weight itself is in the fields below);
/// * a second line only when there is something particular: the coach's note or change, or a first-time hint;
/// * tapping reveals the rest: progression advice, why the coach changed it, and the form tip.
class CoachStrip extends StatefulWidget {
  const CoachStrip({
    super.key,
    required this.item,
    required this.exercise,
    this.advice,
    this.fromCoach = false,
    this.change,
  });

  final PlanItem item;
  final Exercise? exercise;
  final ProgressionAdvice? advice;

  /// The plan came from the AI coach, so [PlanItem.notes] is the coach's note.
  final bool fromCoach;

  /// The coach (or an instant adjustment) put this exercise in the plan; its reason is shown on expand.
  final PlanChange? change;

  @override
  State<CoachStrip> createState() => _CoachStripState();
}

class _CoachStripState extends State<CoachStrip> {
  bool _open = false;

  bool get _focusSwap => widget.change?.reason.startsWith('Go light') ?? false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final item = widget.item;
    final advice = widget.advice;
    final note = item.notes.trim();
    final coachNote = widget.fromCoach && note.isNotEmpty;
    final coachy = coachNote || widget.change != null;
    final last = advice?.lastSummary;
    final adviceText = advice?.message ?? '';

    // The line worth reading now: the coach's words or the hint for a first time. Notes of the rules plan (like
    // "Anchor") are the same every week and stay behind the tap.
    final headline = coachNote
        ? note
        : coachy
            ? widget.change!.reason
            : last == null
                ? adviceText
                : '';
    final details = <(IconData, String)>[
      if (adviceText.isNotEmpty && adviceText != headline) (Icons.trending_up_rounded, adviceText),
      if (note.isNotEmpty && note != headline) (Icons.sticky_note_2_outlined, note),
      if (widget.change case final c? when c.reason.isNotEmpty && c.reason != headline)
        (Icons.swap_horiz_rounded, 'Changed: ${c.reason}'),
      if (widget.exercise?.tip case final tip? when tip != headline) (Icons.lightbulb_outline_rounded, tip),
    ];
    final aim = _aim();
    final style = t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant);
    const strong = TextStyle(fontWeight: FontWeight.w700);

    return Semantics(
      button: details.isNotEmpty,
      expanded: details.isEmpty ? null : _open,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: details.isEmpty ? null : () => setState(() => _open = !_open),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Gap.tap),
          child: Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(style: style, children: [
                      if (last != null) ...[
                        const TextSpan(text: 'Last '),
                        TextSpan(text: last, style: strong),
                        const TextSpan(text: ' · '),
                      ],
                      TextSpan(text: last == null ? 'Aim ' : 'aim '),
                      TextSpan(text: aim, style: strong.copyWith(color: s.onSurface)),
                    ]),
                  ),
                ),
                if (details.isNotEmpty)
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: s.onSurfaceVariant),
              ]),
              if (headline.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (coachy) ...[
                      // Swaps made by the "go light" setting are the athlete's own choice, not the coach's.
                      _Badge(label: coachNote || !_focusSwap ? 'Coach' : 'Focus', color: s.gold),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        headline,
                        maxLines: _open ? null : 2,
                        overflow: _open ? null : TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                  ]),
                ),
              if (_open)
                for (final (icon, text) in details)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(icon, size: 18, color: s.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(child: Text(text, style: style)),
                    ]),
                  ),
            ]),
          ),
        ),
      ),
    );
  }

  /// The same number the reps field shows and a tick logs.
  String _aim() {
    final item = widget.item;
    final side = item.perSide || (widget.exercise?.unilateral ?? false) ? ' / side' : '';
    if (item.isTimed) return '${formatSeconds(item.durationSeconds ?? 30)}$side';
    return '${widget.advice?.targetReps ?? item.repMax ?? item.repMin ?? 10} reps$side';
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
