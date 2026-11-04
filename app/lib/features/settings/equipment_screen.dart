import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/equipment_presets.dart';
import '../../providers.dart';

class EquipmentScreen extends ConsumerWidget {
  const EquipmentScreen({super.key});

  static const _groups = {
    'free': 'Free weights',
    'benches': 'Benches',
    'racks': 'Racks',
    'machines': 'Machines',
    'bodyweight': 'Bodyweight stations',
    'functional': 'Functional',
    'cardio': 'Cardio',
  };

  Future<void> _applyPreset(BuildContext context, WidgetRef ref, EquipmentPreset preset) async {
    final catalog = ref.read(catalogProvider);
    final off = catalog.equipment.where((e) => preset.unavailable.contains(e.id)).map((e) => e.name).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Apply "${preset.label}"?'),
        content: Text(off.isEmpty
            ? 'All equipment will be switched on.'
            : 'Switches off: ${off.join(', ')}.\n\nEverything else will be switched on.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(repositoryProvider);
    for (final entry in preset.availability(catalog).entries) {
      await repo.setEquipment(entry.key, entry.value);
    }
    ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${preset.label} applied')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final status = ref.watch(equipmentProvider).value ?? const {};
    final repo = ref.read(repositoryProvider);
    final t = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Gym equipment')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick setup', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Start from a preset, then fine-tune the switches below.', style: t.textTheme.bodySmall),
                const SizedBox(height: 12),
                for (final preset in EquipmentPreset.all)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                      onPressed: () => _applyPreset(context, ref, preset),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(preset.label),
                        Text(
                          preset.description,
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            color: t.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Switch off anything your gym does not have. Workouts and AI suggestions will never use it. '
                'Equipment that is just busy can be skipped during a workout with "Swap → Occupied".',
                style: TextStyle(color: t.colorScheme.onSecondaryContainer),
              ),
            ),
          ),
          for (final g in _groups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
              child: Text(g.value, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Card(
              child: Column(children: [
                for (final e in catalog.equipment.where((e) => e.group == g.key && !e.alwaysAvailable))
                  SwitchListTile(
                    title: Text(e.name),
                    subtitle: e.description == null
                        ? null
                        : Text(e.description!, maxLines: 2, overflow: TextOverflow.ellipsis),
                    value: status[e.id] ?? true,
                    onChanged: (v) {
                      repo.setEquipment(e.id, v);
                      ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
                    },
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }
}
