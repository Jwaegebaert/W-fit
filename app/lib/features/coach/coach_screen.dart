import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/api/api_client.dart';
import '../../domain/catalog.dart';
import '../../domain/muscles.dart';
import '../../providers.dart';
import '../../services/coach_service.dart';
import '../../widgets/active_injuries.dart';
import '../../widgets/common.dart';
import '../../widgets/report_issue_sheet.dart';

/// What to do next, two ways to talk to the coach, active injuries; the longer review is folded.
class CoachScreen extends ConsumerStatefulWidget {
  const CoachScreen({super.key});

  @override
  ConsumerState<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends ConsumerState<CoachScreen> {
  Insights? _insights;
  String? _notice;
  bool _loading = false;

  // Both buttons fit next to each other on a normal phone.
  static final _compact = FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Gap.sm));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _notice = null;
    });
    final coach = ref.read(coachServiceProvider);
    final configured = (await ref.read(apiConfigProvider.future)).isConfigured;
    Insights result;
    if (configured) {
      try {
        result = await coach.aiInsights(force: force);
        if (mounted) ref.invalidate(cachedInsightsProvider);
      } on ApiException catch (e) {
        result = await coach.localInsights();
        _notice = '${e.message} Showing advice from this phone.';
      }
    } else {
      result = await coach.localInsights();
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
    final s = t.colorScheme;
    final i = _insights;
    final injuries = (ref.watch(activeFeedbackProvider).value ?? const []).any(isInjury);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Coach'),
        actions: [
          IconButton(
            tooltip: 'Refresh advice',
            onPressed: _loading ? null : () => _load(force: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _loading && i != null
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(padding: pagePadding(context), children: [
          const SectionTitle('Do next', padding: SectionTitle.first),
          if (i == null)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else
            Card(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (i.nextFocus.isNotEmpty)
                  ListTile(
                    leading: Icon(Icons.flag_rounded, color: i.source == 'ai' ? s.gold : s.primary),
                    title: Text(i.nextFocus, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: i.focusMuscles.isEmpty
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(spacing: 6, runSpacing: 6, children: [
                              for (final m in i.focusMuscles)
                                Pill(trackedMuscles[m]?.label ?? prettyMuscle(m), color: s.primary),
                            ]),
                          ),
                  ),
                for (final r in i.recommendations)
                  ListTile(leading: Icon(Icons.arrow_right_rounded, color: s.onSurfaceVariant), title: Text(r)),
              ]),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.sm),
              child: Text(_notice!, style: t.textTheme.bodySmall?.copyWith(color: s.onSurfaceVariant)),
            ),
          const SizedBox(height: Gap.md),
          _Actions(children: [
            FilledButton.tonalIcon(
              style: _compact,
              onPressed: () => showReportPain(context),
              icon: const Icon(Icons.healing_outlined),
              label: const Text('Report pain', maxLines: 1),
            ),
            FilledButton.tonalIcon(
              style: _compact,
              onPressed: () => showTellCoach(context),
              icon: const Icon(Icons.edit_note),
              label: const Text('Tell your coach', maxLines: 1),
            ),
          ]),
          if (injuries) ...[
            const SectionTitle('Active injuries'),
            const ActiveInjuries(),
          ],
          if (i != null && (i.summary.isNotEmpty || i.highlights.isNotEmpty)) ...[
            const SizedBox(height: Gap.md),
            Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                shape: const Border(),
                title: const Text('Review', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(i.source == 'ai'
                    ? 'From your coach${i.generatedAt == null ? '' : ', ${DateFormat('d MMM HH:mm').format(i.generatedAt!.toLocal())}'}'
                    : 'From this phone'),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                childrenPadding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
                children: [
                  Text(i.summary),
                  for (final h in i.highlights)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.sm),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.trending_up, size: 20, color: s.primary),
                        const SizedBox(width: Gap.sm),
                        Expanded(child: Text(h)),
                      ]),
                    ),
                ],
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Two buttons side by side when they fit, otherwise stacked.
class _Actions extends StatelessWidget {
  const _Actions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => c.maxWidth / MediaQuery.textScalerOf(context).scale(1) >= 345
            ? Row(spacing: Gap.item, children: [for (final w in children) Expanded(child: w)])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Gap.sm, children: children),
      );
}
