import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/repository.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final equipment = ref.watch(equipmentProvider).value ?? const {};
    final unavailable = equipment.values.where((v) => !v).length;
    final config = ref.watch(apiConfigProvider).value;
    final sync = ref.watch(syncControllerProvider);
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final days = parseDays(profile?.trainingDays ?? '1,3,5').map((d) => dayNames[d - 1]).join(', ');

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: pagePadding(context), children: [
        const SectionTitle('Training'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Profile & schedule'),
              subtitle: Text('$days · ${profile?.sessionMinutes ?? 60} min · ${profile?.experience ?? 'beginner'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/profile'),
            ),
            ListTile(
              leading: const Icon(Icons.fitness_center),
              title: const Text('Gym equipment'),
              subtitle: Text(unavailable == 0 ? 'Everything available' : '$unavailable unavailable'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/equipment'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Exercise preferences'),
              subtitle: const Text('Like, dislike or exclude exercises'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/library'),
            ),
          ]),
        ),
        const SectionTitle('Cloud & AI'),
        Card(
          child: Column(children: [
            ListTile(
              leading: Icon(config?.isConfigured == true ? Icons.cloud_done_outlined : Icons.cloud_off_outlined),
              title: const Text('Backend connection'),
              subtitle: Text(config?.isConfigured == true
                  ? (sync.lastSync == null ? 'Connected · not synced yet' : 'Last sync ${DateFormat('d MMM HH:mm').format(sync.lastSync!)}')
                  : 'Offline mode – everything is stored on this phone'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/connection'),
            ),
            if (config?.isConfigured == true)
              ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('Sync now'),
                subtitle: Text(sync.pending == 0 ? 'All changes uploaded' : '${sync.pending} changes waiting'),
                trailing: sync.syncing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                onTap: sync.syncing
                    ? null
                    : () async {
                        final ok = await ref.read(syncControllerProvider.notifier).syncNow();
                        if (context.mounted) {
                          showSnack(context, ok ? 'Synced' : 'Sync failed: ${ref.read(syncControllerProvider).error}');
                        }
                      },
              ),
          ]),
        ),
        const SectionTitle('About'),
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('W-fit 0.1.0'),
            subtitle: Text('Your data stays on this phone and syncs to your own Azure backend when connected.'),
          ),
        ),
      ]),
    );
  }
}
