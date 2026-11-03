import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(completedSessionsProvider);
    final sets = ref.watch(allLoggedSetsProvider).value ?? const [];
    final bySession = <String, (int, double)>{};
    for (final s in sets) {
      final cur = bySession[s.sessionId] ?? (0, 0.0);
      bySession[s.sessionId] = (cur.$1 + 1, cur.$2 + s.volume);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
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
          final groups = <String, List<dynamic>>{};
          for (final s in list) {
            groups.putIfAbsent(DateFormat('MMMM yyyy').format(s.startedAt.toLocal()), () => []).add(s);
          }
          return ListView(padding: Gap.page, children: [
            for (final g in groups.entries) ...[
              SectionTitle(g.key),
              for (final s in g.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      onTap: () => context.push('/history/${s.id}'),
                      leading: CircleAvatar(
                        backgroundColor: DayType.parse(s.dayType).color(Theme.of(context).colorScheme).withValues(alpha: 0.15),
                        child: Icon(DayType.parse(s.dayType).icon, color: DayType.parse(s.dayType).color(Theme.of(context).colorScheme)),
                      ),
                      title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${DateFormat('EEE d MMM · HH:mm').format(s.startedAt.toLocal())}'
                        '${s.durationSeconds != null ? ' · ${(s.durationSeconds! / 60).round()} min' : ''}\n'
                        '${bySession[s.id]?.$1 ?? 0} sets · ${formatKg(bySession[s.id]?.$2 ?? 0)} kg',
                      ),
                      isThreeLine: true,
                      trailing: s.rating == null
                          ? null
                          : Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.star_rounded, color: Colors.amber.shade600, size: 18),
                              Text('${s.rating}'),
                            ]),
                    ),
                  ),
                ),
            ],
          ]);
        },
      ),
    );
  }
}

String formatDuration(int? seconds) => seconds == null ? '–' : formatClock(seconds);
