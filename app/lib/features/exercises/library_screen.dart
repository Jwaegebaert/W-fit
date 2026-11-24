import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/muscles.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/preference_sheet.dart';

/// Exercises A–Z with filters; long press to like or exclude one.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _query = '';
  String _category = 'strength';
  String? _muscle;
  bool _onlyAvailable = false;
  bool _onlyMine = false;

  static const _categories = {
    'strength': 'Strength',
    'power': 'Power',
    'core': 'Core',
    'warmup': 'Warm-up',
    'cooldown': 'Mobility',
  };

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final catalog = ref.watch(catalogProvider);
    final equipment = ref.watch(equipmentProvider).value ?? const {};
    final prefs = ref.watch(preferencesProvider).value ?? const {};
    bool available(Exercise e) => e.equipment.every((id) => equipment[id] ?? true);
    final q = _query.trim().toLowerCase();
    final list = catalog.exercises.where((e) {
      if (_onlyAvailable && !available(e)) return false;
      if (_onlyMine && (prefs[e.id] ?? 'neutral') == 'neutral') return false;
      if (_muscle != null && !e.primary.contains(_muscle)) return false;
      // Searching and "mine" look through everything.
      if (q.isEmpty) return _onlyMine || e.category == _category;
      return e.name.toLowerCase().contains(q) || e.primary.any((m) => prettyMuscle(m).toLowerCase().contains(q));
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return Scaffold(
      appBar: AppBar(title: const Text('Exercises')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search exercise or muscle'),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(
          height: Gap.tap,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            PopupMenuButton<String>(
              tooltip: 'Filter by muscle',
              onSelected: (v) => setState(() => _muscle = v.isEmpty ? null : v),
              itemBuilder: (_) => [
                const PopupMenuItem(value: '', child: Text('All muscles')),
                for (final m in trackedMuscleInfo) PopupMenuItem(value: m.id, child: Text(m.label)),
              ],
              child: IgnorePointer(
                child: FilterChip(
                  avatar: const Icon(Icons.arrow_drop_down_rounded),
                  showCheckmark: false,
                  label: Text(_muscle == null ? 'Muscle' : trackedMuscles[_muscle]!.label),
                  selected: _muscle != null,
                  onSelected: (_) {},
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('In my gym'),
              selected: _onlyAvailable,
              onSelected: (v) => setState(() => _onlyAvailable = v),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('Liked or excluded'),
              selected: _onlyMine,
              onSelected: (v) => setState(() => _onlyMine = v),
            ),
          ]),
        ),
        if (q.isEmpty && !_onlyMine)
          SizedBox(
            height: Gap.tap,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
              for (final c in _categories.entries) ...[
                ChoiceChip(
                  label: Text(c.value),
                  showCheckmark: false,
                  selected: _category == c.key,
                  onSelected: (_) => setState(() => _category = c.key),
                ),
                const SizedBox(width: 8),
              ],
            ]),
          ),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(icon: Icons.search_off, title: 'No exercises match')
              : ListView.builder(
                  padding: pagePadding(context, const EdgeInsets.only(top: Gap.xs, bottom: Gap.lg)),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final e = list[i];
                    return ListTile(
                      onTap: () => context.push('/exercise/${e.id}'),
                      onLongPress: () => showPreferenceSheet(context, e),
                      leading: ExerciseAvatar(exercise: e),
                      title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([
                        e.primary.map(prettyMuscle).join(', '),
                        if (!available(e)) 'not in your gym',
                      ].join(' · ')),
                      trailing: switch (prefs[e.id]) {
                        'liked' => Icon(Icons.thumb_up, size: 18, color: s.primary, semanticLabel: 'Liked'),
                        'disliked' => const Icon(Icons.thumb_down, size: 18, semanticLabel: 'Disliked'),
                        'banned' => Icon(Icons.block, size: 18, color: s.error, semanticLabel: 'Excluded'),
                        _ => null,
                      },
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
