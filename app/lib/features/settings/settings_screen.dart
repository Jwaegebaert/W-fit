import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/repositories/repository.dart';
import '../../domain/muscles.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final equipment = ref.watch(equipmentProvider).value ?? const {};
    final unavailable = equipment.values.where((v) => !v).length;
    final config = ref.watch(apiConfigProvider).value;
    final sync = ref.watch(syncControllerProvider);
    final injuries = (ref.watch(activeFeedbackProvider).value ?? const [])
        .where((f) => f.kind == 'pain' || f.kind == 'discomfort')
        .length;
    final liked = (ref.watch(preferencesProvider).value ?? const {}).values.where((v) => v != 'neutral').length;
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final days = parseDays(profile?.trainingDays ?? '1,3,5').map((d) => dayNames[d - 1]).join(', ');

    Widget tile(IconData icon, String title, String subtitle, String route) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(route),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: pagePadding(context), children: [
        const SectionTitle('Training', padding: SectionTitle.first),
        Card(
          child: Column(children: [
            tile(Icons.event_outlined, 'Schedule & session', '$days · ${profile?.sessionMinutes ?? 60} min',
                '/settings/schedule'),
            tile(Icons.tune_rounded, 'Muscle focus', _focusSummary(MuscleFocus.decode(profile?.muscleFocusJson)),
                '/settings/focus'),
            tile(Icons.healing_outlined, 'Injuries', injuries == 0 ? 'None active' : '$injuries active', '/settings/injuries'),
            tile(Icons.menu_book_outlined, 'Exercises',
                liked == 0 ? 'Browse, like or exclude' : '$liked liked or excluded', '/library'),
          ]),
        ),
        const SectionTitle('Gym'),
        Card(
          child: tile(Icons.fitness_center, 'Equipment & bar weights',
              unavailable == 0 ? 'Everything available' : '$unavailable unavailable', '/settings/equipment'),
        ),
        const SectionTitle('Connections'),
        Card(
          child: Column(children: [
            tile(Icons.favorite_border_rounded, 'Samsung Health', 'Workouts and heart rate', '/settings/health'),
            tile(
              config?.isConfigured == true ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              'Cloud & coach',
              config?.isConfigured != true
                  ? 'Not connected, everything stays on this phone'
                  : sync.error != null
                      ? 'Last sync failed'
                      : 'Connected',
              '/settings/connection',
            ),
          ]),
        ),
        const SectionTitle('You'),
        Card(
          child: tile(Icons.person_outline, 'About you', 'Name, goals, height', '/settings/profile'),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Gap.md),
          child: Text('W-fit 0.1.0',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

/// "Less: shoulders · More: glutes · Light: lower back", or a default line.
String _focusSummary(MuscleFocus f) {
  if (f.isEmpty) return 'All muscles normal';
  String names(Iterable<String> ids) => ids.map((m) => trackedMuscles[m]?.label.toLowerCase() ?? m).join(', ');
  final less = [for (final m in trackedMuscleInfo) if (f.levelOf(m.id) == FocusLevel.less) m.id];
  final more = [for (final m in trackedMuscleInfo) if (f.levelOf(m.id) == FocusLevel.more) m.id];
  return [
    if (less.isNotEmpty) 'Less: ${names(less)}',
    if (more.isNotEmpty) 'More: ${names(more)}',
    if (f.light.isNotEmpty) 'Light: ${names(f.light)}',
  ].join(' · ');
}
