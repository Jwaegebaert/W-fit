import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final status = ref.watch(equipmentProvider).value ?? const {};
    final repo = ref.read(repositoryProvider);
    final t = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Gym equipment')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
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
                  value: status[e.id] ?? true,
                  onChanged: (v) {
                    repo.setEquipment(e.id, v);
                    ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
                  },
                ),
            ]),
          ),
        ],
      ]),
    );
  }
}
