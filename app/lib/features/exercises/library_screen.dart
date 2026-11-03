import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/catalog.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _query = '';
  String? _category;
  bool _onlyAvailable = false;

  static const _categories = {
    'strength': 'Strength',
    'power': 'Power',
    'core': 'Core',
    'warmup': 'Warm-up',
    'cooldown': 'Mobility',
  };

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(catalogProvider);
    final equipment = ref.watch(equipmentProvider).value ?? const {};
    final prefs = ref.watch(preferencesProvider).value ?? const {};
    bool available(Exercise e) => e.equipment.every((id) => equipment[id] ?? true);
    final q = _query.toLowerCase();
    final list = catalog.exercises.where((e) {
      if (_category != null && e.category != _category) return false;
      if (_onlyAvailable && !available(e)) return false;
      if (q.isEmpty) return true;
      return e.name.toLowerCase().contains(q) ||
          e.primary.any((m) => prettyMuscle(m).toLowerCase().contains(q)) ||
          (q.contains('badminton') && e.badminton != null);
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Exercise library')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search exercise, muscle or "badminton"'),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            FilterChip(
              label: const Text('Available'),
              selected: _onlyAvailable,
              onSelected: (v) => setState(() => _onlyAvailable = v),
            ),
            const SizedBox(width: 8),
            for (final c in _categories.entries) ...[
              ChoiceChip(
                label: Text(c.value),
                selected: _category == c.key,
                onSelected: (v) => setState(() => _category = v ? c.key : null),
              ),
              const SizedBox(width: 8),
            ],
          ]),
        ),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(icon: Icons.search_off, title: 'No exercises match')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final e = list[i];
                    final pref = prefs[e.id];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        onTap: () => context.push('/exercise/${e.id}'),
                        leading: ExerciseAvatar(exercise: e),
                        title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(e.primary.map(prettyMuscle).join(', ')),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (e.badminton != null) const Icon(Icons.sports_tennis, size: 18),
                          if (pref == 'liked') const Icon(Icons.thumb_up, size: 18),
                          if (pref == 'banned' || pref == 'disliked') const Icon(Icons.thumb_down, size: 18),
                          if (!available(e)) Icon(Icons.block, size: 18, color: Theme.of(context).colorScheme.error),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
