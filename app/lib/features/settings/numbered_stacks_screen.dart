import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/progression.dart' show formatKg;
import '../../providers.dart';
import '../../widgets/common.dart';

/// "2 = 10 kg · 4 = 20 kg · 10 = 50 kg" for plates of [plateKg]; what a stack marked in kg says when null.
String stackSummary(double? plateKg) =>
    plateKg == null ? 'Marked in kg' : [for (final n in const [2, 4, 10]) '$n = ${formatKg(n * plateKg)} kg'].join(' · ');

/// Lets the user say that the stack of [equipmentId] is numbered and what one plate weighs, or that it is in kg.
Future<void> showPlateDialog(BuildContext context, WidgetRef ref, String equipmentId) async {
  final equipment = ref.read(catalogProvider).equipmentById(equipmentId);
  if (equipment == null) return;
  final repo = ref.read(repositoryProvider);
  final sync = ref.read(syncControllerProvider.notifier);
  final current = ref.read(loadModelProvider).plates[equipmentId];
  final logged = current == null ? await repo.countKgSets(equipmentId) : 0;
  if (!context.mounted) return;
  final choice = await showDialog<_PlateChoice>(
    context: context,
    builder: (_) => _PlateDialog(title: equipment.name, current: current, loggedInKg: logged),
  );
  if (choice == null) return;
  await repo.setStackPlate(equipmentId, choice.kg, numbersLogged: choice.numbersLogged);
  sync.syncNow(onlyIfStale: true);
}

class _PlateChoice {
  const _PlateChoice(this.kg, {this.numbersLogged = false});

  /// Null: the stack is marked in kg.
  final double? kg;
  final bool numbersLogged;
}

class _PlateDialog extends StatefulWidget {
  const _PlateDialog({required this.title, required this.current, required this.loggedInKg});

  final String title;
  final double? current;

  /// Sets logged on this machine without a plate number.
  final int loggedInKg;

  @override
  State<_PlateDialog> createState() => _PlateDialogState();
}

class _PlateDialogState extends State<_PlateDialog> {
  late final _controller = TextEditingController(text: widget.current == null ? '' : _text(widget.current!));
  bool _numbersLogged = false;

  /// American stacks are cast in pounds.
  static const _pounds = [10, 15, 20];
  static const _kgPerPound = 0.45359237;

  /// Two decimals: 10 lb plates are 4.54 kg.
  static String _text(double kg) => kg.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _kg {
    final v = double.tryParse(_controller.text.replaceAll(',', '.'));
    return v != null && v >= 0.5 && v <= 50 ? v : null;
  }

  void _save() {
    if (_kg case final kg?) Navigator.pop(context, _PlateChoice(kg, numbersLogged: _numbersLogged));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final n = widget.loggedInKg;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('What does one plate weigh? The numbers count plates: the one without a number between 2 and 4 is 3.'),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'One plate',
              suffixText: 'kg',
              helperText: _kg == null ? ' ' : stackSummary(_kg),
              helperMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: Gap.sm),
          Wrap(spacing: Gap.sm, children: [
            for (final lb in _pounds)
              ActionChip(
                label: Text('$lb lb'),
                onPressed: () => setState(() => _controller.text = _text(lb * _kgPerPound)),
              ),
          ]),
          if (n > 0)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('I logged plate numbers before ($n set${n == 1 ? '' : 's'})', style: t.textTheme.bodyMedium),
              subtitle: const Text('Turns them into their real weight'),
              value: _numbersLogged,
              onChanged: (v) => setState(() => _numbersLogged = v ?? false),
            ),
        ]),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () => Navigator.pop(context, const _PlateChoice(null)),
            child: const Text('Use kg'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _kg == null ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

/// Which machines have numbers instead of kg on their weight stack.
class NumberedStacksScreen extends ConsumerWidget {
  const NumberedStacksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(equipmentProvider).value ?? const {};
    final plates = ref.watch(loadModelProvider).plates;
    final machines = [
      for (final e in ref.watch(catalogProvider).equipment)
        if (e.hasStack && ((status[e.id] ?? true) || plates.containsKey(e.id))) e,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Numbered machines'), actions: const [
        HelpButton(
          title: 'Numbered machines',
          text: 'Some machines, like older Cybex ones, have 2, 4, 6, 8 on the weight stack instead of kg.\n\n'
              'Switch such a machine on and fill in what one plate weighs. During the workout you see and log the plate '
              'number; your records, stats and coach use the real weight.\n\n'
              'If the plates turn out to weigh something else, change it here: the sets you logged by number follow.',
        ),
      ]),
      body: ListView(padding: pagePadding(context), children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final e in machines)
              ListTile(
                title: Text(e.name),
                subtitle: Text(stackSummary(plates[e.id])),
                onTap: () => showPlateDialog(context, ref, e.id),
                trailing: Semantics(
                  label: '${e.name} numbered',
                  child: Switch(
                    value: plates.containsKey(e.id),
                    onChanged: (on) async {
                      if (on) return showPlateDialog(context, ref, e.id);
                      await ref.read(repositoryProvider).setStackPlate(e.id, null);
                      ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
                    },
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}
