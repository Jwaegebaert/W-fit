import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../domain/muscles.dart';
import '../domain/plan.dart';
import '../providers.dart';
import '../services/coach_service.dart';
import 'common.dart';

enum _Kind {
  pain('pain', 'Pain', Icons.healing_outlined),
  discomfort('discomfort', 'Discomfort', Icons.sentiment_dissatisfied_outlined),
  unavailable('unavailable', 'Equipment unavailable', Icons.build_circle_outlined),
  dislike('dislike', "Doesn't feel right", Icons.thumb_down_alt_outlined),
  tooEasy('too_easy', 'Too easy', Icons.trending_up),
  tooHard('too_hard', 'Too hard', Icons.trending_down),
  note('note', 'Other note', Icons.edit_note);

  const _Kind(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;

  bool get painLike => this == pain || this == discomfort;
  bool get needsExercise => this == dislike || this == tooEasy || this == tooHard;
}

const _severityHints = {
  1: 'Mild: exercises that load the area are avoided when there is an alternative.',
  2: 'Moderate: exercises that load the area are paused until you feel better.',
  3: 'Severe: also no direct work for the muscles around the area.',
};

/// "Report an issue": pain, discomfort, equipment or exercise feedback. Applies the change to upcoming plans at
/// once and shows the coach's reply when the AI is connected. [exerciseId] gives exercise context (preselects the
/// region from its stress tags), [plannedId] the plan to refine, [sessionId] a workout in progress.
Future<void> showReportIssueSheet(BuildContext context, {String? exerciseId, String? plannedId, String? sessionId}) =>
    showAppSheet<void>(
      context,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, controller) => ReportIssueSheet(
          controller: controller,
          exerciseId: exerciseId,
          plannedId: plannedId,
          sessionId: sessionId,
        ),
      ),
    );

class ReportIssueSheet extends ConsumerStatefulWidget {
  const ReportIssueSheet({super.key, this.controller, this.exerciseId, this.plannedId, this.sessionId});

  final ScrollController? controller;
  final String? exerciseId;
  final String? plannedId;
  final String? sessionId;

  @override
  ConsumerState<ReportIssueSheet> createState() => _ReportIssueSheetState();
}

class _ReportIssueSheetState extends ConsumerState<ReportIssueSheet> {
  final _note = TextEditingController();
  _Kind _kind = _Kind.pain;
  BodyRegion? _region;
  int _severity = 2;
  String? _equipment;
  bool _busy = false;
  IssueOutcome? _outcome;
  String? _reply;
  List<FocusChange> _suggestions = const [];
  final _decided = <String, bool>{}; // muscle → accepted?

  @override
  void initState() {
    super.initState();
    final e = widget.exerciseId == null ? null : ref.read(catalogProvider).exercise(widget.exerciseId!);
    _region = e == null || e.stress.isEmpty ? null : BodyRegion.parse(e.stress.first);
    _equipment = e?.equipment.where((id) => id != 'bodyweight').firstOrNull;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _valid => switch (_kind) {
        _Kind.pain || _Kind.discomfort => _region != null || widget.exerciseId != null,
        _Kind.unavailable => _equipment != null || widget.exerciseId != null,
        _Kind.note => _note.text.trim().isNotEmpty,
        _ => widget.exerciseId != null,
      };

  Future<void> _submit() async {
    setState(() => _busy = true);
    final outcome = await ref.read(coachServiceProvider).reportIssue(
          kind: _kind.id,
          region: _kind.painLike ? _region?.id : null,
          severity: _kind.painLike ? _severity : null,
          exerciseId: widget.exerciseId,
          equipmentId: _kind == _Kind.unavailable ? _equipment : null,
          note: _note.text,
          plannedId: widget.plannedId,
          sessionId: widget.sessionId,
        );
    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      _busy = false;
    });
    final review = await outcome.coachReply;
    if (mounted && review != null) {
      setState(() {
        _reply = review.reply;
        _suggestions = review.focusChanges;
      });
    }
  }

  Future<void> _decide(FocusChange c, bool accept) async {
    setState(() => _decided[c.muscle] = accept);
    if (accept) await ref.read(coachServiceProvider).acceptFocusChange(c);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final catalog = ref.watch(catalogProvider);
    final exercise = widget.exerciseId == null ? null : catalog.exercise(widget.exerciseId!);
    final outcome = _outcome;
    final title = t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800);
    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(top: Gap.md, bottom: Gap.sm),
          child: Text(text, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
        );

    if (outcome != null) {
      return ListView(controller: widget.controller, padding: sheetPadding(context), children: [
        Row(children: [
          Icon(Icons.check_circle, color: t.colorScheme.primary),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text('Saved – thanks', style: title)),
        ]),
        const SizedBox(height: Gap.md),
        Text(outcome.changes.isEmpty ? 'No upcoming workout needed changes.' : 'Upcoming workouts adjusted:',
            style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        for (final c in outcome.changes) ChangeLine(change: c),
        if (outcome.coachReply != null)
          Card(
            margin: const EdgeInsets.only(top: Gap.md),
            color: t.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _reply == null
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.auto_awesome, color: t.colorScheme.onSecondaryContainer),
                const SizedBox(width: Gap.item),
                Expanded(
                  child: Text(_reply ?? 'Coach is reviewing…',
                      style: TextStyle(color: t.colorScheme.onSecondaryContainer)),
                ),
              ]),
            ),
          ),
        for (final c in _suggestions) _FocusSuggestion(change: c, decided: _decided[c.muscle], onDecide: (a) => _decide(c, a)),
        const SizedBox(height: Gap.lg),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ]);
    }

    final equipment = [
      ...?exercise?.equipment.where((id) => id != 'bodyweight'),
      for (final e in catalog.equipment)
        if (!e.alwaysAvailable && e.id != 'bodyweight' && !(exercise?.equipment.contains(e.id) ?? false)) e.id,
    ];
    return ListView(controller: widget.controller, padding: sheetPadding(context), children: [
      Text('Report an issue', style: title),
      if (exercise != null) ...[
        const SizedBox(height: Gap.sm),
        Row(children: [
          ExerciseAvatar(exercise: exercise, size: 36),
          const SizedBox(width: Gap.item),
          Expanded(child: Text(exercise.name, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      ],
      label('What happened?'),
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
        for (final k in _Kind.values)
          if (!k.needsExercise || exercise != null)
            ChoiceChip(
              avatar: Icon(k.icon, size: 18),
              label: Text(k.label),
              selected: _kind == k,
              onSelected: (_) => setState(() {
                _kind = k;
                _severity = k == _Kind.pain ? 2 : 1;
              }),
            ),
      ]),
      if (_kind.painLike) ...[
        label(exercise == null ? 'Where?' : 'Where? (optional)'),
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final r in BodyRegion.values)
            ChoiceChip(
              label: Text(r.label),
              selected: _region == r,
              onSelected: (v) => setState(() => _region = v ? r : null),
            ),
        ]),
        label('How bad?'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('Mild')),
            ButtonSegment(value: 2, label: Text('Moderate')),
            ButtonSegment(value: 3, label: Text('Severe')),
          ],
          selected: {_severity},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _severity = s.first),
        ),
        const SizedBox(height: Gap.sm),
        Text(_severityHints[_severity]!, style: t.textTheme.bodySmall),
        if (_severity == 3)
          Card(
            margin: const EdgeInsets.only(top: Gap.sm),
            color: t.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(Gap.item),
              child: Text(
                'Stop the exercise. If the pain is sharp, persistent or radiating, or comes with numbness or '
                'weakness, see a doctor or physiotherapist.',
                style: TextStyle(color: t.colorScheme.onErrorContainer),
              ),
            ),
          ),
      ],
      if (_kind == _Kind.unavailable && equipment.isNotEmpty) ...[
        label('Which equipment?'),
        DropdownButtonFormField<String>(
          initialValue: _equipment,
          isExpanded: true,
          items: [
            for (final id in equipment)
              DropdownMenuItem(value: id, child: Text(catalog.equipmentById(id)?.name ?? id, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _equipment = v),
        ),
      ],
      label('Note'),
      TextField(
        controller: _note,
        minLines: 1,
        maxLines: 4,
        maxLength: 500,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(hintText: 'Anything the coach should know (optional)'),
      ),
      const SizedBox(height: Gap.sm),
      FilledButton.icon(
        onPressed: _busy || !_valid ? null : _submit,
        icon: _busy
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.send),
        label: const Text('Save report'),
      ),
    ]);
  }
}

/// "Leg press → Hack squat" with the reason underneath (plan changes from a report or the plan meta).
class ChangeLine extends ConsumerWidget {
  const ChangeLine({super.key, required this.change});

  final PlanChange change;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final catalog = ref.watch(catalogProvider);
    final to = change.to == null ? 'removed' : catalog.exerciseName(change.to!);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.swap_horiz, size: 18, color: t.colorScheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '${catalog.exerciseName(change.from)} → $to', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (change.reason.isNotEmpty)
              TextSpan(text: '\n${change.reason}', style: t.textTheme.bodySmall),
          ])),
        ),
      ]),
    );
  }
}

/// A muscle-focus change proposed by the coach; nothing is saved until the athlete accepts it.
class _FocusSuggestion extends StatelessWidget {
  const _FocusSuggestion({required this.change, required this.decided, required this.onDecide});

  final FocusChange change;

  /// null = not decided yet, true = accepted, false = dismissed.
  final bool? decided;
  final ValueChanged<bool> onDecide;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: Gap.sm),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.tune_rounded, size: 20, color: s.primary),
            const SizedBox(width: Gap.sm),
            Expanded(child: Text('Muscle focus: ${change.label}', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          if (change.reason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Text(change.reason, style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: switch (decided) {
              true => Padding(
                  padding: const EdgeInsets.all(Gap.sm),
                  child: Text('Saved to your settings', style: t.textTheme.labelLarge?.copyWith(color: s.primary)),
                ),
              false => Padding(
                  padding: const EdgeInsets.all(Gap.sm),
                  child: Text('Dismissed', style: t.textTheme.labelLarge?.copyWith(color: s.onSurfaceVariant)),
                ),
              null => Wrap(spacing: Gap.xs, children: [
                  TextButton(onPressed: () => onDecide(false), child: const Text('Dismiss')),
                  FilledButton.tonal(onPressed: () => onDecide(true), child: const Text('Save to settings')),
                ]),
            },
          ),
        ]),
      ),
    );
  }
}
