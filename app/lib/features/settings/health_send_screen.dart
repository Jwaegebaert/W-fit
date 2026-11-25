import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../providers.dart';
import '../../services/health_service.dart' show HealthOutcome;
import '../../widgets/common.dart';

/// Pick finished workouts to write to Health Connect, also ones that were sent before (they are replaced as an
/// updated record, so Samsung Health gets another chance to import them).
class HealthSendScreen extends ConsumerStatefulWidget {
  const HealthSendScreen({super.key});

  @override
  ConsumerState<HealthSendScreen> createState() => _HealthSendScreenState();
}

class _HealthSendScreenState extends ConsumerState<HealthSendScreen> {
  List<WorkoutSession>? _sessions;
  final _selected = <String>{};

  /// Session id → what happened, for the workouts sent from this screen.
  final _results = <String, HealthOutcome>{};

  /// Sessions another app recorded too.
  Set<String> _covered = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await ref.read(repositoryProvider).completedSessions();
    final sync = ref.read(healthSyncProvider);
    final covered = {for (final s in sessions) if (await sync.coveredApp(s.id) != null) s.id};
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _covered = covered;
      });
    }
  }

  Future<void> _send() async {
    final chosen = [for (final s in _sessions!) if (_selected.contains(s.id)) s];
    setState(() {
      _busy = true;
      _results.clear();
    });
    final r = await ref.read(healthSyncProvider).send(chosen, onResult: (id, outcome) {
      if (mounted) setState(() => _results[id] = outcome);
    });
    await _load();
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Failed ones stay selected for another try.
      _selected.removeWhere((id) => _results[id] == HealthOutcome.saved || _results[id] == HealthOutcome.covered);
    });
    String n(int count) => '$count workout${count == 1 ? '' : 's'}';
    showSnack(
      context,
      r.unavailable
          ? 'Health Connect can\'t be used right now.'
          : [
              '${n(r.changed)} saved',
              if (r.covered > 0) '${n(r.covered)} left to your watch',
              if (r.failed > 0) '${n(r.failed)} not accepted',
            ].join(', '),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sessions = _sessions;
    if (sessions == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Send workouts')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final unsent = [for (final s in sessions) if (s.healthExportedAt == null && !_covered.contains(s.id)) s.id];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send workouts'),
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: sessions.isEmpty
          ? const EmptyState(icon: Icons.fitness_center, title: 'No finished workouts yet')
          : ListView(padding: Gap.page, children: [
              Card(
                color: t.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'Sends to Health Connect; whether a workout then shows up is up to Samsung Health. Workouts your watch '
                    'recorded at the same time are left out.',
                    style: TextStyle(color: t.colorScheme.onSecondaryContainer),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: Gap.xs, children: [
                  TextButton(
                    onPressed: _busy || unsent.isEmpty ? null : () => setState(() => _selected.addAll(unsent)),
                    child: Text('Select not sent (${unsent.length})'),
                  ),
                  TextButton(
                    onPressed: _busy || _selected.isEmpty ? null : () => setState(_selected.clear),
                    child: const Text('Clear'),
                  ),
                ]),
              ),
              Card(
                child: Column(children: [
                  for (final s in sessions)
                    CheckboxListTile(
                      value: _selected.contains(s.id),
                      onChanged: _busy
                          ? null
                          : (on) => setState(() => on == true ? _selected.add(s.id) : _selected.remove(s.id)),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(s.title),
                      subtitle: Text('${DateFormat('EEE d MMM · HH:mm').format(s.startedAt.toLocal())}\n${_status(s)}'),
                      isThreeLine: true,
                      secondary: switch (_results[s.id]) {
                        HealthOutcome.saved => Icon(Icons.check_circle, color: t.colorScheme.primary),
                        HealthOutcome.covered => Icon(Icons.watch_outlined, color: t.colorScheme.tertiary),
                        HealthOutcome.failed => Icon(Icons.error_outline, color: t.colorScheme.error),
                        null => null,
                      },
                    ),
                ]),
              ),
            ]),
      bottomNavigationBar: sessions.isEmpty
          ? null
          : BottomActionBar(
              child: FilledButton.icon(
                onPressed: _busy || _selected.isEmpty ? null : _send,
                icon: const Icon(Icons.send_rounded),
                label: Text(_selected.isEmpty ? 'Select workouts' : 'Send ${_selected.length}'),
              ),
            ),
    );
  }

  String _status(WorkoutSession s) {
    if (_results[s.id] == HealthOutcome.failed) return 'Health Connect did not accept it';
    if (_covered.contains(s.id)) return 'Recorded by another app, not sent${s.avgHeartRate == null ? '' : ' · ${s.avgHeartRate} bpm'}';
    final at = s.healthExportedAt;
    final sent = at == null ? 'Not sent yet' : 'Saved to Health Connect ${DateFormat('d MMM HH:mm').format(at.toLocal())}';
    return s.avgHeartRate == null ? sent : '$sent · ${s.avgHeartRate} bpm';
  }
}
