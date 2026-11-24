import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/session_tile.dart';

/// All finished workouts, by month.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(completedSessionsProvider);
    final sets = <String, int>{};
    for (final s in ref.watch(allLoggedSetsProvider).value ?? const []) {
      sets[s.sessionId] = (sets[s.sessionId] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Workouts')),
      body: AsyncView(
        value: sessions,
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.history,
              title: 'No workouts yet',
              message: 'Finished workouts appear here with all your sets.',
            );
          }
          final groups = <String, List<WorkoutSession>>{};
          for (final s in list) {
            groups.putIfAbsent(DateFormat('MMMM yyyy').format(s.startedAt.toLocal()), () => []).add(s);
          }
          return ListView(padding: pagePadding(context), children: [
            for (final (i, g) in groups.entries.indexed) ...[
              i == 0 ? SectionTitle(g.key, padding: SectionTitle.first) : SectionTitle(g.key),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [for (final s in g.value) SessionTile(session: s, sets: sets[s.id] ?? 0)]),
              ),
            ],
            const SizedBox(height: Gap.sm),
          ]);
        },
      ),
    );
  }
}
