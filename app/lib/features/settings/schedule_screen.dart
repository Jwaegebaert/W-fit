import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../providers.dart';
import '../../services/coach_service.dart';
import '../../widgets/common.dart';

/// Training days and what a session looks like. Every change is saved at once; plans that are already open follow a
/// moment later (or when the page is left), so trying out a setting does not rebuild them on every tap.
class ScheduleScreen extends ConsumerStatefulWidget {
  const ScheduleScreen({super.key});

  @override
  ConsumerState<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends ConsumerState<ScheduleScreen> {
  // Kept for dispose, where ref can no longer be used.
  late final CoachService _coach;
  late final SyncController _sync;

  /// Rest mode and cool-down the open plans were last adjusted to; null before anything was changed.
  (String, int)? _applied;
  Timer? _timer;
  double? _minutes;

  @override
  void initState() {
    super.initState();
    _coach = ref.read(coachServiceProvider);
    _sync = ref.read(syncControllerProvider.notifier);
  }

  @override
  void dispose() {
    _apply().then((_) => _sync.syncNow(onlyIfStale: true)).ignore();
    super.dispose();
  }

  Future<void> _save(ProfilesCompanion change) => ref.read(repositoryProvider).saveProfile(change);

  /// Saves a rest or cool-down setting and adjusts the open plans once the taps stop.
  Future<void> _savePrefs(Profile before, ProfilesCompanion change) async {
    _applied ??= (before.restMode, before.cooldownStretches);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), _apply);
    await _save(change);
  }

  Future<void> _apply() async {
    _timer?.cancel();
    final applied = _applied;
    if (applied == null) return;
    _applied = null;
    await _coach.applyTrainingPrefs(oldRestMode: applied.$1, oldCooldownStretches: applied.$2);
  }

  Future<void> _toggleDay(Set<int> days, int day) async {
    final next = days.contains(day) ? ({...days}..remove(day)) : {...days, day};
    if (next.isEmpty) {
      showSnack(context, 'Keep at least one training day.');
      return;
    }
    // First: other days can create new plans, which already have the new rest and cool-down.
    await _apply();
    await _save(ProfilesCompanion(trainingDays: Value((next.toList()..sort()).join(','))));
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final t = Theme.of(context);
    final note = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final days = parseDays(profile.trainingDays).toSet();
    final minutes = _minutes ?? profile.sessionMinutes.toDouble();
    const names = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const fullNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final backToBack = days.any((d) => days.contains(d % 7 + 1));

    return Scaffold(
      appBar: AppBar(title: const Text('Schedule & session')),
      body: ListView(padding: pagePadding(context), children: [
        const SectionTitle('Training days', padding: SectionTitle.first),
        Row(children: [
          for (var d = 1; d <= 7; d++)
            Expanded(
              child: _DayToggle(
                label: names[d - 1],
                tooltip: fullNames[d - 1],
                selected: days.contains(d),
                onTap: () => _toggleDay(days, d),
              ),
            ),
        ]),
        if (days.length != 3 || backToBack)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Text('The plan works best with 3 days and a rest day in between.', style: note),
          ),
        SectionTitle('Session length: ${minutes.round()} min'),
        Slider(
          value: minutes,
          min: 30,
          max: 90,
          divisions: 12,
          label: '${minutes.round()} min',
          onChanged: (v) => setState(() => _minutes = v),
          onChangeEnd: (v) => _save(ProfilesCompanion(sessionMinutes: Value(v.round()))),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Abs / core block'),
          value: profile.includeCore,
          onChanged: (v) => _save(ProfilesCompanion(includeCore: Value(v))),
        ),
        const SectionTitle('Rest between sets'),
        OptionBar<String>(
          options: const {'short': 'Short', 'normal': 'Normal', 'long': 'Long'},
          selected: profile.restMode,
          onSelected: (v) => _savePrefs(profile, ProfilesCompanion(restMode: Value(v))),
        ),
        const SizedBox(height: Gap.sm),
        Text(
          switch (profile.restMode) {
            'short' => 'About 30 % less. Heavy lifts may feel harder.',
            'long' => 'About 30 % more, for full recovery.',
            _ => '2–3 min on heavy lifts, 1–1.5 min on isolation work.',
          },
          style: note,
        ),
        const SectionTitle('Cool-down stretches'),
        OptionBar<int>(
          options: const {0: 'Off', 1: '1', 2: '2', 3: '3'},
          selected: profile.cooldownStretches.clamp(0, 3),
          onSelected: (v) => _savePrefs(profile, ProfilesCompanion(cooldownStretches: Value(v))),
        ),
        const SectionTitle('Experience'),
        OptionBar<String>(
          options: const {'beginner': 'Beginner', 'novice': 'Novice', 'intermediate': 'Intermediate'},
          selected: profile.experience,
          onSelected: (v) => _save(ProfilesCompanion(experience: Value(v))),
        ),
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
