import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/progression.dart';
import '../../domain/stats.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/sync_indicator.dart';
import '../workout/workout_actions.dart';

/// The next planned workout (generated with the rule engine when missing).
final nextPlanProvider = FutureProvider<PlannedWorkout>((ref) async {
  await ref.watch(completedSessionsProvider.future);
  // Re-plan when the profile (e.g. training days) changes.
  await ref.watch(profileProvider.future);
  final coach = ref.read(coachServiceProvider);
  final date = await coach.nextTrainingDate();
  return coach.ensurePlan(date);
});

final plannedStreamProvider = StreamProvider.family<PlannedWorkout?, String>(
  (ref, id) => ref.watch(repositoryProvider).watchPlanned(id),
);

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final active = ref.watch(activeSessionProvider).value;
    final greeting = _greeting();
    final name = (profile?.name.isNotEmpty ?? false) ? ', ${profile!.name}' : '';

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$greeting$name'),
          Text(DateFormat('EEEE d MMMM').format(DateTime.now()),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        actions: [
          const SyncIndicator(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(syncControllerProvider.notifier).syncNow();
          ref.invalidate(nextPlanProvider);
        },
        child: ListView(
          padding: Gap.page,
          children: [
            if (active != null) ...[_ResumeCard(session: active), const SizedBox(height: Gap.md)],
            const _NextWorkoutCard(),
            const SectionTitle('This week'),
            const _WeekCard(),
            const SectionTitle('Coming up'),
            const _UpcomingList(),
            const SectionTitle('Quick actions'),
            const _QuickActions(),
          ],
        ),
      ),
    );
  }

  static String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

class _ResumeCard extends StatelessWidget {
  const _ResumeCard({required this.session});

  final WorkoutSession session;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Card(
      color: s.tertiaryContainer,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(Icons.play_circle_fill_rounded, color: s.onTertiaryContainer, size: 36),
        title: Text('Workout in progress', style: TextStyle(color: s.onTertiaryContainer, fontWeight: FontWeight.w700)),
        subtitle: Text('${session.title} · started ${DateFormat.Hm().format(session.startedAt.toLocal())}',
            style: TextStyle(color: s.onTertiaryContainer)),
        trailing: Icon(Icons.chevron_right, color: s.onTertiaryContainer),
        onTap: () => context.push('/session/${session.id}'),
      ),
    );
  }
}

class _NextWorkoutCard extends ConsumerWidget {
  const _NextWorkoutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = ref.watch(nextPlanProvider);
    return next.when(
      loading: () => const Card(child: SizedBox(height: 220, child: Center(child: CircularProgressIndicator()))),
      error: (e, _) => Card(child: Padding(padding: const EdgeInsets.all(16), child: Text('Could not plan workout: $e'))),
      data: (initial) {
        final plan = ref.watch(plannedStreamProvider(initial.id)).value ?? initial;
        if (plan.deleted || plan.status != 'planned') {
          Future.microtask(() => ref.invalidate(nextPlanProvider));
        }
        return _HeroCard(plan: plan);
      },
    );
  }
}

class _HeroCard extends ConsumerWidget {
  const _HeroCard({required this.plan});

  final PlannedWorkout plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final day = DayType.parse(plan.dayType);
    final color = day.color(t.colorScheme);
    final date = parseDateKey(plan.date);
    final isToday = dateKey(date) == dateKey(DateTime.now());
    final blocks = Repository.decodeBlocks(plan.blocksJson);
    final main = blocks.where((b) => b.section == Section.main).expand((b) => b.items).toList();
    final catalog = ref.watch(catalogProvider);
    final active = ref.watch(activeSessionProvider).value;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Gap.radius + 4),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.35)!],
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Pill(isToday ? 'TODAY' : DateFormat('EEE d MMM').format(date).toUpperCase(),
              color: Colors.white, icon: Icons.event),
          const SizedBox(width: 8),
          Pill(plan.source == 'ai' ? 'AI coach' : 'Smart plan',
              color: Colors.white, icon: plan.source == 'ai' ? Icons.auto_awesome : Icons.rule),
          const Spacer(),
          Icon(day.icon, color: Colors.white70, size: 28),
        ]),
        const SizedBox(height: 16),
        Text(plan.title,
            style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(day.focus, style: t.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.timer_outlined, color: Colors.white70, size: 18),
          const SizedBox(width: 4),
          Text('~${plan.estimatedMinutes} min', style: const TextStyle(color: Colors.white)),
          const SizedBox(width: 16),
          const Icon(Icons.fitness_center, color: Colors.white70, size: 18),
          const SizedBox(width: 4),
          Text('${main.length} exercises', style: const TextStyle(color: Colors.white)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final i in main.take(5))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
              child: Text(catalog.exerciseName(i.exerciseId),
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: color),
              onPressed: active != null
                  ? () => context.push('/session/${active.id}')
                  : () => startWorkout(context, ref, plan),
              icon: Icon(active != null ? Icons.play_arrow : Icons.play_arrow_rounded),
              label: Text(active != null ? 'Resume' : 'Start workout'),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54)),
            onPressed: () => context.push('/plan/${plan.id}'),
            child: const Text('View plan'),
          ),
        ]),
      ]),
    );
  }
}

class _WeekCard extends ConsumerWidget {
  const _WeekCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final sessions = ref.watch(completedSessionsProvider).value ?? const [];
    final profile = ref.watch(profileProvider).value;
    final days = parseDays(profile?.trainingDays ?? '1,3,5');
    final monday = startOfWeek(DateTime.now());
    final trainedDates = sessions.map((s) => dateKey(s.startedAt.toLocal())).toSet();
    final thisWeek = sessions.where((s) => !s.startedAt.toLocal().isBefore(monday)).length;
    final sets = ref.watch(allLoggedSetsProvider).value ?? const [];
    final weeks = weeklyStats(sessions.map((s) => s.startedAt.toLocal()), sets, weeks: 12);
    final streak = weekStreak(weeks, days.length);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (var i = 0; i < 7; i++)
              _DayDot(
                date: addDays(monday, i),
                planned: days.contains(i + 1),
                done: trainedDates.contains(dateKey(addDays(monday, i))),
              ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$thisWeek / ${days.length} sessions',
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: days.isEmpty ? 0 : (thisWeek / days.length).clamp(0, 1).toDouble(),
                    minHeight: 8,
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 16),
            Column(children: [
              Row(children: [
                Icon(Icons.local_fire_department, color: Colors.orange.shade600),
                Text('$streak', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              ]),
              Text('week streak', style: t.textTheme.bodySmall),
            ]),
          ]),
        ]),
      ),
    );
  }
}

class _DayDot extends StatelessWidget {
  const _DayDot({required this.date, required this.planned, required this.done});

  final DateTime date;
  final bool planned;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final isToday = dateKey(date) == dateKey(DateTime.now());
    final bg = done ? s.primary : (planned ? s.primaryContainer : s.surfaceContainerHighest);
    final fg = done ? s.onPrimary : (planned ? s.onPrimaryContainer : s.onSurfaceVariant);
    return Column(children: [
      Text(DateFormat.E().format(date).substring(0, 2),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: isToday ? FontWeight.w800 : FontWeight.w500, color: isToday ? s.primary : null)),
      const SizedBox(height: 6),
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: isToday ? Border.all(color: s.primary, width: 2) : null,
        ),
        child: Center(
          child: done
              ? Icon(Icons.check, size: 18, color: fg)
              : Text('${date.day}', style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
        ),
      ),
    ]);
  }
}

class _UpcomingList extends ConsumerWidget {
  const _UpcomingList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = ref.watch(nextPlanProvider).value;
    final profile = ref.watch(profileProvider).value;
    if (next == null || profile == null) return const SizedBox.shrink();
    final start = addDays(parseDateKey(next.date), 1);
    final dates = upcomingTrainingDates(parseDays(profile.trainingDays), count: 3, from: start);
    final s = Theme.of(context).colorScheme;
    var day = DayType.parse(next.dayType);
    final entries = <(DateTime, DayType)>[];
    for (final d in dates) {
      day = day.next;
      entries.add((d, day));
    }
    return Card(
      child: Column(children: [
        for (final (d, dt) in entries)
          ListTile(
              leading: CircleAvatar(
                backgroundColor: dt.color(s).withValues(alpha: 0.15),
                child: Icon(dt.icon, color: dt.color(s)),
              ),
              title: Text('${dt.label} day', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(dt.focus),
              trailing: Text(DateFormat('EEE d MMM').format(d)),
            ),
      ]),
    );
  }
}

class _QuickActions extends ConsumerWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final body = ref.watch(bodyMetricsProvider).value ?? const [];
    final latest = body.where((b) => b.weightKg != null).firstOrNull;
    final sessions = ref.watch(completedSessionsProvider).value ?? const [];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 0.95,
      children: [
        _ActionTile(
          icon: Icons.monitor_weight_outlined,
          label: 'Body',
          value: latest == null ? 'Log weight' : '${formatKg(latest.weightKg)} kg',
          onTap: () => context.push('/body'),
        ),
        _ActionTile(
          icon: Icons.menu_book_outlined,
          label: 'Exercises',
          value: '${ref.watch(catalogProvider).exercises.length} moves',
          onTap: () => context.push('/library'),
        ),
        _ActionTile(
          icon: Icons.emoji_events_outlined,
          label: 'Workouts',
          value: '${sessions.length} done',
          onTap: () => StatefulNavigationShell.maybeOf(context)?.goBranch(1),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.value, required this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Icon(icon, color: t.colorScheme.primary),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(label, style: t.textTheme.bodySmall),
            ]),
          ]),
        ),
      ),
    );
  }
}
