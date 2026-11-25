import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/equipment_presets.dart';
import '../../domain/progression.dart' show formatKg;
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/equipment_sheet.dart';

/// Lets the user set the empty-bar weight of [equipmentId] (e.g. their gym's Smith machine).
Future<void> showBarWeightDialog(BuildContext context, WidgetRef ref, String equipmentId) async {
  final catalog = ref.read(catalogProvider);
  final equipment = catalog.equipmentById(equipmentId);
  if (equipment == null) return;
  final current = ref.read(loadModelProvider).barWeight(equipmentId);
  final kg = await showDialog<double>(
    context: context,
    builder: (_) => _BarWeightDialog(
      title: '${equipment.name}: bar weight',
      hint: equipmentId == 'smith_machine'
          ? 'Smith machine bars differ per gym (often 10–20 kg; some are counterbalanced). Check the label on '
              'the machine.'
          : 'Standard: ${formatKg(equipment.barWeightKg)} kg. Change it if your gym\'s bar is different.',
      current: current,
    ),
  );
  if (kg == null) return;
  await ref.read(repositoryProvider).setBarWeight(equipmentId, kg);
  ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
}

/// Owns its text controller, so the field stays valid while the dialog animates out.
class _BarWeightDialog extends StatefulWidget {
  const _BarWeightDialog({required this.title, required this.hint, required this.current});

  final String title;
  final String hint;
  final double current;

  @override
  State<_BarWeightDialog> createState() => _BarWeightDialogState();
}

class _BarWeightDialogState extends State<_BarWeightDialog> {
  late final _controller = TextEditingController(text: widget.current > 0 ? formatKg(widget.current) : '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = double.tryParse(_controller.text.replaceAll(',', '.'));
    if (v != null && v >= 0 && v <= 60) Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.hint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Empty bar', suffixText: 'kg'),
            onSubmitted: (_) => _submit(),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _submit, child: const Text('Save')),
        ],
      );
}

/// What the gym has: groups with a count, a switch per piece; tapping a piece shows it (with its bar weight).
class EquipmentScreen extends ConsumerWidget {
  const EquipmentScreen({super.key});

  Future<void> _applyPreset(BuildContext context, WidgetRef ref, EquipmentPreset preset) async {
    final catalog = ref.read(catalogProvider);
    final off = catalog.equipment.where((e) => preset.unavailable.contains(e.id)).map((e) => e.name).toList();
    final ok = await confirmDestructive(
      context,
      title: 'Apply "${preset.label}"?',
      message: off.isEmpty
          ? 'All equipment will be switched on.'
          : 'Switches off: ${off.join(', ')}.\n\nEverything else will be switched on.',
      action: 'Apply',
    );
    if (!ok) return;
    final repo = ref.read(repositoryProvider);
    for (final entry in preset.availability(catalog).entries) {
      await repo.setEquipment(entry.key, entry.value);
    }
    ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    if (context.mounted) showSnack(context, '${preset.label} applied');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogProvider);
    final status = ref.watch(equipmentProvider).value ?? const {};
    final loads = ref.watch(loadModelProvider);
    final t = Theme.of(context);
    final s = t.colorScheme;
    bool has(Equipment e) => status[e.id] ?? true;
    final numbered = [for (final e in catalog.equipment) if (loads.plates.containsKey(e.id)) e.name];
    final unset = catalog.equipment.where((e) => e.hasBar && has(e) && loads.barWeight(e.id) <= 0).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Equipment'), actions: [
        PopupMenuButton<EquipmentPreset>(
          tooltip: 'Presets',
          icon: const Icon(Icons.checklist_rounded),
          onSelected: (p) => _applyPreset(context, ref, p),
          itemBuilder: (_) => [
            for (final p in EquipmentPreset.all) PopupMenuItem(value: p, child: Text(p.label)),
          ],
        ),
        const HelpButton(
          title: 'Equipment',
          text: 'Switch off what your gym does not have; workouts and your coach then never use it. For something that is '
              'just busy, use Swap during the workout.\n\n'
              'For bar exercises you log only the plates. Your records and stats add the empty bar; tap a bar to set its '
              'weight.\n\n'
              'For machines with numbers instead of kg on the stack you log the plate number; see Numbered machines.',
        ),
      ]),
      body: ListView(padding: pagePadding(context), children: [
        for (final e in unset)
          Card(
            margin: const EdgeInsets.only(bottom: Gap.item),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(Icons.error_outline_rounded, color: s.attention),
              title: Text('Set the bar weight of your ${e.name.toLowerCase()}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showBarWeightDialog(context, ref, e.id),
            ),
          ),
        Card(
          margin: const EdgeInsets.only(bottom: Gap.item),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: const Icon(Icons.format_list_numbered_rounded),
            title: const Text('Numbered machines'),
            subtitle: Text(
              numbered.isEmpty ? 'For stacks marked 2, 4, 6 instead of kg' : numbered.join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/equipment/stacks'),
          ),
        ),
        for (final g in equipmentGroupLabels.entries)
          if (catalog.equipment.where((e) => e.group == g.key && !e.alwaysAvailable).toList() case final group
              when group.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.item),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                shape: const Border(),
                title: Text(g.value, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${group.where(has).length} of ${group.length} available'),
                children: [
                  for (final e in group)
                    ListTile(
                      title: Text(e.name),
                      subtitle: e.hasBar
                          ? Text(loads.barWeight(e.id) > 0 ? 'Bar ${formatKg(loads.barWeight(e.id))} kg' : 'Bar weight not set')
                          : loads.plates[e.id] == null
                              ? null
                              : Text('Numbered, ${formatKg(loads.plates[e.id])} kg per plate'),
                      onTap: () => showEquipmentSheet(context, e.id),
                      trailing: Semantics(
                        label: '${e.name} available',
                        child: Switch(
                          value: has(e),
                          onChanged: (v) {
                            ref.read(repositoryProvider).setEquipment(e.id, v);
                            ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
      ]),
    );
  }
}
