import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../dashboard/dashboard_screen.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _name = TextEditingController();
  final _goals = TextEditingController();
  final _injuries = TextEditingController();
  final _height = TextEditingController();
  final _birthYear = TextEditingController();
  Set<int> _days = {1, 3, 5};
  double _minutes = 60;
  bool _core = true;
  String _experience = 'beginner';
  String _restMode = 'normal';
  int _cooldown = 3;
  bool _loaded = false;

  void _load(Profile p) {
    if (_loaded) return;
    _loaded = true;
    _name.text = p.name;
    _goals.text = p.goals;
    _injuries.text = p.injuries;
    _height.text = p.heightCm?.toStringAsFixed(0) ?? '';
    _birthYear.text = p.birthYear?.toString() ?? '';
    _days = parseDays(p.trainingDays).toSet();
    _minutes = p.sessionMinutes.toDouble();
    _core = p.includeCore;
    _experience = p.experience;
    _restMode = p.restMode;
    _cooldown = p.cooldownStretches.clamp(0, 3);
  }

  @override
  void dispose() {
    for (final c in [_name, _goals, _injuries, _height, _birthYear]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_days.isEmpty) {
      showSnack(context, 'Pick at least one training day.');
      return;
    }
    final before = await ref.read(repositoryProvider).getProfile();
    await ref.read(repositoryProvider).saveProfile(ProfilesCompanion(
          name: Value(_name.text.trim()),
          goals: Value(_goals.text.trim()),
          injuries: Value(_injuries.text.trim()),
          heightCm: Value(double.tryParse(_height.text.replaceAll(',', '.'))),
          birthYear: Value(int.tryParse(_birthYear.text)),
          trainingDays: Value((_days.toList()..sort()).join(',')),
          sessionMinutes: Value(_minutes.round()),
          includeCore: Value(_core),
          experience: Value(_experience),
          restMode: Value(_restMode),
          cooldownStretches: Value(_cooldown),
        ));
    await ref
        .read(coachServiceProvider)
        .applyTrainingPrefs(oldRestMode: before.restMode, oldCooldownStretches: before.cooldownStretches);
    ref.invalidate(nextPlanProvider);
    ref.read(syncControllerProvider.notifier).syncNow();
    if (mounted) {
      showSnack(context, 'Profile saved');
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    _load(profile);
    const names = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const fullNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

    return Scaffold(
      appBar: AppBar(title: const Text('Profile & schedule'), actions: [
        TextButton(onPressed: _save, child: const Text('Save')),
      ]),
      body: ListView(padding: pagePadding(context), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        const SectionTitle('Training days'),
        Row(children: [
          for (var d = 1; d <= 7; d++)
            Expanded(
              child: _DayToggle(
                label: names[d - 1],
                tooltip: fullNames[d - 1],
                selected: _days.contains(d),
                onTap: () => setState(() => _days.contains(d) ? _days.remove(d) : _days.add(d)),
              ),
            ),
        ]),
        const SizedBox(height: Gap.sm),
        Text('Recommended: 3 non-consecutive days (Push → Pull → Legs rotation).',
            style: Theme.of(context).textTheme.bodySmall),
        SectionTitle('Session length: ${_minutes.round()} min'),
        Slider(value: _minutes, min: 30, max: 90, divisions: 12, label: '${_minutes.round()} min',
            onChanged: (v) => setState(() => _minutes = v)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include abs / core block'),
          value: _core,
          onChanged: (v) => setState(() => _core = v),
        ),
        const SectionTitle('Rest between sets'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'short', label: FittedBox(fit: BoxFit.scaleDown, child: Text('Short'))),
            ButtonSegment(value: 'normal', label: FittedBox(fit: BoxFit.scaleDown, child: Text('Normal'))),
            ButtonSegment(value: 'long', label: FittedBox(fit: BoxFit.scaleDown, child: Text('Long'))),
          ],
          selected: {_restMode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _restMode = s.first),
        ),
        const SizedBox(height: Gap.sm),
        Text(
          switch (_restMode) {
            'short' => 'About 30 % less rest. Sessions get shorter or fit more work; heavy lifts may feel harder.',
            'long' => 'About 30 % more rest for full recovery between heavy sets.',
            _ => 'Rest as programmed: 2–3 min on heavy lifts, 1–1.5 min on isolation work.',
          },
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SectionTitle('Cool-down stretches'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: FittedBox(fit: BoxFit.scaleDown, child: Text('Off'))),
            ButtonSegment(value: 1, label: Text('1')),
            ButtonSegment(value: 2, label: Text('2')),
            ButtonSegment(value: 3, label: Text('3')),
          ],
          selected: {_cooldown},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _cooldown = s.first),
        ),
        const SectionTitle('Experience'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'beginner', label: FittedBox(fit: BoxFit.scaleDown, child: Text('Beginner'))),
            ButtonSegment(value: 'novice', label: FittedBox(fit: BoxFit.scaleDown, child: Text('Novice'))),
            ButtonSegment(value: 'intermediate', label: FittedBox(fit: BoxFit.scaleDown, child: Text('Intermediate'))),
          ],
          selected: {_experience},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _experience = s.first),
        ),
        const SectionTitle('About you'),
        TextField(controller: _goals, maxLines: 2, decoration: const InputDecoration(labelText: 'Goals')),
        const SizedBox(height: 12),
        TextField(
          controller: _injuries,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Injuries / limitations (used by the AI coach)'),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _height,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Height (cm)'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _birthYear,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Birth year'),
            ),
          ),
        ]),
        const SizedBox(height: 24),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ]),
    );
  }
}

/// Round weekday toggle; seven of them always fit one row, even on narrow phones with large text.
/// The whole cell (≥ 46 × 48 dp) is tappable.
class _DayToggle extends StatelessWidget {
  const _DayToggle({required this.label, required this.tooltip, required this.selected, required this.onTap});

  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        child: InkResponse(
          onTap: onTap,
          radius: Gap.tap / 2,
          child: SizedBox(
            height: Gap.tap,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: selected ? s.primary : s.surfaceContainerHighest),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label,
                      style: TextStyle(fontWeight: FontWeight.w700, color: selected ? s.onPrimary : s.onSurfaceVariant)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}