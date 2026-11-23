import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../providers.dart';
import '../../services/health_service.dart';
import '../../widgets/common.dart';

/// Samsung Health via Health Connect: save finished workouts and read the watch's heart rate.
class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({super.key});

  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen> with WidgetsBindingObserver {
  HealthAvailability? _availability;
  bool _enabled = false;
  bool _access = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from installing Health Connect or changing permissions in its settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final sync = ref.read(healthSyncProvider);
    final bridge = ref.read(healthBridgeProvider);
    final availability = await bridge.availability();
    final access = availability == HealthAvailability.available && await bridge.hasAccess();
    final enabled = await sync.isEnabled();
    if (mounted) {
      setState(() {
        _availability = availability;
        _access = access;
        _enabled = enabled;
      });
    }
  }

  Future<void> _toggle(bool on) async {
    final sync = ref.read(healthSyncProvider);
    setState(() => _busy = true);
    try {
      if (on) {
        final granted = _access || await ref.read(healthBridgeProvider).requestAccess();
        if (!granted) {
          if (mounted) showSnack(context, 'Health Connect access was not granted.');
          return;
        }
        await sync.setEnabled(true);
        final r = await sync.catchUp();
        if (mounted) showSnack(context, r.changed + r.failed == 0 ? 'Connected' : 'Connected · ${_describe(r)}');
      } else {
        await sync.setEnabled(false);
      }
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final r = await ref.read(healthSyncProvider).catchUp();
    if (mounted) {
      setState(() => _busy = false);
      showSnack(context, _describe(r));
    }
  }

  static String _describe(HealthSyncResult r) {
    if (r.unavailable) return 'Health Connect can\'t be used right now.';
    String n(int count) => '$count workout${count == 1 ? '' : 's'}';
    return [
      if (r.changed > 0) '${n(r.changed)} updated',
      if (r.failed > 0) 'Health Connect did not accept ${n(r.failed)}',
      if (r.changed + r.failed == 0) 'Nothing new',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final availability = _availability;
    final on = _enabled && _access;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Samsung Health'),
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: ListView(padding: pagePadding(context), children: [
        Card(
          color: t.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'W-fit talks to Samsung Health through Health Connect. Finished workouts are saved there as strength '
              'training for Samsung Health to pick up, and the heart rate your watch recorded during a workout shows up '
              'in its history. Heart rate can arrive a while after the workout.',
              style: TextStyle(color: t.colorScheme.onSecondaryContainer),
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        if (availability == null)
          const Padding(padding: EdgeInsets.all(Gap.lg), child: Center(child: CircularProgressIndicator()))
        else if (availability == HealthAvailability.unsupported)
          const EmptyState(
            icon: Icons.health_and_safety_outlined,
            title: 'Not available',
            message: 'Health Connect is not available on this device.',
          )
        else if (availability != HealthAvailability.available)
          Card(
            child: ListTile(
              leading: const Icon(Icons.system_update_alt_rounded),
              title: Text(availability == HealthAvailability.needsUpdate ? 'Update Health Connect' : 'Install Health Connect'),
              subtitle: const Text('Needed once, then come back here.'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => ref.read(healthBridgeProvider).install(),
            ),
          )
        else ...[
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.favorite_border_rounded),
              title: const Text('Connect to Samsung Health'),
              subtitle: Text(on
                  ? 'Saving workouts and reading heart rate'
                  : _enabled
                      ? 'Access was removed in Health Connect – turn on to grant it again'
                      : 'Asks Health Connect for access'),
              value: on,
              onChanged: _busy ? null : _toggle,
            ),
          ),
          if (on) ...[
            const SectionTitle('What is shared'),
            const Card(
              child: Column(children: [
                ListTile(
                  leading: Icon(Icons.upload_rounded),
                  title: Text('Workouts → Health Connect'),
                  subtitle: Text('Each finished workout as a strength-training session (title, start and end).'),
                ),
                ListTile(
                  leading: Icon(Icons.monitor_heart_outlined),
                  title: Text('Heart rate → W-fit'),
                  subtitle: Text('Read only for the time of each workout; average and max are shown in History.'),
                ),
              ]),
            ),
            const SizedBox(height: Gap.sm),
            OutlinedButton.icon(
              onPressed: _busy ? null : _syncNow,
              icon: const Icon(Icons.sync),
              label: const Text('Check recent workouts now'),
            ),
            const SizedBox(height: Gap.sm),
            Card(
              child: ListTile(
                leading: const Icon(Icons.send_rounded),
                title: const Text('Send workouts'),
                subtitle: const Text('Pick past workouts, or send one again that Samsung Health missed.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/health/send'),
              ),
            ),
          ],
          const SectionTitle('In Samsung Health'),
          Text(
            'Open Samsung Health → Settings → Health Connect and allow heart rate and exercise, both reading and '
            'writing. A workout saved before that may be skipped: send it again, then pull down on the Samsung Health '
            'home screen.',
            style: t.textTheme.bodySmall,
          ),
        ],
      ]),
    );
  }
}
