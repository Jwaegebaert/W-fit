import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../domain/catalog.dart';
import '../../domain/muscles.dart';
import '../../domain/training_load.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

/// Status colours shared by the balance views: under target amber, on target primary, above target purple.
Color volumeColor(VolumeStatus status, ColorScheme s) => switch (status) {
      VolumeStatus.under => Colors.amber.shade700,
      VolumeStatus.ok => s.primary,
      VolumeStatus.high => Colors.deepPurple.shade300,
    };

/// Colour of [sets] effective sets against [target] (empty-cell colour when nothing was logged).
Color bandColor(double sets, MuscleTarget target, ColorScheme s) => sets <= 0
    ? s.surfaceContainerHighest
    : volumeColor(
        sets < target.min ? VolumeStatus.under : (sets > target.max ? VolumeStatus.high : VolumeStatus.ok), s);

Color _groupColor(MuscleGroup g, ColorScheme s) => switch (g) {
      MuscleGroup.push => DayType.push.color(s),
      MuscleGroup.pull => DayType.pull.color(s),
      MuscleGroup.legs => DayType.legs.color(s),
      MuscleGroup.core => Section.core.color(s),
    };

String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

const _labelWidth = 92.0;

class BalanceScreen extends ConsumerWidget {
  const BalanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coachFocus = ref.watch(cachedInsightsProvider).value?.focusMuscles ?? const <String>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Muscle balance')),
      body: AsyncView(
        value: ref.watch(coachSnapshotProvider),
        builder: (snap) {
          if (snap.sessions.isEmpty) {
            return const EmptyState(
              icon: Icons.accessibility_new,
              title: 'No training data yet',
              message: 'Finish a workout to see how your weekly volume is spread across your muscles.',
            );
          }
          final b = snap.balance;
          return ListView(padding: pagePadding(context), children: [
            const SectionTitle('Next focus', padding: EdgeInsets.fromLTRB(4, 8, 4, 8)),
            _FocusCard(balance: b, coachFocus: coachFocus),
            SectionTitle('This week', trailing: Text('sets · target', style: Theme.of(context).textTheme.bodySmall)),
            _WeekCard(balance: b),
            const SectionTitle('8-week balance'),
            _Heatmap(weeks: snap.weeks, focus: MuscleFocus.decode(snap.profile.muscleFocusJson)),
            const SectionTitle('Distribution'),
            _DistributionCard(balance: b),
            const SectionTitle('Recently trained'),
            _RecentCard(balance: b),
          ]);
        },
      ),
    );
  }
}

class _FocusCard extends StatelessWidget {
  const _FocusCard({required this.balance, required this.coachFocus});

  final BalanceReport balance;
  final List<String> coachFocus;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (balance.priorities.isEmpty)
            const Padding(padding: EdgeInsets.only(bottom: Gap.sm), child: Text('Every muscle is on track this week.')),
          for (final p in balance.priorities.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.flag_rounded, size: 20, color: Colors.amber.shade700),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(p.reason, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ]),
            ),
          if (coachFocus.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 6, children: [
              Pill('Coach', icon: Icons.auto_awesome, color: t.colorScheme.tertiary),
              for (final m in coachFocus) Pill(trackedMuscles[m]?.label ?? prettyMuscle(m)),
            ]),
        ]),
      ),
    );
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.balance});

  final BalanceReport balance;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final g in MuscleGroup.values) ...[
            Padding(
              padding: EdgeInsets.only(top: g == MuscleGroup.values.first ? 0 : Gap.item, bottom: Gap.xs),
              child: Text(g.label,
                  style: t.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700, color: t.colorScheme.onSurfaceVariant)),
            ),
            for (final m in balance.muscles.where((m) => m.info.group == g)) _VolumeBar(status: m),
          ],
        ]),
      ),
    );
  }
}

/// Slim bar: shaded target band (min–max) and the current effective sets in the status colour.
class _VolumeBar extends StatelessWidget {
  const _VolumeBar({required this.status});

  final MuscleStatus status;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final m = status;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: _labelWidth,
          child: Text(m.label, style: t.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: SizedBox(
            height: 12,
            child: LayoutBuilder(builder: (context, c) {
              final scale = math.max(m.targetMax * 1.25, m.thisWeek);
              double x(double v) => c.maxWidth * (v / scale).clamp(0.0, 1.0);
              return Stack(children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: s.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
                  ),
                ),
                Positioned(
                  left: x(m.targetMin),
                  width: x(m.targetMax) - x(m.targetMin),
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: s.primary.withValues(alpha: 0.18)),
                ),
                Positioned(
                  left: 0,
                  width: x(m.thisWeek),
                  top: 3,
                  bottom: 3,
                  child: DecoratedBox(
                    decoration:
                        BoxDecoration(color: volumeColor(m.status, s), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
              ]);
            }),
          ),
        ),
        const SizedBox(width: Gap.sm),
        SizedBox(
          width: 76,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text('${_n(m.thisWeek)} · ${_n(m.targetMin)}–${_n(m.targetMax)}', style: t.textTheme.bodySmall),
          ),
        ),
      ]),
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.weeks, this.focus = MuscleFocus.none});

  /// The athlete's muscle focus: cells are coloured against the adjusted band.
  final MuscleFocus focus;

  final List<MuscleWeek> weeks;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final tiny = t.textTheme.labelSmall?.copyWith(color: s.onSurfaceVariant);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const SizedBox(width: _labelWidth),
            for (final w in weeks)
              Expanded(
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(DateFormat('d/M').format(w.weekStart), style: tiny)),
              ),
          ]),
          const SizedBox(height: Gap.xs),
          for (final info in trackedMuscleInfo)
            Row(children: [
              SizedBox(
                width: _labelWidth,
                child: Text(info.label, style: t.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              for (final w in weeks)
                Expanded(
                  child: Container(
                    height: 14,
                    margin: const EdgeInsets.all(1.5),
                    decoration: BoxDecoration(
                        color: bandColor(w.of(info.id), focus.targetFor(info.id), s), borderRadius: BorderRadius.circular(3)),
                  ),
                ),
            ]),
          const SizedBox(height: Gap.item),
          Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
            _Legend('Under target', volumeColor(VolumeStatus.under, s)),
            _Legend('On target', volumeColor(VolumeStatus.ok, s)),
            _Legend('Above', volumeColor(VolumeStatus.high, s)),
            _Legend('None', s.surfaceContainerHighest),
          ]),
        ]),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: Gap.xs),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _DistributionCard extends StatelessWidget {
  const _DistributionCard({required this.balance});

  final BalanceReport balance;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final share = balance.groupShare;
    String ratio(double? v) => v == null ? '–' : v.toStringAsFixed(2);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (share.isEmpty)
            const Text('No volume logged in the last 4 weeks.')
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 14,
                child: Row(children: [
                  for (final g in MuscleGroup.values)
                    if ((share[g] ?? 0) > 0)
                      Expanded(flex: (share[g]! * 1000).round(), child: ColoredBox(color: _groupColor(g, s))),
                ]),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.md, runSpacing: Gap.xs, children: [
              for (final g in MuscleGroup.values)
                _Legend('${g.label} ${((share[g] ?? 0) * 100).round()} %', _groupColor(g, s)),
            ]),
          ],
          const SizedBox(height: Gap.item),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            Pill('Push : Pull ${ratio(balance.pushPullRatio)}', icon: Icons.compare_arrows),
            Pill('Quads : Hams ${ratio(balance.quadHamRatio)}', icon: Icons.compare_arrows),
          ]),
        ]),
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.balance});

  final BalanceReport balance;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final muscles = [...balance.muscles]
      ..sort((a, b) => (a.daysSinceTrained ?? 999).compareTo(b.daysSinceTrained ?? 999));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.item),
        child: Wrap(spacing: 6, runSpacing: 6, children: [
          for (final m in muscles)
            Pill(
              '${m.label} · ${switch (m.daysSinceTrained) { null => '–', 0 => 'today', final d => '${d}d' }}',
              color: switch (m.daysSinceTrained) {
                null => s.onSurfaceVariant,
                final d when d > 7 => Colors.amber.shade800,
                _ => s.primary,
              },
            ),
        ]),
      ),
    );
  }
}

/// Compact balance summary (this week's heat strip + under-trained muscles) linking to the balance screen.
class BalanceSummaryCard extends ConsumerWidget {
  const BalanceSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(coachSnapshotProvider).value;
    if (snap == null || snap.sessions.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final s = t.colorScheme;
    final under = snap.balance.muscles.where((m) => m.status == VolumeStatus.under).toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/balance'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.accessibility_new, color: s.primary),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text('Muscle balance', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
              const Icon(Icons.chevron_right),
            ]),
            const SizedBox(height: Gap.item),
            Row(children: [
              for (final m in snap.balance.muscles)
                Expanded(
                  child: Container(
                    height: 10,
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                        color: bandColor(m.thisWeek, MuscleTarget(m.targetMin, m.targetMax), s), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
            ]),
            const SizedBox(height: Gap.item),
            if (under.isEmpty)
              Text('All muscles on track', style: t.textTheme.bodySmall)
            else
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final m in under.take(5)) Pill(m.label, color: Colors.amber.shade800),
                if (under.length > 5) Pill('+${under.length - 5}', color: s.onSurfaceVariant),
              ]),
          ]),
        ),
      ),
    );
  }
}
