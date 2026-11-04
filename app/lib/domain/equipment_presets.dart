import 'catalog.dart';

/// One-tap equipment setups for the equipment screen.
class EquipmentPreset {
  const EquipmentPreset({required this.label, required this.description, this.unavailable = const {}});

  final String label;
  final String description;

  /// Equipment ids switched off by this preset; everything else is switched on.
  final Set<String> unavailable;

  /// Availability for every switchable (not always-available) equipment item.
  Map<String, bool> availability(Catalog catalog) => {
        for (final e in catalog.equipment)
          if (!e.alwaysAvailable) e.id: !unavailable.contains(e.id),
      };

  static const classicMachineGym = EquipmentPreset(
    label: 'Classic machine gym',
    description: 'Machines, cables, racks, benches and small tools. No medicine ball, foam roller, jump rope or rowing machine.',
    unavailable: {'medicine_ball', 'foam_roller', 'jump_rope', 'rowing_machine'},
  );

  static const everything = EquipmentPreset(
    label: 'Everything available',
    description: 'Switches every piece of equipment on.',
  );

  static const all = [classicMachineGym, everything];
}
