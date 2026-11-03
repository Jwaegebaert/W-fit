import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../domain/catalog.dart';
import '../../providers.dart';
import '../../services/coach_service.dart';
import '../../widgets/common.dart';

enum SwapReason {
  occupied('occupied', 'Occupied', Icons.hourglass_top_rounded),
  unavailable('unavailable', 'Not in my gym', Icons.block_rounded),
  preference('preference', 'Prefer another', Icons.thumbs_up_down_rounded);

  const SwapReason(this.api, this.label, this.icon);
  final String api;
  final String label;
  final IconData icon;
}

/// Opens the swap sheet. Returns true when the plan was changed.
Future<bool> showSwapSheet(
  BuildContext context, {
  required String plannedId,
  required int blockIndex,
  required int itemIndex,
  required String exerciseId,
  required DayType day,
  required Section section,
  required Set<String> excludeIds,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => _SwapSheet(
        controller: controller,
        plannedId: plannedId,
        blockIndex: blockIndex,
        itemIndex: itemIndex,
        exerciseId: exerciseId,
        day: day,
        section: section,
        excludeIds: excludeIds,
      ),
    ),
  );
  return result ?? false;
}

class _SwapSheet extends ConsumerStatefulWidget {
  const _SwapSheet({
    required this.controller,
    required this.plannedId,
    required this.blockIndex,
    required this.itemIndex,
    required this.exerciseId,
    required this.day,
    required this.section,
    required this.excludeIds,
  });

  final ScrollController controller;
  final String plannedId;
  final int blockIndex;
  final int itemIndex;
  final String exerciseId;
  final DayType day;
  final Section section;
  final Set<String> excludeIds;

  @override
  ConsumerState<_SwapSheet> createState() => _SwapSheetState();
}

class _SwapSheetState extends ConsumerState<_SwapSheet> {
  SwapReason _reason = SwapReason.occupied;
  late Set<String> _selectedEquipment;
  bool _neverAgain = false;
  List<SwapSuggestion> _rules = const [];
  List<SwapSuggestion>? _ai;
  bool _aiLoading = false;
  String? _aiError;
  final _note = TextEditingController();

  Exercise get _original => ref.read(catalogProvider).exercise(widget.exerciseId)!;

  @override
  void initState() {
    super.initState();
    _selectedEquipment = _original.equipment.toSet();
    _refreshRules();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _refreshRules() async {
    final coach = ref.read(coachServiceProvider);
    final occupied = _reason == SwapReason.occupied ? _selectedEquipment : <String>{};
    final unavailable = _reason == SwapReason.unavailable ? _selectedEquipment : <String>{};
    final rules = await coach.ruleSwaps(
      widget.exerciseId,
      day: widget.day,
      exclude: widget.excludeIds,
      extraUnavailable: {...occupied, ...unavailable},
    );
    if (mounted) setState(() => _rules = rules);
  }

  Future<void> _askAi() async {
    setState(() {
      _aiLoading = true;
      _aiError = null;
    });
    // Apply the equipment context first so the server sees it.
    await _commitEquipmentContext();
    try {
      final ai = await ref.read(coachServiceProvider).aiSwaps(
            widget.exerciseId,
            day: widget.day,
            section: widget.section,
            reason: _reason.api,
            exclude: widget.excludeIds,
            note: _note.text,
          );
      if (mounted) setState(() => _ai = ai);
    } on ApiException catch (e) {
      if (mounted) setState(() => _aiError = e.message);
    } finally {
      if (mounted) setState(() => _aiLoading = false);
    }
  }

  Future<void> _commitEquipmentContext() async {
    final equipment = _selectedEquipment.where((e) => e != 'bodyweight');
    if (_reason == SwapReason.occupied) {
      ref.read(occupiedEquipmentProvider.notifier).add(equipment);
    } else if (_reason == SwapReason.unavailable) {
      await ref.read(coachServiceProvider).markUnavailable(equipment);
    }
  }

  Future<void> _apply(SwapSuggestion s) async {
    await _commitEquipmentContext();
    if (_reason == SwapReason.preference && _neverAgain) {
      await ref.read(repositoryProvider).setPreference(widget.exerciseId, 'banned');
    } else if (_reason == SwapReason.preference) {
      await ref.read(repositoryProvider).setPreference(widget.exerciseId, 'disliked');
    }
    await ref.read(coachServiceProvider).applySwap(widget.plannedId, widget.blockIndex, widget.itemIndex, s);
    if (!mounted) return;
    if (_reason == SwapReason.unavailable) {
      showSnack(context, 'Saved: future workouts will avoid that equipment.');
    }
    ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final catalog = ref.watch(catalogProvider);
    final original = _original;
    final aiConfigured = ref.watch(apiConfigProvider).value?.isConfigured ?? false;

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Text('Swap ${original.name}', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Targets ${original.primary.map(prettyMuscle).join(', ').toLowerCase()} · ${original.pattern.replaceAll('_', ' ')}',
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        SegmentedButton<SwapReason>(
          segments: [
            for (final r in SwapReason.values)
              ButtonSegment(value: r, label: Text(r.label, style: const TextStyle(fontSize: 12)), icon: Icon(r.icon, size: 18)),
          ],
          selected: {_reason},
          showSelectedIcon: false,
          onSelectionChanged: (s) {
            setState(() => _reason = s.first);
            _refreshRules();
          },
        ),
        const SizedBox(height: 12),
        if (_reason != SwapReason.preference && original.equipment.isNotEmpty) ...[
          Text(
            _reason == SwapReason.occupied
                ? 'Which equipment is busy? It will be avoided for the rest of this workout.'
                : 'Which equipment does your gym not have? It will be removed from future plans (you can undo in Settings).',
            style: t.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final id in original.equipment)
              FilterChip(
                label: Text(catalog.equipmentById(id)?.name ?? id),
                selected: _selectedEquipment.contains(id),
                onSelected: (v) {
                  setState(() => v ? _selectedEquipment.add(id) : _selectedEquipment.remove(id));
                  _refreshRules();
                },
              ),
          ]),
        ],
        if (_reason == SwapReason.preference)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _neverAgain,
            onChanged: (v) => setState(() => _neverAgain = v ?? false),
            title: const Text("Don't suggest this exercise again"),
            subtitle: const Text('Otherwise it is just marked as less preferred.'),
          ),
        const SizedBox(height: 8),
        if (aiConfigured) ...[
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              hintText: 'Optional note for the coach (e.g. "shoulder feels tight")',
              prefixIcon: Icon(Icons.edit_note),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _aiLoading ? null : _askAi,
            icon: _aiLoading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_aiLoading ? 'Asking the AI coach…' : 'Ask the AI coach'),
          ),
          if (_aiError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('$_aiError Showing smart suggestions instead.',
                  style: TextStyle(color: t.colorScheme.error)),
            ),
        ],
        if (_ai != null && _ai!.isNotEmpty) ...[
          const SectionTitle('AI coach suggestions'),
          for (final s in _ai!) _SuggestionTile(suggestion: s, onTap: () => _apply(s)),
        ],
        const SectionTitle('Equivalent exercises'),
        if (_rules.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No equivalent exercise fits your available equipment. Try another reason or equipment.'),
          ),
        for (final s in _rules) _SuggestionTile(suggestion: s, onTap: () => _apply(s)),
      ],
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({required this.suggestion, required this.onTap});

  final SwapSuggestion suggestion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: onTap,
          leading: ExerciseAvatar(exercise: suggestion.exercise),
          title: Row(children: [
            Expanded(child: Text(suggestion.exercise.name, style: const TextStyle(fontWeight: FontWeight.w600))),
            if (suggestion.fromAi) Icon(Icons.auto_awesome, size: 16, color: t.colorScheme.tertiary),
          ]),
          subtitle: Text(suggestion.why),
          trailing: const Icon(Icons.swap_horiz),
        ),
      ),
    );
  }
}
