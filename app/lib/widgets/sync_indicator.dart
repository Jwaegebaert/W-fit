import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// App-bar icon that only shows up when the last sync failed; tap to try again. Settings shows the full state.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final configured = ref.watch(apiConfigProvider).value?.isConfigured ?? false;
    if (!configured || (sync.error == null && !sync.syncing)) return const SizedBox.shrink();
    if (sync.syncing) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return IconButton(
      tooltip: 'Sync failed. Your changes are saved on this phone (${sync.pending} waiting).',
      icon: Icon(Icons.cloud_off_outlined, color: Theme.of(context).colorScheme.error),
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
