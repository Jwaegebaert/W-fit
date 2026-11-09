import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/api/api_client.dart';
import '../../domain/catalog.dart';
import '../../domain/muscles.dart';
import '../../providers.dart';
import '../../services/coach_service.dart';
import '../../widgets/common.dart';
import '../../widgets/report_issue_sheet.dart';

/// Active pain / discomfort entries with a Resolve action.
class _Limitations extends ConsumerWidget {
  const _Limitations();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = (ref.watch(activeFeedbackProvider).value ?? const [])
        .where((f) => f.kind == 'pain' || f.kind == 'discomfort')
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    final catalog = ref.watch(catalogProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Active limitations'),
      Card(
        child: Column(children: [
          for (final f in entries)
            ListTile(
              leading: const Icon(Icons.healing_outlined),
              title: Text(f.region != null ? prettyRegion(f.region!) : catalog.exerciseName(f.exerciseId ?? '')),
              subtitle: Text('${switch (f.severity) { 1 => 'Mild', 3 => 'Severe', _ => 'Moderate' }} ${f.kind} · '
                  'since ${DateFormat('d MMM').format(f.createdAt.toLocal())}'),
              trailing: TextButton(
                onPressed: () => ref.read(coachServiceProvider).resolveIssue(f.id),
                child: const Text('Resolve'),
              ),
            ),
        ]),
      ),
    ]);
  }
}

class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key});

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  Insights? _insights;
  String? _notice;
  bool _loading = false;
  Map<String, dynamic>? _usage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false, bool ai = true}) async {
    setState(() {
      _loading = true;
      _notice = null;
    });
    final coach = ref.read(coachServiceProvider);
    final configured = (await ref.read(apiConfigProvider.future)).isConfigured;
    Insights result;
    if (ai && configured) {
      try {
        result = await coach.aiInsights(force: force);
        if (mounted) ref.invalidate(cachedInsightsProvider);
      } on ApiException catch (e) {
        result = await coach.localInsights();
        _notice = '${e.message} Showing on-device insights.';
      }
      _usage = await coach.aiUsage();
    } else {
      result = await coach.localInsights();
      if (!configured) _notice = 'Connect your backend in Settings to unlock AI coaching.';
    }
    if (!mounted) return;
    setState(() {
      _insights = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final i = _insights;
    return Scaffold(
      appBar: AppBar(title: const Text('Coach'), actions: [
        IconButton(
          tooltip: 'Refresh insights',
          onPressed: _loading ? null : () => _load(force: true),
          icon: const Icon(Icons.refresh),
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(padding: pagePadding(context), children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Gap.radius),
              gradient: LinearGradient(colors: [t.colorScheme.primary, t.colorScheme.tertiary]),
            ),
            child: Row(children: [
              const Icon(Icons.auto_awesome, color: Colors.white, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Your training coach',
                      style: t.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(
                    i == null
                        ? 'Analysing your training…'
                        : i.source == 'ai'
                            ? 'AI insights${i.generatedAt != null ? ' · ${DateFormat('d MMM HH:mm').format(i.generatedAt!.toLocal())}' : ''}'
                            : 'On-device insights',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ]),
              ),
            ]),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_notice!, style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
            ),
          const SizedBox(height: Gap.item),
          FilledButton.tonalIcon(
            onPressed: () => showReportIssueSheet(context),
            icon: const Icon(Icons.report_problem_outlined),
            label: const Text('Report pain / tell your coach'),
          ),
          const _Limitations(),
          if (_loading && i == null)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
          if (_loading && i != null) const LinearProgressIndicator(),
          if (i != null) ...[
            const SectionTitle('Summary'),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(i.summary, style: t.textTheme.bodyLarge))),
            if (i.highlights.isNotEmpty) ...[
              const SectionTitle('Highlights'),
              Card(
                child: Column(children: [
                  for (final h in i.highlights)
                    ListTile(leading: Icon(Icons.trending_up, color: t.colorScheme.primary), title: Text(h)),
                ]),
              ),
            ],
            if (i.recommendations.isNotEmpty) ...[
              const SectionTitle('Recommendations'),
              Card(
                child: Column(children: [
                  for (final r in i.recommendations)
                    ListTile(leading: Icon(Icons.lightbulb_outline, color: Colors.amber.shade700), title: Text(r)),
                ]),
              ),
            ],
            if (i.nextFocus.isNotEmpty) ...[
              const SectionTitle('Next focus'),
              Card(
                color: t.colorScheme.primaryContainer,
                child: ListTile(
                  leading: Icon(Icons.flag_rounded, color: t.colorScheme.onPrimaryContainer),
                  title: Text(i.nextFocus,
                      style: TextStyle(color: t.colorScheme.onPrimaryContainer, fontWeight: FontWeight.w600)),
                  subtitle: i.focusMuscles.isEmpty
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: Gap.sm),
                          child: Wrap(spacing: 6, runSpacing: 6, children: [
                            for (final m in i.focusMuscles)
                              Pill(trackedMuscles[m]?.label ?? prettyMuscle(m), color: t.colorScheme.onPrimaryContainer),
                          ]),
                        ),
                ),
              ),
            ],
          ],
          const SectionTitle('Coach tools'),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.event_note),
                title: const Text('Plan / regenerate next workout'),
                subtitle: const Text('Open your next workout and use the menu to ask the AI coach'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => StatefulNavigationShell.maybeOf(context)?.goBranch(0),
              ),
              ListTile(
                leading: const Icon(Icons.fitness_center),
                title: const Text('Equipment in my gym'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/equipment'),
              ),
              ListTile(
                leading: const Icon(Icons.thumbs_up_down_outlined),
                title: const Text('Exercise preferences'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/library'),
              ),
            ]),
          ),
          if (_usage != null) ...[
            const SizedBox(height: 12),
            Text(
              'AI usage: ${_usage!['callsToday']}/${_usage!['dailyCallLimit']} calls today · '
              '${((_usage!['tokensThisMonth'] as num) / 1000).toStringAsFixed(0)}k of '
              '${((_usage!['monthlyTokenLimit'] as num) / 1000).toStringAsFixed(0)}k tokens this month',
              style: t.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ]),
      ),
    );
  }
}
