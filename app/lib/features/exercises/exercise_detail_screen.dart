import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class ExerciseDetailScreen extends ConsumerWidget {
  const ExerciseDetailScreen({super.key, required this.exerciseId});

  final String exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final e = catalog.exercise(exerciseId);
    if (e == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.help_outline, title: 'Unknown exercise'));
    }
    final t = Theme.of(context);
    final equipment = ref.watch(equipmentProvider).value ?? const {};
    final pref = ref.watch(preferencesProvider).value?[e.id] ?? 'neutral';
    final prescription = e.isTimed
        ? '${e.sets} × ${formatSeconds(e.durationSeconds ?? 30)}'
        : '${e.sets} × ${e.repMin}–${e.repMax} reps';

    return Scaffold(
      appBar: AppBar(title: Text(e.name)),
      body: ListView(padding: Gap.page, children: [
        Row(children: [
          ExerciseAvatar(exercise: e, size: 64),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              Pill(_categoryLabel(e.category)),
              Pill(e.pattern.replaceAll('_', ' ')),
              Pill('Level ${e.difficulty}', color: t.colorScheme.tertiary),
              if (e.unilateral) const Pill('Each side'),
            ]),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: StatTile(label: 'Default', value: prescription, icon: Icons.repeat)),
          const SizedBox(width: 10),
          Expanded(child: StatTile(label: 'Rest', value: e.rest == 0 ? '–' : formatSeconds(e.rest), icon: Icons.timer_outlined)),
        ]),
        if (e.badminton != null) ...[
          const SizedBox(height: 12),
          Card(
            color: t.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: Icon(Icons.sports_tennis, color: t.colorScheme.onTertiaryContainer),
              title: Text('Badminton benefit',
                  style: TextStyle(fontWeight: FontWeight.w700, color: t.colorScheme.onTertiaryContainer)),
              subtitle: Text(e.badminton!, style: TextStyle(color: t.colorScheme.onTertiaryContainer)),
            ),
          ),
        ],
        const SectionTitle('How to do it'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < e.instructions.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                    const SizedBox(width: 10),
                    Expanded(child: Text(e.instructions[i])),
                  ]),
                ),
              if (e.tip != null)
                Row(children: [
                  Icon(Icons.lightbulb_outline, color: Colors.amber.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(e.tip!, style: const TextStyle(fontStyle: FontStyle.italic))),
                ]),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => launchUrl(
            Uri.https('www.youtube.com', '/results', {'search_query': '${e.name} exercise proper form'}),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Watch a demonstration'),
        ),
        const SectionTitle('Muscles'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final m in e.primary) Chip(avatar: const Icon(Icons.circle, size: 10), label: Text(prettyMuscle(m))),
          for (final m in e.secondary) Chip(label: Text(prettyMuscle(m))),
        ]),
        const SectionTitle('Equipment'),
        if (e.equipment.isEmpty) const Text('No equipment needed.'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final id in e.equipment)
            Chip(
              avatar: Icon(equipment[id] == false ? Icons.block : Icons.check_circle_outline, size: 18,
                  color: equipment[id] == false ? t.colorScheme.error : t.colorScheme.primary),
              label: Text(catalog.equipmentById(id)?.name ?? id),
            ),
        ]),
        const SectionTitle('Your preference'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'liked', icon: Icon(Icons.thumb_up_outlined), label: Text('Like')),
            ButtonSegment(value: 'neutral', label: Text('Neutral')),
            ButtonSegment(value: 'disliked', icon: Icon(Icons.thumb_down_outlined), label: Text('Dislike')),
            ButtonSegment(value: 'banned', icon: Icon(Icons.block), label: Text('Never')),
          ],
          selected: {pref},
          showSelectedIcon: false,
          onSelectionChanged: (s) => ref.read(repositoryProvider).setPreference(e.id, s.first),
        ),
        const SizedBox(height: 16),
        if (e.category == 'strength' || e.category == 'power')
          FilledButton.tonalIcon(
            onPressed: () => context.push('/progress/${e.id}'),
            icon: const Icon(Icons.show_chart),
            label: const Text('See my progress'),
          ),
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
