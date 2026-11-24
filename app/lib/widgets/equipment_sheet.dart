import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../domain/progression.dart' show formatKg;
import '../features/settings/equipment_screen.dart' show showBarWeightDialog;
import '../providers.dart';
import 'common.dart';
import 'exercise_visuals.dart';

const equipmentGroupLabels = {
  'free': 'Free weights',
  'benches': 'Benches',
  'racks': 'Racks',
  'machines': 'Machines',
  'bodyweight': 'Bodyweight stations',
  'functional': 'Functional',
  'cardio': 'Cardio',
};

/// Shows what a piece of equipment looks like, what it is used for and whether the gym has it.
Future<void> showEquipmentSheet(BuildContext context, String equipmentId) =>
    showAppSheet<void>(context, builder: (_) => EquipmentSheet(equipmentId: equipmentId));

class EquipmentSheet extends ConsumerWidget {
  const EquipmentSheet({super.key, required this.equipmentId});

  final String equipmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final catalog = ref.watch(catalogProvider);
    final eq = catalog.equipmentById(equipmentId);
    final available = ref.watch(equipmentProvider).value?[equipmentId] ?? true;
    final usedIn = catalog.exercises.where((e) => e.equipment.contains(equipmentId)).length;

    return SingleChildScrollView(
      padding: sheetPadding(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Container(
          height: 180,
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: s.primaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(Gap.radius),
          ),
          child: EquipmentIllustration(equipmentId, color: s.onPrimaryContainer),
        ),
        const SizedBox(height: Gap.md),
        Text(eq?.name ?? equipmentId, style: t.textTheme.titleLarge),
        if (eq != null) ...[
          const SizedBox(height: Gap.xs),
          Text(
            equipmentGroupLabels[eq.group] ?? eq.group,
            style: t.textTheme.labelLarge?.copyWith(color: s.primary),
          ),
        ],
        if (eq?.description case final description?) ...[
          const SizedBox(height: Gap.sm),
          Text(description, style: t.textTheme.bodyMedium),
        ],
        const SizedBox(height: Gap.md),
        Row(children: [
          Icon(Icons.fitness_center_rounded, size: 18, color: s.onSurfaceVariant),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              'Used in $usedIn exercise${usedIn == 1 ? '' : 's'}',
              style: t.textTheme.bodyMedium?.copyWith(color: s.onSurfaceVariant),
            ),
          ),
        ]),
        if (eq?.hasBar ?? false)
          Card(
            margin: const EdgeInsets.only(top: Gap.sm),
            color: s.surfaceContainerHigh,
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              title: const Text('Empty bar'),
              subtitle: const Text('You log only the plates; stats add the bar'),
              trailing: Text(
                ref.watch(loadModelProvider).barWeight(equipmentId) > 0
                    ? '${formatKg(ref.watch(loadModelProvider).barWeight(equipmentId))} kg'
                    : 'Not set',
                style: t.textTheme.titleSmall,
              ),
              onTap: () => showBarWeightDialog(context, ref, equipmentId),
            ),
          ),
        const SizedBox(height: Gap.sm),
        if (eq?.alwaysAvailable ?? false)
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.check_circle_outline),
            title: Text('Always available'),
          )
        else
          Card(
            color: s.surfaceContainerHigh,
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              title: const Text('Available in my gym'),
              subtitle: Text(available ? 'Workouts can use it' : 'Workouts and suggestions skip it'),
              value: available,
              onChanged: (v) {
                ref.read(repositoryProvider).setEquipment(equipmentId, v);
                ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
              },
            ),
          ),
      ]),
    );
  }
}
