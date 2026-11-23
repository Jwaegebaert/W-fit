import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/muscles.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../dashboard/dashboard_screen.dart';

/// Per muscle: Less / Normal / More (scales its weekly target band) and "Go light" (no heavy loading).
/// Changes are saved straight away and rebuild the open rule-engine plans.
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

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final focus = _focus ?? MuscleFocus.decode(profile.muscleFocusJson);
    final t = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Muscle focus'),
        actions: [
          if (!focus.isEmpty)
            TextButton(onPressed: _saving ? null : () => _set(MuscleFocus.none), child: const Text('Reset')),
        ],
        bottom: _saving
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: ListView(padding: pagePadding(context), children: [
        Card(
          color: t.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Less lowers a muscle\'s weekly target (no extra work for it), More raises it. Go light keeps that muscle '
              'away from heavy sets: 10–15 reps and machines or cables instead of barbell lifts. You can also ask the '
              'coach ("go easy on my shoulders") and save its suggestion.',
              style: TextStyle(color: t.colorScheme.onSecondaryContainer),
            ),
          ),
        ),
        for (final group in MuscleGroup.values) ...[
          SectionTitle(group.label),
          Card(
            child: Column(children: [
              for (final m in trackedMuscleInfo.where((m) => m.group == group))
                _MuscleRow(
                  info: m,
                  level: focus.levelOf(m.id),
                  light: focus.isLight(m.id),
                  target: focus.targetFor(m.id),
                  onLevel: (l) => _set(focus.withLevel(m.id, l)),
                  onLight: (v) => _set(focus.withLight(m.id, v)),
                ),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _MuscleRow extends StatelessWidget {
  const _MuscleRow({
    required this.info,
    required this.level,
    required this.light,
    required this.target,
    required this.onLevel,
    required this.onLight,
  });

  final MuscleInfo info;
  final FocusLevel level;
  final bool light;
  final MuscleTarget target;
  final ValueChanged<FocusLevel> onLevel;
  final ValueChanged<bool> onLight;

  static String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(info.label, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
          Text('${_n(target.min)}–${_n(target.max)} sets/wk', style: t.textTheme.bodySmall),
        ]),
        const SizedBox(height: Gap.xs),
        Row(children: [
          Expanded(
            child: SegmentedButton<FocusLevel>(
              segments: [
                for (final l in FocusLevel.values)
                  ButtonSegment(value: l, label: FittedBox(fit: BoxFit.scaleDown, child: Text(l.label))),
              ],
              selected: {level},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (s) => onLevel(s.first),
            ),
          ),
          const SizedBox(width: Gap.sm),
          FilterChip(
            label: const Text('Go light'),
            selected: light,
            onSelected: onLight,
            visualDensity: VisualDensity.compact,
          ),
        ]),
      ]),
    );
  }
}
