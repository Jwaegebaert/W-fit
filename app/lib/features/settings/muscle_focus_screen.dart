import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/muscles.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../dashboard/dashboard_screen.dart';

/// Per muscle: less / normal / more (scales its weekly target band) and "go light" (no heavy loading).
/// Changes are saved straight away and applied to every open plan (see `CoachService.saveMuscleFocus`).
class MuscleFocusScreen extends ConsumerStatefulWidget {
  const MuscleFocusScreen({super.key});

  @override
  ConsumerState<MuscleFocusScreen> createState() => _MuscleFocusScreenState();
}

class _MuscleFocusScreenState extends ConsumerState<MuscleFocusScreen> {
  MuscleFocus? _focus;
  bool _saving = false;

  Future<void> _set(MuscleFocus focus) async {
    setState(() {
      _focus = focus;
      _saving = true;
    });
    await ref.read(coachServiceProvider).saveMuscleFocus(focus);
    ref.invalidate(nextPlanProvider);
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _edit(MuscleInfo info, MuscleFocus focus) async {
    var chosen = focus;
    await showAppSheet<void>(context,
        builder: (_) => _MuscleSheet(info: info, focus: focus, onChanged: (f) => chosen = f));
    if (mounted && chosen.encode() != focus.encode()) await _set(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final focus = _focus ?? MuscleFocus.decode(profile.muscleFocusJson);
    bool changed(MuscleInfo m) => focus.levelOf(m.id) != FocusLevel.normal || focus.isLight(m.id);
    final own = trackedMuscleInfo.where(changed).toList();

    Widget list(Iterable<MuscleInfo> muscles) => Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (final m in muscles) _MuscleTile(info: m, focus: focus, onTap: () => _edit(m, focus)),
          ]),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Muscle focus'),
        actions: [
          if (!focus.isEmpty)
            TextButton(onPressed: _saving ? null : () => _set(MuscleFocus.none), child: const Text('Reset')),
          const HelpButton(
            title: 'Muscle focus',
            text: 'Less lowers a muscle\'s weekly target and gives it no extra work; More raises it.\n\n'
                'Go light keeps a muscle away from heavy sets: 10–15 reps and, where there is an alternative, no barbell '
                'or Smith lifts.\n\n'
                'Changes apply to your planned workouts, not to one you are doing right now. You can also tell your coach '
                '("go easy on my shoulders") and save its suggestion.',
          ),
        ],
        bottom: _saving
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: ListView(padding: pagePadding(context), children: [
        if (own.isNotEmpty) ...[
          const SectionTitle('Changed', padding: SectionTitle.first),
          list(own),
        ],
        for (final (i, group) in MuscleGroup.values.indexed)
          if (trackedMuscleInfo.any((m) => m.group == group && !changed(m))) ...[
            i == 0 && own.isEmpty
                ? SectionTitle(group.label, padding: SectionTitle.first)
                : SectionTitle(group.label),
            list(trackedMuscleInfo.where((m) => m.group == group && !changed(m))),
          ],
      ]),
    );
  }
}

class _MuscleTile extends StatelessWidget {
  const _MuscleTile({required this.info, required this.focus, required this.onTap});

  final MuscleInfo info;
  final MuscleFocus focus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final level = focus.levelOf(info.id);
    final light = focus.isLight(info.id);
    final normal = level == FocusLevel.normal && !light;
    return ListTile(
      title: Text(info.label),
      trailing: Text(
        [if (level != FocusLevel.normal || !light) level.label, if (light) 'Go light'].join(', '),
        style: t.textTheme.bodyMedium?.copyWith(
          color: normal ? t.colorScheme.onSurfaceVariant : t.colorScheme.primary,
          fontWeight: normal ? null : FontWeight.w700,
        ),
      ),
      onTap: onTap,
    );
  }
}

/// The choices for one muscle; closing the sheet in any way keeps what was chosen.
class _MuscleSheet extends StatefulWidget {
  const _MuscleSheet({required this.info, required this.focus, required this.onChanged});

  final MuscleInfo info;
  final MuscleFocus focus;
  final ValueChanged<MuscleFocus> onChanged;

  @override
  State<_MuscleSheet> createState() => _MuscleSheetState();
}

class _MuscleSheetState extends State<_MuscleSheet> {
  late MuscleFocus _focus = widget.focus;

  void _choose(MuscleFocus focus) {
    setState(() => _focus = focus);
    widget.onChanged(focus);
  }

  static String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final id = widget.info.id;
    return SingleChildScrollView(
      padding: sheetPadding(context),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.info.label, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: Gap.sm),
          for (final l in FocusLevel.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _focus.levelOf(id) == l ? Icons.radio_button_checked : Icons.radio_button_off,
                color: _focus.levelOf(id) == l ? t.colorScheme.primary : null,
              ),
              title: Text(l.label),
              subtitle: Builder(builder: (context) {
                final target = _focus.withLevel(id, l).targetFor(id);
                return Text('${_n(target.min)}–${_n(target.max)} sets a week');
              }),
              selected: _focus.levelOf(id) == l,
              selectedColor: t.colorScheme.onSurface,
              onTap: () => _choose(_focus.withLevel(id, l)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Go light'),
            subtitle: const Text('10–15 reps, no heavy bar lifts'),
            value: _focus.isLight(id),
            onChanged: (v) => _choose(_focus.withLight(id, v)),
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ),
        ]),
    );
  }
}
