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
import '../../domain/watch_protocol.dart';
import '../../domain/workout_countdown.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../../widgets/report_issue_sheet.dart';
import '../dashboard/dashboard_screen.dart';
import '../settings/equipment_screen.dart' show showBarWeightDialog;
import '../watch/watch_sync.dart';
import 'coach_strip.dart';
import 'section_checklist.dart';
import 'set_logger.dart';
import 'set_tick.dart';
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

  /// Exercises in plan order as last built, the open one, sets added by hand, and where each card is on screen.
  List<_Entry> _entries = const [];
  String? _openKey;
  final _extraSets = <String, int>{};
  final _cardKeys = <String, GlobalKey>{};

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

  /// When the last set of the open card is done, opens the next unfinished exercise below it (then from the top) and
  /// brings it into view. Also after a card was opened by hand.
  void _advance(List<SetLog> before, List<SetLog> after) {
    final i = _entries.indexWhere((e) => e.key == _openKey);
    if (i < 0) return;
    if (_entries[i].isDone(before) || !_entries[i].isDone(after)) return;
    final next = [..._entries.skip(i + 1), ..._entries.take(i)].where((e) => e.isCard && !e.isDone(after)).firstOrNull?.key;
    ref.read(openExerciseProvider.notifier).clear(); // the watch moves on by itself
    setState(() {
      _expandedKey = next;
      _collapsed.remove(next);
    });
    if (next == null) return;
    // After the finished card has folded (200 ms plus the frames around it), or the target would move meanwhile.
    Future.delayed(const Duration(milliseconds: 400), () {
      final card = mounted ? _cardKeys[next]?.currentContext : null;
      if (card == null || !card.mounted) return;
      Scrollable.ensureVisible(card, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(_sessionSetsProvider(widget.sessionId), (prev, next) {
      final before = prev?.value;
      final after = next.value;
      if (before != null && after != null) _advance(before, after);
    });
    final session = ref.watch(_sessionProvider(widget.sessionId)).value;
    if (session == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final plan = session.plannedWorkoutId == null
        ? null
        : ref.watch(plannedStreamProvider(session.plannedWorkoutId!)).value;
    final sets = ref.watch(_sessionSetsProvider(widget.sessionId)).value ?? const <SetLog>[];
    final blocks = plan == null ? const <PlanBlock>[] : Repository.decodeBlocks(plan.blocksJson);
    final changes = plan == null ? const <PlanChange>[] : PlanMeta.decode(plan.metaJson).changes;
    final day = DayType.parse(session.dayType);
    final usedIds = blocks.expand((b) => b.items).map((i) => i.exerciseId).toSet();

    // Determine which card is open: the user's choice or the one after the last finished, otherwise the first unfinished.
    var order = 0;
    _entries = [
      for (final b in blocks)
        for (final item in b.items)
          _Entry(order++, item.exerciseId, b.section, item.sets + (_extraSets['${order - 1}:${item.exerciseId}'] ?? 0)),
    ];
    // Progress counts the work; warm-up and cool-down are ticked off on the side.
    final cards = _entries.where((e) => e.isCard).toList();
    final totalSets = cards.fold<int>(0, (n, e) => n + e.sets);
    final doneSets = cards.fold<int>(0, (n, e) => n + e.doneOf(sets));
    final openKey = _openKey = _expandedKey ?? cards.where((e) => !e.isDone(sets)).firstOrNull?.key;
    final currentExerciseId = openKey?.substring(openKey.indexOf(':') + 1);

    final children = <Widget>[];
    order = 0;
    for (var b = 0; b < blocks.length; b++) {
      final block = blocks[b];
      Future<void> swap(int i) async {
        final changed = await showSwapSheet(
          context,
          plannedId: plan!.id,
          blockIndex: b,
          itemIndex: i,
          exerciseId: block.items[i].exerciseId,
          day: day,
          section: block.section,
          excludeIds: usedIds,
        );
        if (!changed || !mounted) return;
        ref.read(openExerciseProvider.notifier).clear();
        setState(() => _expandedKey = null);
      }

      if (_Entry.isChecklist(block.section)) {
        children.add(SectionChecklist(
          sessionId: session.id,
          section: block.section,
          items: [for (final item in block.items) (order++, item)],
          logged: sets,
          onSwap: plan == null ? null : swap,
        ));
        continue;
      }
      children.add(SectionTitle(block.section.label));
      for (var i = 0; i < block.items.length; i++) {
        final item = block.items[i];
        final itemOrder = order++;
        final key = '$itemOrder:${item.exerciseId}';
        children.add(Padding(
          key: _cardKeys.putIfAbsent(key, GlobalKey.new),
          padding: const EdgeInsets.only(bottom: Gap.item),
          child: ExerciseCard(
            key: ValueKey(key),
            sessionId: session.id,
            item: item,
            section: block.section,
            order: itemOrder,
            logged: sets.where((s) => s.exerciseOrder == itemOrder && s.exerciseId == item.exerciseId).toList(),
            expanded: key == openKey && !_collapsed.contains(key),
            fromCoach: plan?.source == 'ai',
            change: changes.where((c) => c.to == item.exerciseId).lastOrNull,
            onAddSet: () => setState(() => _extraSets[key] = (_extraSets[key] ?? 0) + 1),
            onToggle: () => setState(() {
              if (key == openKey && !_collapsed.contains(key)) {
                _collapsed.add(key);
              } else {
                _collapsed.remove(key);
                _expandedKey = key;
                ref.read(openExerciseProvider.notifier).open(session.id, itemOrder);
              }
            }),
            onSwap: plan == null ? null : () => swap(i),
          ),
        ));
      }
    }

    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: AppBarTitle.toolbarHeight,
          title: AppBarTitle(session.title, subtitle: _ElapsedClock(startedAt: session.startedAt)),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'discard') await _discard(session);
                if (v == 'pain' && context.mounted) {
                  await showReportPain(context,
                      exerciseId: currentExerciseId, plannedId: plan?.id, sessionId: session.id);
                }
                if (v == 'tell' && context.mounted) {
                  await showTellCoach(context,
                      exerciseId: currentExerciseId, plannedId: plan?.id, sessionId: session.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'pain', child: ListTile(leading: Icon(Icons.healing_outlined), title: Text('Report pain'))),
                PopupMenuItem(
                    value: 'tell', child: ListTile(leading: Icon(Icons.edit_note), title: Text('Tell your coach'))),
                PopupMenuItem(value: 'discard', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Discard workout'))),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(value: totalSets == 0 ? 0 : (doneSets / totalSets).clamp(0, 1).toDouble()),
          ),
        ),
        // Not a lazy list: cards keep numbers typed but not ticked yet when they scroll off screen.
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.lg),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (plan == null)
              const EmptyState(icon: Icons.fitness_center, title: 'Free workout', message: 'No plan attached to this session.'),
            ...children,
          ]),
        ),
        // A bottom *navigation* bar keeps the system inset, so Finish stays above Android's nav buttons.
        bottomNavigationBar: _BottomBar(
          doneSets: doneSets,
          totalSets: totalSets,
          onFinish: () => _finish(session, doneSets, totalSets),
        ),
      ),
    );
  }

  Future<void> _discard(WorkoutSession session) async {
    final ok = await confirmDestructive(context,
        title: 'Discard this workout?',
        message: 'All sets logged in this session will be deleted.',
        action: 'Discard',
        cancel: 'Keep');
    if (!ok) return;
    ref.read(workoutTimerProvider.notifier).skip();
    await ref.read(repositoryProvider).discardSession(session.id);
    if (mounted) context.go('/');
  }

  Future<void> _finish(WorkoutSession session, int doneSets, int totalSets) async {
    final repo = ref.read(repositoryProvider);
    final logged = (await repo.loggedSets())
        .where((s) => s.section != Section.warmup.name && s.section != Section.cooldown.name);
    final prs = detectPrs(
        logged.where((s) => s.sessionId == session.id).toList(), logged.where((s) => s.sessionId != session.id));
    if (!mounted) return;
    final feedback = await showAppSheet<_Feedback>(
      context,
      builder: (_) => _FinishSheet(
        minutes: DateTime.now().toUtc().difference(session.startedAt.toUtc()).inMinutes,
        doneSets: doneSets,
        totalSets: totalSets,
        prs: prs,
      ),
    );
    if (feedback == null || !mounted) return;
    ref.read(workoutTimerProvider.notifier).skip();
    await repo.finishSession(session.id, effort: feedback.effort, notes: feedback.notes);

    ref.read(occupiedEquipmentProvider.notifier).clear();
    unawaited(ref.read(syncControllerProvider.notifier).syncNow());
    unawaited(ref.read(coachServiceProvider).pregenerateNext());
    unawaited(ref.read(healthSyncProvider).catchUp()); // save to Health Connect, read the watch's heart rate
    if (!mounted) return;
    showSnack(context, 'Workout saved');
    context.go('/');
  }
}

/// One exercise of the running plan: how many sets it takes and whether they are done.
class _Entry {
  const _Entry(this.order, this.exerciseId, this.section, this.sets);

  final int order;
  final String exerciseId;
  final Section section;
  final int sets;

  String get key => '$order:$exerciseId';

  /// Warm-up and cool-down are a list to tick off, the rest are cards to log sets on.
  static bool isChecklist(Section s) => s.isChecklist;
  bool get isCard => !isChecklist(section);

  int doneOf(List<SetLog> logged) {
    final n = logged.where((s) => s.exerciseOrder == order && s.exerciseId == exerciseId && s.completed).length;
    return n > sets ? sets : n;
  }

  bool isDone(List<SetLog> logged) => doneOf(logged) >= sets;
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
    this.onAddSet,
    this.fromCoach = false,
    this.change,
  });

  final String sessionId;
  final PlanItem item;
  final Section section;
  final int order;
  final List<SetLog> logged;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback? onSwap;

  /// A set was added by hand: the exercise is not done before it.
  final VoidCallback? onAddSet;

  /// The plan was written / refined by the AI coach (its item notes are the coach's).
  final bool fromCoach;

  /// The plan change that put this exercise here (coach adjustment or instant limitation swap), if any.
  final PlanChange? change;

  @override
  ConsumerState<ExerciseCard> createState() => _ExerciseCardState();
}

class _ExerciseCardState extends ConsumerState<ExerciseCard> {
  final List<TextEditingController> _weight = [];
  final List<TextEditingController> _reps = [];
  final List<FocusNode> _weightFocus = [];

  /// Set numbers whose weight was typed here; a change further up leaves them alone.
  final _ownWeight = <int>{};
  int _extraSets = 0;
  ProgressionAdvice? _advice;

  /// Kg of one plate when this machine has a numbered stack: the weight fields hold plate numbers then.
  double? _plateKg;

  int get _rowCount {
    final maxLogged = widget.logged.fold<int>(0, (m, s) => s.setNumber > m ? s.setNumber : m);
    final base = widget.item.sets + _extraSets;
    return maxLogged > base ? maxLogged : base;
  }

  @override
  void initState() {
    super.initState();
    _plateKg = ref.read(loadModelProvider).plateKg(widget.item.exerciseId);
    _loadAdvice();
  }

  @override
  void didUpdateWidget(ExerciseCard old) {
    super.didUpdateWidget(old);
    // Weights logged before turned out to be plate numbers (said so in the equipment settings).
    for (final s in widget.logged) {
      final i = s.setNumber - 1;
      final was = old.logged.where((o) => o.id == s.id).firstOrNull;
      if (was != null && was.plate == null && s.plate != null && i < _weight.length && !_ownWeight.contains(s.setNumber)) {
        _weight[i].text = _loggedText(s);
      }
    }
  }

  /// A logged weight the way this card shows it: kg or a plate number.
  String _loggedText(SetLog s) => switch (_plateKg) {
        final plate? => formatPlate(s.plate ?? (s.weightKg ?? 0) / plate),
        _ => formatKg(s.weightKg),
      };

  /// A weight to lift: kg or a whole plate number.
  String _targetText(double kg) => switch (_plateKg) {
        final plate? => '${(kg / plate).round()}',
        _ => formatKg(kg),
      };

  /// What is typed for set [n], as the weight to store.
  ({double? kg, double? plate}) _entered(int n) {
    final v = double.tryParse(_weight[n - 1].text.replaceAll(',', '.'));
    final plate = _plateKg;
    return plate == null || v == null ? (kg: v, plate: null) : (kg: v * plate, plate: v);
  }

  /// The machine was set to plate numbers or back to kg: what is typed follows. Other plate weights change no numbers.
  void _changeUnit(double? plateKg) {
    final before = _plateKg;
    if (plateKg == before) return;
    setState(() {
      _plateKg = plateKg;
      if (before != null && plateKg != null) return;
      for (var n = 1; n <= _weight.length; n++) {
        final log = _loggedFor(n);
        final v = double.tryParse(_weight[n - 1].text.replaceAll(',', '.'));
        if (log?.weightKg != null) {
          _weight[n - 1].text = _loggedText(log!);
        } else if (v != null) {
          _weight[n - 1].text = _targetText(before == null ? v : v * before);
        }
      }
    });
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
        if (_weight[i].text.isEmpty && _loggedFor(i + 1) == null) _weight[i].text = _targetText(w);
      }
    });
  }

  @override
  void dispose() {
    for (final c in [..._weight, ..._reps]) {
      c.dispose();
    }
    for (final f in _weightFocus) {
      f.dispose();
    }
    super.dispose();
  }

  SetLog? _loggedFor(int setNumber) => widget.logged.where((s) => s.setNumber == setNumber).firstOrNull;

  void _ensureControllers() {
    while (_weight.length < _rowCount) {
      final n = _weight.length + 1;
      final log = _loggedFor(n);
      final prevWeight = _weight.isNotEmpty ? _weight.last.text : null;
      _weightFocus.add(FocusNode());
      final suggested = widget.item.targetWeightKg ?? _advice?.weightKg;
      _weight.add(TextEditingController(
        text: log?.weightKg != null
            ? _loggedText(log!)
            : (prevWeight != null && prevWeight.isNotEmpty ? prevWeight : (suggested != null ? _targetText(suggested) : '')),
      ));
      _reps.add(TextEditingController(text: log?.reps?.toString() ?? ''));
    }
  }

  int get _targetReps => targetRepsFor(widget.item, _advice);

  SetRef _setRef(int setNumber) => SetRef(
        sessionId: widget.sessionId,
        order: widget.order,
        exerciseId: widget.item.exerciseId,
        section: widget.section.name,
        set: setNumber,
        seconds: widget.item.durationSeconds ?? 30,
        rest: widget.item.restSeconds,
        last: setNumber >= _rowCount,
      );

  Future<void> _toggleSet(int setNumber, bool complete) async {
    final e = ref.read(catalogProvider).exercise(widget.item.exerciseId);
    final idx = setNumber - 1;
    final isTimed = widget.item.isTimed;
    var weight = _entered(setNumber);
    int? reps = int.tryParse(_reps[idx].text);
    if (complete && !isTimed && reps == null) {
      reps = _targetReps;
      _reps[idx].text = '$reps';
    }
    if (e != null && (!_weightColumn(e) || (!e.isWeighted && weight.kg == 0))) weight = (kg: null, plate: null);
    if (complete) HapticFeedback.lightImpact();
    await ref.read(setLoggerProvider).log(
          _setRef(setNumber),
          weightKg: isTimed ? null : weight.kg,
          plate: isTimed ? null : weight.plate,
          reps: isTimed ? null : reps,
          durationSeconds: isTimed ? widget.item.durationSeconds : null,
          completed: complete,
        );
  }

  /// A set came in from the watch: show its values instead of what this row was filled with.
  void _showFromWatch(SetLog log) {
    final idx = log.setNumber - 1;
    if (log.exerciseOrder != widget.order || log.exerciseId != widget.item.exerciseId || idx >= _reps.length) return;
    _reps[idx].text = log.reps?.toString() ?? '';
    if (log.weightKg == null) return;
    _weight[idx].text = _loggedText(log);
    _weightToLaterSets(log.setNumber);
  }

  Future<void> _updateIfLogged(int setNumber) async {
    final existing = _loggedFor(setNumber);
    if (existing == null || !existing.completed) return;
    final idx = setNumber - 1;
    final hasWeight = _weightColumn(ref.read(catalogProvider).exercise(widget.item.exerciseId));
    final weight = _entered(setNumber);
    await ref.read(repositoryProvider).logSet(
          id: existing.id,
          sessionId: widget.sessionId,
          exerciseId: widget.item.exerciseId,
          section: widget.section,
          exerciseOrder: widget.order,
          setNumber: setNumber,
          weightKg: hasWeight ? weight.kg : null,
          plate: hasWeight ? weight.plate : null,
          reps: int.tryParse(_reps[idx].text),
          durationSeconds: existing.durationSeconds,
          completed: true,
        );
  }

  /// Work timer for a timed set; per-side exercises run one phase per side before the set is logged.
  void _startWork(int setNumber, String name) =>
      ref.read(workoutTimerProvider.notifier).startWork(name, _setRef(setNumber), perSide: _perSide);

  /// A weight typed in set [n] also goes to the sets after it.
  void _weightTyped(int n) {
    _ownWeight.add(n);
    _weightToLaterSets(n);
    _updateIfLogged(n);
  }

  /// Copies the weight of set [n] to the sets after it, up to the first one that was typed or logged already.
  void _weightToLaterSets(int n) {
    for (var next = n + 1; next <= _weight.length; next++) {
      if (_ownWeight.contains(next)) break;
      if (_loggedFor(next) == null) _weight[next - 1].text = _weight[n - 1].text;
    }
  }

  /// Working sets on weighted exercises need a weight: an empty one would be missing from records and advice.
  bool _weightMissing(int n, Exercise? e) =>
      e != null &&
      e.isWeighted &&
      e.load != LoadType.optional &&
      widget.section != Section.warmup &&
      _weightColumn(e) &&
      double.tryParse(_weight[n - 1].text.replaceAll(',', '.')) == null;

  void _tickReps(int n, {required bool done}) {
    final e = ref.read(catalogProvider).exercise(widget.item.exerciseId);
    if (!done && _weightMissing(n, e)) {
      showSnack(
          context,
          e?.bar != null
              ? 'Enter the plates first (0 for the empty bar).'
              : _plateKg != null
                  ? 'Enter the plate number first.'
                  : 'Enter the weight first.');
      _weightFocus[n - 1].requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();
    _toggleSet(n, !done);
  }

  bool get _perSide =>
      widget.item.perSide || (ref.read(catalogProvider).exercise(widget.item.exerciseId)?.unilateral ?? false);

  /// Optional extra load (pull-ups, dips): the kg column only shows once asked for or already used.
  bool _showOptionalWeight = false;

  bool _weightColumn(Exercise? e) {
    if (e == null) return true;
    return switch (e.load) {
      LoadType.none => false,
      LoadType.optional => _showOptionalWeight ||
          widget.item.targetWeightKg != null ||
          widget.logged.any((s) => (s.weightKg ?? 0) > 0),
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = ref.watch(catalogProvider).exercise(widget.item.exerciseId);
    final name = e?.name ?? widget.item.exerciseId;
    final done = widget.logged.where((s) => s.completed).length;
    final complete = done >= widget.item.sets;
    _ensureControllers();
    ref.listen(watchSetProvider, (_, log) {
      if (log != null) _showFromWatch(log);
    });
    ref.listen(loadModelProvider, (_, loads) => _changeUnit(loads.plateKg(widget.item.exerciseId)));

    return Card(
      clipBehavior: Clip.antiAlias,
      color: complete ? t.colorScheme.primaryContainer.withValues(alpha: 0.45) : null,
      child: Column(children: [
        InkWell(
          onTap: widget.onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(children: [
              complete
                  ? CircleAvatar(radius: 18, backgroundColor: t.colorScheme.primary, child: Icon(Icons.check, size: 20, color: t.colorScheme.onPrimary))
                  : ExerciseAvatar(exercise: e, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      widget.item.copyWith(perSide: _perSide).targetLabel,
                      // The open card has the weight in its fields.
                      if (widget.item.targetWeightKg case final kg? when !widget.expanded)
                        _plateKg == null ? '${formatKg(kg)} kg' : 'plate ${_targetText(kg)}',
                      if (!widget.expanded && done > 0 && !complete) '$done done',
                    ].join(' · '),
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ]),
              ),
              if (widget.expanded) ...[
                IconButton(
                  tooltip: 'How to',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => context.push('/exercise/${widget.item.exerciseId}'),
                ),
                if (widget.onSwap != null)
                  IconButton(tooltip: 'Swap exercise', icon: const Icon(Icons.swap_horiz), onPressed: widget.onSwap),
              ] else
                const SizedBox(width: Gap.sm, height: Gap.tap),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CoachStrip(
          item: widget.item,
          exercise: e,
          advice: _advice,
          fromCoach: widget.fromCoach,
          change: widget.change,
        ),
        if (!isTimed && e?.bar != null && ref.watch(loadModelProvider).barWeight(e!.bar!) <= 0) _barMissing(e),
        if (!isTimed)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: DefaultTextStyle.merge(
              style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: t.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const SizedBox(width: _numberWidth),
                if (_weightColumn(e)) ...[
                  Expanded(child: Text(_weightHeader(e))),
                  const SizedBox(width: Gap.sm),
                ],
                Expanded(child: Text(_perSide ? 'Reps / side' : 'Reps')),
                const SizedBox(width: Gap.sm + Gap.tap),
              ]),
            ),
          ),
        for (var n = 1; n <= _rowCount; n++) isTimed ? _timedRow(n, name) : _repsRow(n, showWeight: _weightColumn(e)),
        Wrap(spacing: Gap.sm, children: [
          TextButton.icon(
            onPressed: () {
              setState(() => _extraSets++);
              widget.onAddSet?.call();
            },
            icon: const Icon(Icons.add, size: 20),
            label: const Text('Add set'),
          ),
          if (!isTimed && e?.load == LoadType.optional && !_weightColumn(e))
            TextButton.icon(
              onPressed: () => setState(() => _showOptionalWeight = true),
              icon: const Icon(Icons.fitness_center, size: 18),
              label: const Text('Add weight'),
            ),
        ]),
      ]),
    );
  }

  String _weightHeader(Exercise? e) => switch (e?.load) {
        LoadType.assist || LoadType.weight when _plateKg != null =>
          '${e!.isAssisted ? 'Assist plate' : 'Plate'} (${formatKg(_plateKg)} kg each)',
        LoadType.assist => 'Assist kg',
        LoadType.optional => 'Extra kg',
        _ => e?.bar == null
            ? 'kg'
            : switch (ref.watch(loadModelProvider).barWeight(e!.bar!)) {
                > 0 && final bar => 'Plates kg (+${formatKg(bar)} bar)',
                _ => 'Plates kg',
              },
      };

  /// Bar exercises whose bar weight is unknown (Smith machines): stats would be too low.
  Widget _barMissing(Exercise e) {
    final t = Theme.of(context);
    return TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: t.colorScheme.attention, padding: EdgeInsets.zero),
      onPressed: () => showBarWeightDialog(context, ref, e.bar!),
      icon: const Icon(Icons.error_outline_rounded, size: 18),
      label: const Text('Set the bar weight'),
    );
  }

  static const _numberWidth = 28.0;

  Widget _number(int n, {required bool done}) {
    final t = Theme.of(context);
    return SizedBox(
      width: _numberWidth,
      child: Text('$n',
          style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700, color: done ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant)),
    );
  }

  /// A logged set reads as plain text; it can still be corrected in place.
  InputDecoration _cell(String hint, {required bool done}) => InputDecoration(
        hintText: hint,
        isDense: true,
        fillColor: done ? Colors.transparent : null,
      );

  static void _selectAll(TextEditingController c) =>
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);

  Widget _repsRow(int n, {required bool showWeight}) {
    final log = _loggedFor(n);
    final done = log?.completed ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        _number(n, done: done),
        if (showWeight) ...[
          Expanded(
            child: TextField(
              controller: _weight[n - 1],
              focusNode: _weightFocus[n - 1],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              decoration: _cell('–', done: done),
              onTap: () => _selectAll(_weight[n - 1]),
              onChanged: (_) => _weightTyped(n),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: TextField(
            controller: _reps[n - 1],
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            // What a tick logs when nothing else is typed.
            decoration: _cell('$_targetReps', done: done),
            onTap: () => _selectAll(_reps[n - 1]),
            onChanged: (_) => _updateIfLogged(n),
          ),
        ),
        const SizedBox(width: 8),
        SetTick(label: done ? 'Undo set $n' : 'Log set $n', done: done, onPressed: () => _tickReps(n, done: done)),
      ]),
    );
  }

  Widget _timedRow(int n, String name) {
    final log = _loggedFor(n);
    final done = log?.completed ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        _number(n, done: done),
        Expanded(
          child: Text('${formatSeconds(widget.item.durationSeconds ?? 30)}${_perSide ? ' / side' : ''}'),
        ),
        if (!done)
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => _startWork(n, name),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Start'),
          ),
        const SizedBox(width: Gap.sm),
        SetTick(label: done ? 'Undo set $n' : 'Log set $n', done: done, onPressed: () => _toggleSet(n, !done)),
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
    return BottomActionBar(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (timer != null) ...[_TimerBanner(timer: timer), const SizedBox(height: Gap.sm)],
        Row(children: [
          Expanded(
            child: Text('$doneSets / $totalSets sets',
                style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: Gap.sm),
          // Quiet until the work is done: it is used once, the ticks all the time.
          if (totalSets > 0 && doneSets < totalSets)
            OutlinedButton(onPressed: onFinish, child: const Text('Finish'))
          else
            FilledButton.icon(
              onPressed: onFinish,
              icon: const Icon(Icons.flag_rounded),
              label: const Text('Finish'),
            ),
        ]),
      ]),
    );
  }
}

class _TimerBanner extends ConsumerStatefulWidget {
  const _TimerBanner({required this.timer});

  final Countdown timer;

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
    final now = ref.read(nowMsProvider)();
    final pause = timer.phaseAt(now)?.pause ?? false; // changing sides
    final color = timer.isWork && !pause ? t.colorScheme.attention : t.colorScheme.primary;
    final ctrl = ref.read(workoutTimerProvider.notifier);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(Gap.radiusMd)),
      child: Row(children: [
        SizedBox(
          width: 44,
          height: 44,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                  value: timer.progress(now), strokeWidth: 4, color: color, backgroundColor: color.withValues(alpha: 0.2)),
            ),
            Icon(
                pause
                    ? Icons.swap_horiz_rounded
                    : timer.isWork
                        ? Icons.directions_run
                        : Icons.self_improvement,
                color: color,
                size: 22),
          ]),
        ),
        const SizedBox(width: Gap.md - 4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(timer.phaseAt(now)?.label ?? '', style: t.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(formatClock(timer.remaining(now)),
                  style: t.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ]),
        ),
        IconButton(
            tooltip: 'Minus 15 seconds',
            onPressed: () => ctrl.add(-15),
            icon: const Text('-15', style: TextStyle(fontWeight: FontWeight.w700))),
        IconButton(
            tooltip: 'Plus 15 seconds',
            onPressed: () => ctrl.add(15),
            icon: const Text('+15', style: TextStyle(fontWeight: FontWeight.w700))),
        IconButton(onPressed: ctrl.skip, icon: const Icon(Icons.skip_next_rounded), tooltip: 'Skip'),
      ]),
    );
  }
}

class _Feedback {
  const _Feedback(this.effort, this.notes);

  /// 1–10, null when not given.
  final int? effort;
  final String notes;
}

/// Result, records and how it felt; saving ends the workout.
class _FinishSheet extends ConsumerStatefulWidget {
  const _FinishSheet({required this.minutes, required this.doneSets, required this.totalSets, required this.prs});

  final int minutes;
  final int doneSets;
  final int totalSets;
  final List<PersonalRecord> prs;

  @override
  ConsumerState<_FinishSheet> createState() => _FinishSheetState();
}

class _FinishSheetState extends ConsumerState<_FinishSheet> {
  /// Values on the 1–10 scale the program and the coach use (an average of 8.5 asks for a deload).
  static const _efforts = {4: 'Easy', 6: 'Moderate', 8: 'Hard', 9: 'Very hard', 10: 'Max'};

  int? _effort;
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SingleChildScrollView(
      padding: sheetPadding(context),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Finish workout', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.xs),
        Text('${widget.minutes} min · ${widget.doneSets} set${widget.doneSets == 1 ? '' : 's'}',
            style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        for (final pr in widget.prs)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.emoji_events_rounded, size: 20, color: t.colorScheme.gold),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                      text: ref.read(catalogProvider).exerciseName(pr.exerciseId),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: '\n${pr.describe()}', style: t.textTheme.bodySmall),
                ])),
              ),
            ]),
          ),
        if (widget.doneSets < widget.totalSets) ...[
          const SizedBox(height: Gap.sm),
          Row(children: [
            Icon(Icons.error_outline_rounded, size: 20, color: t.colorScheme.attention),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                widget.doneSets == 0
                    ? 'No sets are ticked yet.'
                    : '${widget.totalSets - widget.doneSets} of ${widget.totalSets} sets are not ticked.',
                style: TextStyle(color: t.colorScheme.attention, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ],
        const SizedBox(height: Gap.md),
        const Text('How hard was it?'),
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.sm, children: [
          for (final MapEntry(key: value, value: label) in _efforts.entries)
            ChoiceChip(
              label: Text(label),
              showCheckmark: false,
              selected: _effort == value,
              onSelected: (on) => setState(() => _effort = on ? value : null),
            ),
        ]),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _notes,
          maxLines: 2,
          decoration: const InputDecoration(hintText: 'Note (optional)'),
        ),
        const SizedBox(height: Gap.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _Feedback(_effort, _notes.text.trim())),
            child: const Text('Save workout'),
          ),
        ),
      ]),
    );
  }
}
