import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../providers.dart';

/// Small app-bar icon that reflects sync state; tap to sync now.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final configured = ref.watch(apiConfigProvider).value?.isConfigured ?? false;
    final s = Theme.of(context).colorScheme;

    if (!configured) {
      return IconButton(
        tooltip: 'Offline mode – connect a backend',
        icon: Icon(Icons.cloud_off_outlined, color: s.onSurfaceVariant),
        onPressed: () => context.push('/settings/connection'),
      );
    }
    if (sync.syncing) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final hasError = sync.error != null;
    final tip = hasError
        ? 'Sync failed – changes are saved on this phone (${sync.pending} pending)'
        : sync.lastSync == null
            ? 'Not synced yet'
            : 'Synced ${DateFormat.Hm().format(sync.lastSync!)}${sync.pending > 0 ? ' · ${sync.pending} pending' : ''}';
    return IconButton(
      tooltip: tip,
      icon: Badge(
        isLabelVisible: sync.pending > 0,
        label: Text('${sync.pending}'),
        child: Icon(hasError ? Icons.cloud_sync_outlined : Icons.cloud_done_outlined,
            color: hasError ? s.error : s.primary),
      ),
      onPressed: () async {
        final ok = await ref.read(syncControllerProvider.notifier).syncNow();
        if (!context.mounted) return;
        final st = ref.read(syncControllerProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? 'Synced with W-fit cloud' : 'Sync failed: ${st.error ?? 'unknown error'}'),
        ));
      },
    );
  }
}
