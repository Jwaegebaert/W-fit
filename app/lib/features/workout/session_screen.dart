import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/catalog.dart';
import '../../domain/plan.dart';
import '../../domain/progression.dart';
import '../../domain/stats.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../dashboard/dashboard_screen.dart';
import 'swap_sheet.dart';
import 'workout_timer.dart';

final _sessionProvider =
    StreamProvider.family<WorkoutSession?, String>((ref, id) => ref.watch(repositoryProvider).watchSession(id));
final _sessionSetsProvider =
    StreamProvider.family<List<SetLog>, String>((ref, id) => ref.watch(repositoryProvider).watchSets(id));

class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  final Set<String> _collapsed = {};
  String? _expandedKey;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable().catchError((_) {}); // best effort; unsupported on some devices
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(_sessionProvider(widget.sessionId)).value;
    if (session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final plan = session.plannedWorkoutId == null
        ? null
        : ref.watch(plannedStreamProvider(session.plannedWorkoutId!)).value;
    final sets = ref.watch(_sessionSetsProvider(widget.sessionId)).value ?? const <SetLog>[];
    final blocks = plan == null ? const <PlanBlock>[] : Repository.decodeBlocks(plan.blocksJson);
    final day = DayType.parse(session.dayType);
    final usedIds = blocks.expand((b) => b.items).map((i) => i.exerciseId).toSet();

    final totalSets = blocks.expand((b) => b.items).fold<int>(0, (s, i) => s + i.sets);
    final doneSets = sets.where((s) => s.completed).length;

    // Determine which card is open: the user's choice, otherwise the first unfinished exercise.
    String? firstOpen;
    var order = 0;
    for (final b in blocks) {
      for (final item in b.items) {
        final done = sets.where((s) => s.exerciseOrder == order && s.exerciseId == item.exerciseId && s.completed).length;
        if (firstOpen == null && done < item.sets) firstOpen = '$order:${item.exerciseId}';
        order++;
      }
    }
    final openKey = _expandedKey ?? firstOpen;

    final children = <Widget>[];
    order = 0;
    for (var b = 0; b < blocks.length; b++) {
      final block = blocks[b];
      children.add(SectionTitle(block.section.label,
          trailing: Icon(block.section.icon, color: block.section.color(Theme.of(context).colorScheme), size: 20)));
      for (var i = 0; i < block.items.length; i++) {
        final item = block.items[i];
        final itemOrder = order++;
        final key = '$itemOrder:${item.exerciseId}';
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ExerciseCard(
            key: ValueKey(key),
            sessionId: session.id,
            item: item,
            section: block.section,
            order: itemOrder,
            logged: sets.where((s) => s.exerciseOrder == itemOrder && s.exerciseId == item.exerciseId).toList(),
            expanded: key == openKey && !_collapsed.contains(key),
            onToggle: () => setState(() {
              if (key == openKey && !_collapsed.contains(key)) {
                _collapsed.add(key);
              } else {
                _collapsed.remove(key);
                _expandedKey = key;
              }
            }),
            onSwap: plan == null
                ? null
                : () async {
                    final changed = await showSwapSheet(
                      context,
                      plannedId: plan.id,
                      blockIndex: b,
                      itemIndex: i,
                      exerciseId: item.exerciseId,
                      day: day,
                      section: block.section,
                      excludeIds: usedIds,
                    );
                    if (changed && mounted) setState(() => _expandedKey = null);
                  },
          ),
        ));
      }
    }

    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(session.title),
            _ElapsedClock(startedAt: session.startedAt),
          ]),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'discard') await _discard(session);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'discard', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Discard workout'))),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(value: totalSets == 0 ? 0 : (doneSets / totalSets).clamp(0, 1).toDouble()),
          ),
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 180), children: [
          if (plan == null)
            const EmptyState(icon: Icons.fitness_center, title: 'Free workout', message: 'No plan attached to this session.'),
          ...children,
        ]),
        bottomSheet: _BottomBar(
          doneSets: doneSets,
          totalSets: totalSets,
          onFinish: () => _finish(session),
        ),
      ),
    );
  }

  Future<void> _discard(WorkoutSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this workout?'),
        content: const Text('All sets logged in this session will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(workoutTimerProvider.notifier).skip();
    await ref.read(repositoryProvider).discardSession(session.id);
    if (mounted) context.go('/');
  }

  Future<void> _finish(WorkoutSession session) async {
    final feedback = await showModalBottomSheet<_Feedback>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _FinishSheet(),
    );
    if (feedback == null || !mounted) return;
    final repo = ref.read(repositoryProvider);
    ref.read(workoutTimerProvider.notifier).skip();
    await repo.finishSession(session.id, rating: feedback.rating, effort: feedback.effort, notes: feedback.notes);

    final mine = await repo.loggedSets();
    final current = mine.where((s) => s.sessionId == session.id).toList();
    final previous = mine.where((s) => s.sessionId != session.id);
    final prs = detectPrs(current, previous);
    final volume = current.fold<double>(0, (s, x) => s + x.volume);
    final duration = DateTime.now().toUtc().difference(session.startedAt.toUtc());

    ref.read(occupiedEquipmentProvider.notifier).clear();
    unawaited(ref.read(syncControllerProvider.notifier).syncNow());
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _SummaryDialog(
        prs: prs,
        sets: current.length,
        volume: volume,
        minutes: duration.inMinutes,
        catalog: ref.read(catalogProvider),
      ),
    );
    if (mounted) context.go('/');
  }
}

class _ElapsedClock extends StatefulWidget {
  const _ElapsedClock({required this.startedAt});

  final DateTime startedAt;

  @override
  State<_ElapsedClock> createState() => _ElapsedClockState();
}

class _ElapsedClockState extends State<_ElapsedClock> {
  late final Timer _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secs = DateTime.now().toUtc().difference(widget.startedAt.toUtc()).inSeconds;
    return Text(formatClock(secs < 0 ? 0 : secs),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

/// One exercise in the live session with per-set logging.
class ExerciseCard extends ConsumerStatefulWidget {
  const ExerciseCard({
    super.key,
    required this.sessionId,
    required this.item,
    required this.section,
    required this.order,
    required this.logged,
    required this.expanded,
    required this.onToggle,
    this.onSwap,
  });

  final String sessionId;
  final PlanItem item;
  final Section section;
  final int order;
  final List<SetLog> logged;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onSwap;

  @override
  ConsumerState<ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends ConsumerState<ExerciseCard> {
  final List<TextEditingController> _weight = [];
  final List<TextEditingController> _reps = [];
  int _extraSets = 0;
  ProgressionAdvice? _advice;

  int get _rowCount {
    final maxLogged = widget.logged.fold<int>(0, (m, s) => s.setNumber > m ? s.setNumber : m);
    final base = widget.item.sets + _extraSets;
    return maxLogged > base ? maxLogged : base;
  }

  @override
  void initState() {
    super.initState();
    _loadAdvice();
  }

  Future<void> _loadAdvice() async {
    final a = await ref.read(coachServiceProvider).advice(widget.item.exerciseId, widget.item, excludeSessionId: widget.sessionId);
    if (!mounted) return;
    setState(() {
      _advice = a;
      final w = widget.item.targetWeightKg ?? a.weightKg;
      if (w == null) return;
      for (var i = 0; i < _weight.length; i++) {
        if (_weight[i].text.isEmpty && _loggedFor(i + 1) == null) _weight[i].text = formatKg(w);
      }
    });
  }

  @override
  void dispose() {
    for (final c in [..._weight, ..._reps]) {
      c.dispose();
    }
    super.dispose();
  }

  SetLog? _loggedFor(int setNumber) => widget.logged.where((s) => s.setNumber == setNumber).firstOrNull;

  void _ensureControllers() {
    while (_weight.length < _rowCount) {
      final n = _weight.length + 1;
      final log = _loggedFor(n);
      final prevWeight = _weight.isNotEmpty ? _weight.last.text : null;
      final suggested = widget.item.targetWeightKg ?? _advice?.weightKg;
      _weight.add(TextEditingController(
        text: log?.weightKg != null
            ? formatKg(log!.weightKg)
            : (prevWeight != null && prevWeight.isNotEmpty ? prevWeight : (suggested != null ? formatKg(suggested) : '')),
      ));
      _reps.add(TextEditingController(text: log?.reps?.toString() ?? ''));
    }
  }

  int get _targetReps => _advice?.targetReps ?? widget.item.repMax ?? widget.item.repMin ?? 10;

  Future<void> _toggleSet(int setNumber, bool complete, {int? durationSeconds}) async {
    final e = ref.read(catalogProvider).exercise(widget.item.exerciseId);
    final idx = setNumber - 1;
    final existing = _loggedFor(setNumber);
    final isTimed = widget.item.isTimed;
    double? weight = double.tryParse(_weight[idx].text.replaceAll(',', '.'));
    int? reps = int.tryParse(_reps[idx].text);
    if (complete && !isTimed && reps == null) {
      reps = _targetReps;
      _reps[idx].text = '$reps';
    }
    if (e != null && !e.isWeighted && weight == 0) weight = null;
    await ref.read(repositoryProvider).logSet(
          id: existing?.id,
          sessionId: widget.sessionId,
          exerciseId: widget.item.exerciseId,
          section: widget.section,
          exerciseOrder: widget.order,
          setNumber: setNumber,
          weightKg: isTimed ? null : weight,
          reps: isTimed ? null : reps,
          durationSeconds: isTimed ? (durationSeconds ?? widget.item.durationSeconds) : null,
          completed: complete,
        );
    if (complete) {
      HapticFeedback.lightImpact();
      final isLast = setNumber >= _rowCount;
      final rest = widget.item.restSeconds;
      if (rest > 0) {
        ref.read(workoutTimerProvider.notifier).start(isLast ? 'Rest · next exercise' : 'Rest', rest);
      }
    }
  }

  Future<void> _updateIfLogged(int setNumber) async {
    final existing = _loggedFor(setNumber);
    if (existing == null || !existing.completed) return;
    final idx = setNumber - 1;
    await ref.read(repositoryProvider).logSet(
          id: existing.id,
          sessionId: widget.sessionId,
          exerciseId: widget.item.exerciseId,
          section: widget.section,
          exerciseOrder: widget.order,
          setNumber: setNumber,
          weightKg: double.tryParse(_weight[idx].text.replaceAll(',', '.')),
          reps: int.tryParse(_reps[idx].text),
          durationSeconds: existing.durationSeconds,
          completed: true,
        );
  }

  void _startWork(int setNumber, String name) {
    final secs = widget.item.durationSeconds ?? 30;
    ref.read(workoutTimerProvider.notifier).start(
          name,
          secs,
          isWork: true,
          onDone: () => _toggleSet(setNumber, true, durationSeconds: secs),
        );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = ref.watch(catalogProvider).exercise(widget.item.exerciseId);
    final name = e?.name ?? widget.item.exerciseId;
    final done = widget.logged.where((s) => s.completed).length;
    final complete = done >= widget.item.sets;
    _ensureControllers();

    return Card(
      clipBehavior: Clip.antiAlias,
      color: complete ? t.colorScheme.primaryContainer.withValues(alpha: 0.45) : null,
      child: Column(children: [
        InkWell(
          onTap: widget.onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
            child: Row(children: [
              complete
                  ? CircleAvatar(radius: 22, backgroundColor: t.colorScheme.primary, child: Icon(Icons.check, color: t.colorScheme.onPrimary))
                  : ExerciseAvatar(exercise: e),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.item.targetLabel}'
                    '${widget.item.targetWeightKg != null ? ' · ${formatKg(widget.item.targetWeightKg)} kg' : ''}'
                    ' · $done/${widget.item.sets} done',
                    style: t.textTheme.bodySmall,
                  ),
                ]),
              ),
              IconButton(
                tooltip: 'How to',
                icon: const Icon(Icons.info_outline),
                onPressed: () => context.push('/exercise/${widget.item.exerciseId}'),
              ),
              if (widget.onSwap != null)
                IconButton(tooltip: 'Swap exercise', icon: const Icon(Icons.swap_horiz), onPressed: widget.onSwap),
            ]),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: widget.expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: _buildBody(context, e, name),
        ),
      ]),
    );
  }

  Widget _buildBody(BuildContext context, Exercise? e, String name) {
    final t = Theme.of(context);
    final isTimed = widget.item.isTimed;
    final tip = e?.tip;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_advice != null && _advice!.message.isNotEmpty && widget.section == Section.main)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: t.colorScheme.secondaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${_advice!.lastSummary != null ? 'Last time: ${_advice!.lastSummary}\n' : ''}${_advice!.message}',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSecondaryContainer),
            ),
          ),
        if (widget.item.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(widget.item.notes, style: t.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          ),
        if (tip != null && widget.section != Section.main)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(tip, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        if (!isTimed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              const SizedBox(width: 36, child: Text('Set', style: TextStyle(fontWeight: FontWeight.w600))),
              Expanded(child: Text(e?.isWeighted == false ? 'Extra kg' : 'kg', style: const TextStyle(fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              const Expanded(child: Text('Reps', style: TextStyle(fontWeight: FontWeight.w600))),
              const SizedBox(width: 56),
            ]),
          ),
        for (var n = 1; n <= _rowCount; n++) isTimed ? _timedRow(n, name) : _repsRow(n),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _extraSets++),
            icon: const Icon(Icons.add),
            label: const Text('Add set'),
          ),
        ),
      ]),
    );
  }

  Widget _repsRow(int n) {
    final log = _loggedFor(n);
    final done = log?.completed ?? false;
    final s = Theme.of(context).colorScheme;
    final repHint = widget.item.repMin == null
        ? '$_targetReps'
        : (widget.item.repMin == widget.item.repMax ? '${widget.item.repMin}' : '${widget.item.repMin}-${widget.item.repMax}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: CircleAvatar(
            radius: 13,
            backgroundColor: done ? s.primary : s.surfaceContainerHighest,
            child: Text('$n', style: TextStyle(fontSize: 12, color: done ? s.onPrimary : s.onSurface)),
          ),
        ),
        Expanded(
          child: TextField(
            controller: _weight[n - 1],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.center,
            decoration: const InputDecoration(hintText: '0', isDense: true),
            onChanged: (_) => _updateIfLogged(n),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _reps[n - 1],
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: InputDecoration(hintText: repHint, isDense: true),
            onChanged: (_) => _updateIfLogged(n),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child: IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: done ? s.primary : s.surfaceContainerHighest,
              foregroundColor: done ? s.onPrimary : s.onSurfaceVariant,
            ),
            onPressed: () {
              FocusScope.of(context).unfocus();
              _toggleSet(n, !done);
            },
            icon: const Icon(Icons.check),
          ),
        ),
      ]),
    );
  }

  Widget _timedRow(int n, String name) {
    final log = _loggedFor(n);
    final done = log?.completed ?? false;
    final s = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: CircleAvatar(
            radius: 13,
            backgroundColor: done ? s.primary : s.surfaceContainerHighest,
            child: Text('$n', style: TextStyle(fontSize: 12, color: done ? s.onPrimary : s.onSurface)),
          ),
        ),
        Expanded(child: Text(formatSeconds(widget.item.durationSeconds ?? 30))),
        if (!done)
          TextButton.icon(
            onPressed: () => _startWork(n, name),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Start'),
          ),
        SizedBox(
          width: 48,
          child: IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: done ? s.primary : s.surfaceContainerHighest,
              foregroundColor: done ? s.onPrimary : s.onSurfaceVariant,
            ),
            onPressed: () => _toggleSet(n, !done),
            icon: const Icon(Icons.check),
          ),
        ),
      ]),
    );
  }
}

class _BottomBar extends ConsumerWidget {
  const _BottomBar({required this.doneSets, required this.totalSets, required this.onFinish});

  final int doneSets;
  final int totalSets;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(workoutTimerProvider);
    final t = Theme.of(context);
    return Material(
      elevation: 8,
      color: t.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (timer != null) _TimerBanner(timer: timer),
            if (timer != null) const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text('$doneSets / $totalSets sets', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
              FilledButton.icon(
                onPressed: onFinish,
                icon: const Icon(Icons.flag_rounded),
                label: const Text('Finish'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _TimerBanner extends ConsumerStatefulWidget {
  const _TimerBanner({required this.timer});

  final TimerState timer;

  @override
  ConsumerState<_TimerBanner> createState() => _TimerBannerState();
}

class _TimerBannerState extends ConsumerState<_TimerBanner> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final timer = widget.timer;
    final color = timer.isWork ? const Color(0xFFEF6C4D) : t.colorScheme.primary;
    final ctrl = ref.read(workoutTimerProvider.notifier);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        SizedBox(
          width: 52,
          height: 52,
          child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(value: timer.progress, strokeWidth: 5, color: color, backgroundColor: color.withValues(alpha: 0.2)),
            Icon(timer.isWork ? Icons.directions_run : Icons.self_improvement, color: color),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(timer.label, style: t.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(formatClock(timer.remaining),
                style: t.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
        IconButton(onPressed: () => ctrl.add(-15), icon: const Text('-15')),
        IconButton(onPressed: () => ctrl.add(15), icon: const Text('+15')),
        IconButton(onPressed: ctrl.skip, icon: const Icon(Icons.skip_next_rounded), tooltip: 'Skip'),
      ]),
    );
  }
}

class _Feedback {
  const _Feedback(this.rating, this.effort, this.notes);
  final int rating;
  final int effort;
  final String notes;
}

class _FinishSheet extends StatefulWidget {
  const _FinishSheet();

  @override
  State<_FinishSheet> createState() => _FinishSheetState();
}

class _FinishSheetState extends State<_FinishSheet> {
  int _rating = 4;
  double _effort = 7;
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  static String _effortLabel(int e) => switch (e) {
        <= 4 => 'Easy',
        <= 6 => 'Moderate',
        <= 8 => 'Hard',
        _ => 'Max effort',
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('How did it go?', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        const Text('Overall feeling'),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 1; i <= 5; i++)
            IconButton(
              iconSize: 36,
              onPressed: () => setState(() => _rating = i),
              icon: Icon(i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded, color: Colors.amber.shade600),
            ),
        ]),
        const SizedBox(height: 8),
        Text('Effort: ${_effort.round()}/10 · ${_effortLabel(_effort.round())}'),
        Slider(value: _effort, min: 1, max: 10, divisions: 9, label: '${_effort.round()}', onChanged: (v) => setState(() => _effort = v)),
        TextField(
          controller: _notes,
          maxLines: 2,
          decoration: const InputDecoration(hintText: 'Notes (optional) – e.g. "knee felt great", "gym was busy"'),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _Feedback(_rating, _effort.round(), _notes.text.trim())),
            child: const Text('Save workout'),
          ),
        ),
      ]),
    );
  }
}

class _SummaryDialog extends StatelessWidget {
  const _SummaryDialog({
    required this.prs,
    required this.sets,
    required this.volume,
    required this.minutes,
    required this.catalog,
  });

  final List<PersonalRecord> prs;
  final int sets;
  final double volume;
  final int minutes;
  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      icon: Icon(prs.isEmpty ? Icons.check_circle_rounded : Icons.emoji_events_rounded,
          size: 48, color: prs.isEmpty ? t.colorScheme.primary : Colors.amber.shade600),
      title: Text(prs.isEmpty ? 'Workout saved!' : 'New personal records!'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: StatTile(label: 'minutes', value: '$minutes')),
          const SizedBox(width: 8),
          Expanded(child: StatTile(label: 'sets', value: '$sets')),
          const SizedBox(width: 8),
          Expanded(child: StatTile(label: 'kg volume', value: volume.toStringAsFixed(0))),
        ]),
        if (prs.isNotEmpty) ...[
          const SizedBox(height: Gap.md),
          for (final pr in prs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.emoji_events_outlined, color: Colors.amber.shade700),
              title: Text(catalog.exerciseName(pr.exerciseId), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(pr.describe()),
            ),
        ],
      ]),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
