import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/equipment_sheet.dart';
import '../../widgets/exercise_visuals.dart';
import '../settings/equipment_screen.dart' show showBarWeightDialog;

class ExerciseDetailScreen extends ConsumerWidget {
  const ExerciseDetailScreen({super.key, required this.exerciseId});

  final String exerciseId;

  /// How weight is logged for [e] (title, explanation); null when it is a plain weight exercise.
  static (String, String)? _loadNote(Exercise e, WidgetRef ref) {
    if (e.bar != null) {
      final bar = ref.watch(loadModelProvider).barWeight(e.bar!);
      final name = ref.read(catalogProvider).equipmentById(e.bar!)?.name ?? 'Bar';
      String fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
      return bar > 0
          ? ('Bar: ${fmt(bar)} kg', 'Log only the plates (both sides together). Your stats add the ${fmt(bar)} kg bar. Tap to change.')
          : ('Bar weight not set', '$name bars differ per gym. Tap to set it; log only the plates.');
    }
    return switch (e.load) {
      LoadType.assist => ('Assisted machine', 'Log the assistance. More kg makes it easier, so you progress by lowering it.'),
      LoadType.optional => ('Bodyweight', 'Add extra weight (belt or dumbbell) only once all sets reach the top of the range.'),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final e = catalog.exercise(exerciseId);
    if (e == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.help_outline, title: 'Unknown exercise'));
    }
    final t = Theme.of(context);
    final s = t.colorScheme;
    final kind = ExerciseKind.of(e, catalog);
    final gear = e.equipment.where((id) => !(catalog.equipmentById(id)?.alwaysAvailable ?? false)).toList();

    return Scaffold(
      appBar: AppBar(title: Text(_categoryLabel(e.category))),
      body: ListView(padding: pagePadding(context), children: [
        ExerciseDemo(exercise: e),
        const SizedBox(height: Gap.md),
        Text(e.name, style: t.textTheme.headlineSmall),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _KindLabel(kind),
          if (e.unilateral) Pill('Each side', color: s.tertiary, icon: Icons.swap_horiz_rounded),
        ]),
        const SizedBox(height: Gap.md),
        _FactsStrip(exercise: e),
        if (_loadNote(e, ref) case final note?) ...[
          const SizedBox(height: Gap.sm),
          Card(
            color: s.secondaryContainer,
            child: ListTile(
              leading: Icon(e.bar != null ? Icons.horizontal_rule_rounded : Icons.info_outline,
                  color: s.onSecondaryContainer),
              title: Text(note.$1, style: TextStyle(color: s.onSecondaryContainer, fontWeight: FontWeight.w700)),
              subtitle: Text(note.$2, style: TextStyle(color: s.onSecondaryContainer)),
              trailing: e.bar != null ? Icon(Icons.edit_outlined, color: s.onSecondaryContainer) : null,
              onTap: e.bar != null ? () => showBarWeightDialog(context, ref, e.bar!) : null,
            ),
          ),
        ],
        const SectionTitle('How to do it'),
        _Steps(e.instructions),
        if (e.tip != null || e.mistakes.isNotEmpty) ...[
          const SectionTitle('Form check'),
          _FormCheck(tip: e.tip, mistakes: e.mistakes),
        ],
        const SectionTitle('Equipment'),
        _EquipmentList(gear),
        const SectionTitle('Muscles'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final m in e.primary) Pill(prettyMuscle(m), color: s.primary),
          for (final m in e.secondary) Pill(prettyMuscle(m), color: s.onSurfaceVariant),
        ]),
        if (e.badminton != null) ...[
          const SizedBox(height: Gap.md),
          _BadmintonCard(e.badminton!),
        ],
        const SizedBox(height: Gap.lg),
        OutlinedButton.icon(
          onPressed: () => launchUrl(
            Uri.https('www.youtube.com', '/results', {'search_query': '${e.name} exercise proper form'}),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Watch a demo'),
        ),
        if (e.category == 'strength' || e.category == 'power') ...[
          const SizedBox(height: Gap.sm),
          FilledButton.tonalIcon(
            onPressed: () => context.push('/progress/${e.id}'),
            icon: const Icon(Icons.show_chart),
            label: const Text('See my progress'),
          ),
        ],
        _PreferencePicker(exerciseId: e.id),
      ]),
    );
  }

  static String _categoryLabel(String c) => switch (c) {
        'warmup' => 'Warm-up',
        'strength' => 'Strength',
        'power' => 'Power',
        'core' => 'Core',
        'cooldown' => 'Mobility',
        _ => c,
      };
}

class _KindLabel extends StatelessWidget {
  const _KindLabel(this.kind);

  final ExerciseKind kind;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        KindIcon(kind, size: 18, color: c),
        const SizedBox(width: 6),
        Flexible(
          child: Text(kind.label, style: t.textTheme.labelLarge?.copyWith(color: c, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

class _FactsStrip extends StatelessWidget {
  const _FactsStrip({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context) {
    final e = exercise;
    final reps = e.repMin == e.repMax || e.repMax == null ? '${e.repMin ?? '–'}' : '${e.repMin}–${e.repMax}';
    final facts = [
      (
        e.isTimed ? '${e.sets} × ${formatSeconds(e.durationSeconds ?? 30)}' : '${e.sets} × $reps',
        e.isTimed ? (e.unilateral ? 'time per side' : 'sets × time') : (e.unilateral ? 'reps per side' : 'sets × reps'),
      ),
      (e.rest == 0 ? 'None' : formatSeconds(e.rest), 'rest'),
      (
        switch (e.difficulty) {
          <= 1 => 'Beginner',
          2 => 'Intermediate',
          _ => 'Advanced',
        },
        'level',
      ),
    ];
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: IntrinsicHeight(
          child: Row(children: [
            for (final (i, (value, label)) in facts.indexed) ...[
              if (i > 0) VerticalDivider(width: 1, color: t.colorScheme.outlineVariant),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                  child: Column(children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(value, maxLines: 1, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(height: 2),
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps(this.steps);

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (i, step) in steps.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.only(top: 1),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: s.primaryContainer, shape: BoxShape.circle),
                  child: Text('${i + 1}',
                      textScaler: TextScaler.noScaling,
                      style: t.textTheme.labelSmall?.copyWith(color: s.onPrimaryContainer, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(step, style: t.textTheme.bodyMedium)),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _FormCheck extends StatelessWidget {
  const _FormCheck({required this.tip, required this.mistakes});

  final String? tip;
  final List<String> mistakes;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    Widget line(IconData icon, Color color, String text) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
          ]),
        );
    Widget heading(String text, Color color) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(text, style: t.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700)),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (tip != null) ...[
            heading('Key cue', s.tertiary),
            line(Icons.lightbulb_outline_rounded, s.tertiary, tip!),
          ],
          if (tip != null && mistakes.isNotEmpty) const Divider(height: Gap.md),
          if (mistakes.isNotEmpty) ...[
            heading('Common mistakes', s.error),
            for (final m in mistakes) line(Icons.close_rounded, s.error, m),
          ],
        ]),
      ),
    );
  }
}

class _EquipmentList extends ConsumerWidget {
  const _EquipmentList(this.ids);

  final List<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    if (ids.isEmpty) {
      return Card(
        child: ListTile(
          leading: _Thumb(child: KindIcon(ExerciseKind.bodyweight, size: 26, color: s.onPrimaryContainer)),
          title: const Text('No equipment needed'),
          subtitle: const Text('Just your bodyweight'),
        ),
      );
    }
    final catalog = ref.watch(catalogProvider);
    final status = ref.watch(equipmentProvider).value ?? const {};
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (final (i, id) in ids.indexed) ...[
          if (i > 0) const Divider(height: 1, indent: 88),
          Builder(builder: (context) {
            final available = status[id] ?? true;
            return ListTile(
              onTap: () => showEquipmentSheet(context, id),
              leading: _Thumb(child: EquipmentIllustration(id, color: s.onPrimaryContainer)),
              title: Text(catalog.equipmentById(id)?.name ?? id),
              subtitle: Row(children: [
                Icon(available ? Icons.check_circle_rounded : Icons.block_rounded,
                    size: 14, color: available ? s.primary : s.error),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    available ? 'In your gym' : 'Not in your gym',
                    style: TextStyle(color: available ? s.onSurfaceVariant : s.error),
                  ),
                ),
              ]),
              trailing: const Icon(Icons.chevron_right_rounded),
            );
          }),
        ],
      ]),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        width: 56,
        height: 42,
        padding: const EdgeInsets.all(4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(Gap.radiusSm),
        ),
        child: child,
      );
}

class _BadmintonCard extends StatelessWidget {
  const _BadmintonCard(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final fg = t.colorScheme.onTertiaryContainer;
    return Card(
      color: t.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.sports_tennis, size: 20, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'For badminton: ', style: TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: text),
              ]),
              style: t.textTheme.bodyMedium?.copyWith(color: fg),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PreferencePicker extends ConsumerWidget {
  const _PreferencePicker({required this.exerciseId});

  final String exerciseId;

  static const _hints = {
    'liked': 'Liked: picked more often',
    'neutral': 'Neutral: normal rotation',
    'disliked': 'Disliked: picked less often',
    'banned': 'Never: left out of your plans',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pref = ref.watch(preferencesProvider).value?[exerciseId] ?? 'neutral';
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Your preference'),
      SegmentedButton<String>(
        expandedInsets: EdgeInsets.zero,
        segments: const [
          ButtonSegment(value: 'liked', icon: Icon(Icons.thumb_up_outlined), tooltip: 'Like'),
          ButtonSegment(value: 'neutral', icon: Icon(Icons.thumbs_up_down_outlined), tooltip: 'Neutral'),
          ButtonSegment(value: 'disliked', icon: Icon(Icons.thumb_down_outlined), tooltip: 'Dislike'),
          ButtonSegment(value: 'banned', icon: Icon(Icons.block), tooltip: 'Never'),
        ],
        selected: {pref},
        showSelectedIcon: false,
        onSelectionChanged: (s) => ref.read(repositoryProvider).setPreference(exerciseId, s.first),
      ),
      const SizedBox(height: Gap.sm),
      Text(
        _hints[pref] ?? '',
        textAlign: TextAlign.center,
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    ]);
  }
}
