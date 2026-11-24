import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/muscles.dart';
import '../../domain/stats.dart';
import '../../providers.dart';
import '../../widgets/brand.dart';
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

/// Today: the workout to start or resume, due check-ins and this week's days.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final active = ref.watch(activeSessionProvider).value;
    final name = (profile?.name.isNotEmpty ?? false) ? ', ${profile!.name}' : '';

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: AppBarTitle.toolbarHeight,
        leading: const Padding(padding: EdgeInsets.only(left: Gap.md), child: Center(child: BrandMark(size: 30))),
        leadingWidth: 56,
        titleSpacing: Gap.sm,
        title: AppBarTitle('${_greeting()}$name', subtitle: Text(DateFormat('EEEE d MMMM').format(DateTime.now()))),
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
          padding: pagePadding(context),
          children: [
            active != null ? _ResumeHero(session: active) : const _NextWorkoutCard(),
            const _CheckInCards(),
            const SectionTitle('This week'),
            const _WeekCard(),
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

class _NextWorkoutCard extends ConsumerWidget {
  const _NextWorkoutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = ref.watch(nextPlanProvider);
    return next.when(
      loading: () => const Card(child: SizedBox(height: 180, child: Center(child: CircularProgressIndicator()))),
      error: (e, _) => Card(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: const Text('Could not plan your next workout'),
          trailing: TextButton(onPressed: () => ref.invalidate(nextPlanProvider), child: const Text('Try again')),
        ),
      ),
      data: (initial) {
        final plan = ref.watch(plannedStreamProvider(initial.id)).value ?? initial;
        if (plan.deleted || plan.status != 'planned') {
          Future.microtask(() => ref.invalidate(nextPlanProvider));
        }
        return _PlanHero(plan: plan);
      },
    );
  }
}

/// The workout that is running: one tap back into it.
class _ResumeHero extends StatelessWidget {
  const _ResumeHero({required this.session});

  final WorkoutSession session;

  @override
  Widget build(BuildContext context) {
    void resume() => context.push('/session/${session.id}');
    return _Hero(
      label: 'Workout in progress',
      title: session.title,
      detail: 'Started ${DateFormat.Hm().format(session.startedAt.toLocal())}',
      onTap: resume,
      actions: [_HeroStart(label: 'Resume', onPressed: resume)],
    );
  }
}

class _PlanHero extends ConsumerWidget {
  const _PlanHero({required this.plan});

  final PlannedWorkout plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = dateKey(DateTime.now());
    final isToday = plan.date == today;
    final trainedToday =
        (ref.watch(completedSessionsProvider).value ?? const []).any((s) => dateKey(s.startedAt.toLocal()) == today);
    final when = DateFormat('EEE d MMM').format(parseDateKey(plan.date));
    final exercises = Repository.decodeBlocks(plan.blocksJson)
        .where((b) => b.section == Section.main)
        .fold<int>(0, (n, b) => n + b.items.length);
    void open() => context.push('/plan/${plan.id}');
    return _Hero(
      label: isToday
          ? 'Today'
          : trainedToday
              ? 'Done for today · next $when'
              : 'Rest day · next $when',
      coach: plan.source == 'ai',
      title: plan.title,
      detail: '~${plan.estimatedMinutes} min · $exercises exercises',
      onTap: open,
      actions: [
        _HeroStart(label: isToday ? 'Start workout' : 'Start early', onPressed: () => startWorkout(context, ref, plan)),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54), minimumSize: const Size(48, 52)),
          onPressed: open,
          child: const Text('View plan', maxLines: 1),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.label,
    required this.title,
    required this.detail,
    required this.onTap,
    required this.actions,
    this.coach = false,
  });

  final String label;
  final String title;
  final String detail;

  /// Written or refined by the AI coach.
  final bool coach;
  final VoidCallback onTap;

  /// The main button first; the optional second one gets its natural width next to it.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      borderRadius: BorderRadius.circular(Gap.radius + 4),
      clipBehavior: Clip.antiAlias,
      color: BrandColors.hero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(label,
                    style: t.textTheme.labelLarge?.copyWith(color: Colors.white70, fontWeight: FontWeight.w600)),
              ),
              if (coach) const Icon(Icons.auto_awesome, size: 20, color: Colors.white70, semanticLabel: 'From your coach'),
            ]),
            const SizedBox(height: Gap.sm),
            // Capped so Start stays above the fold on small phones; the plan shows the full title.
            Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: Gap.xs),
            Text(detail, style: t.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
            const SizedBox(height: Gap.md + 2),
            LayoutBuilder(builder: (context, c) {
              if (actions.length == 1) return SizedBox(width: double.infinity, child: actions.single);
              // Side by side when both labels fit on one line, otherwise stacked (narrow phones, large text).
              if (_labelWidth(context, 'Start workout') + _labelWidth(context, 'View plan') + 130 <= c.maxWidth) {
                return Row(children: [Expanded(child: actions.first), const SizedBox(width: Gap.item), actions.last]);
              }
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [actions.first, const SizedBox(height: Gap.sm), actions.last]);
            }),
          ]),
        ),
      ),
    );
  }

  static double _labelWidth(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(
          text: text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

class _HeroStart extends StatelessWidget {
  const _HeroStart({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        key: const ValueKey('start-workout'),
        style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: BrandColors.hero),
        onPressed: onPressed,
        icon: const Icon(Icons.play_arrow_rounded),
        label: Text(label, maxLines: 1),
      );
}

/// "Shoulder: still bothering you?" for pain and discomfort whose check-in date has come.
class _CheckInCards extends ConsumerWidget {
  const _CheckInCards();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final due = ref.watch(dueCheckInsProvider).value ?? const <FeedbackEntry>[];
    if (due.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final s = t.colorScheme;
    final catalog = ref.watch(catalogProvider);
    final coach = ref.read(coachServiceProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final f in due.take(2))
        Card(
          margin: const EdgeInsets.only(top: Gap.item),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 12, Gap.sm, Gap.xs),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.healing_outlined, size: 20, color: s.attention),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(
                      text: f.region != null ? prettyRegion(f.region!) : catalog.exerciseName(f.exerciseId ?? ''),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                        text: ': still bothering you? (since ${DateFormat('d MMM').format(f.createdAt.toLocal())})'),
                  ])),
                ),
              ]),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(children: [
                  TextButton(onPressed: () => coach.keepIssue(f.id), child: const Text('Still hurts')),
                  TextButton(onPressed: () => coach.resolveIssue(f.id), child: const Text('Resolved')),
                ]),
              ),
            ]),
          ),
        ),
    ]);
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (var i = 0; i < 7; i++)
              _DayDot(
                date: addDays(monday, i),
                planned: days.contains(i + 1),
                done: trainedDates.contains(dateKey(addDays(monday, i))),
              ),
          ]),
          const SizedBox(height: 12),
          Text('$thisWeek of ${days.length} workouts done',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
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
    return Semantics(
      label: '${DateFormat('EEEE d').format(date)}${done ? ', trained' : planned ? ', planned' : ''}',
      excludeSemantics: true,
      child: Column(children: [
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
      ]),
    );
  }
}
