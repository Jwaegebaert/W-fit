import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../data/db/database.dart';
import '../domain/muscles.dart';
import '../providers.dart';

bool isInjury(FeedbackEntry f) => f.kind == 'pain' || f.kind == 'discomfort';

/// Active pain / discomfort entries with a Resolved action; empty when there are none.
class ActiveInjuries extends ConsumerWidget {
  const ActiveInjuries({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = (ref.watch(activeFeedbackProvider).value ?? const <FeedbackEntry>[]).where(isInjury).toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    final catalog = ref.watch(catalogProvider);
    return Card(
      child: Column(children: [
        for (final f in entries)
          ListTile(
            leading: Icon(Icons.healing_outlined, color: Theme.of(context).colorScheme.attention),
            title: Text(f.region != null ? prettyRegion(f.region!) : catalog.exerciseName(f.exerciseId ?? '')),
            subtitle: Text('${switch (f.severity) { 1 => 'Mild', 3 => 'Severe', _ => 'Moderate' }} ${f.kind}, '
                'since ${DateFormat('d MMM').format(f.createdAt.toLocal())}'),
            trailing: TextButton(
              onPressed: () => ref.read(coachServiceProvider).resolveIssue(f.id),
              child: const Text('Resolved'),
            ),
          ),
      ]),
    );
  }
}
