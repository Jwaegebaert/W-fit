import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../data/db/database.dart';
import '../domain/catalog.dart';

/// One finished workout in a list; opens its details.
class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.session, required this.sets});

  final WorkoutSession session;
  final int sets;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final day = DayType.parse(session.dayType);
    final color = day.color(s);
    final seconds = session.durationSeconds;
    return ListTile(
      onTap: () => context.push('/history/${session.id}'),
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.15),
        child: Icon(day.icon, color: color),
      ),
      title: Text(session.title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text([
        DateFormat('EEE d MMM').format(session.startedAt.toLocal()),
        if (seconds != null && seconds >= 60) '${(seconds / 60).round()} min',
        sets == 0 ? 'no sets' : '$sets set${sets == 1 ? '' : 's'}',
      ].join(' · ')),
    );
  }
}
