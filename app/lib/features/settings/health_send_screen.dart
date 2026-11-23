import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../providers.dart';
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

  /// Session id → accepted by Health Connect, for the workouts sent from this screen.
  final _results = <String, bool>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await ref.read(repositoryProvider).completedSessions();
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _send() async {
    final chosen = [for (final s in _sessions!) if (_selected.contains(s.id)) s];
    setState(() {
      _busy = true;
      _results.clear();
    });
    final r = await ref.read(healthSyncProvider).send(chosen, onResult: (id, saved) {
      if (mounted) setState(() => _results[id] = saved);
    });
    await _load();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.removeWhere((id) => _results[id] == true); // failed ones stay selected for another try
    });
    String n(int count) => '$count workout${count == 1 ? '' : 's'}';
    showSnack(
      context,
      r.unavailable
          ? 'Health Connect can\'t be used right now.'
          : r.failed == 0
              ? '${n(r.changed)} saved to Health Connect'
              : '${n(r.changed)} saved, ${n(r.failed)} not accepted',
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
    final unsent = [for (final s in sessions) if (s.healthExportedAt == null) s.id];
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
                    'Sends to Health Connect; whether a workout then shows up is up to Samsung Health. Skip workouts you '
                    'also recorded on your watch, or Samsung Health may list them twice.',
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
                        true => Icon(Icons.check_circle, color: t.colorScheme.primary),
                        false => Icon(Icons.error_outline, color: t.colorScheme.error),
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
    if (_results[s.id] == false) return 'Health Connect did not accept it';
    final at = s.healthExportedAt;
    final sent = at == null ? 'Not sent yet' : 'Saved to Health Connect ${DateFormat('d MMM HH:mm').format(at.toLocal())}';
    return s.avgHeartRate == null ? sent : '$sent · ${s.avgHeartRate} bpm';
  }
}
