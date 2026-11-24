import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/api/api_client.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _loaded = false;
  bool _testing = false;
  bool _obscure = true;
  String? _result;
  bool _failed = false;
  Map<String, dynamic>? _usage;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _testing = true;
      _failed = false;
      _result = null;
    });
    final config = ApiConfig(baseUrl: _url.text.trim(), apiKey: _key.text.trim());
    final api = ApiClient(config);
    try {
      await api.health();
      final usage = await api.usage(); // Validates the API key too.
      await ref.read(apiConfigProvider.notifier).save(config);
      ref.read(syncControllerProvider.notifier).syncNow();
      setState(() {
        _usage = usage;
        _result = 'Connected';
      });
    } on ApiException catch (e) {
      setState(() {
        _failed = true;
        _result = e.message;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _disconnect() async {
    await ref.read(apiConfigProvider.notifier).save(ApiConfig.empty);
    _url.clear();
    _key.clear();
    setState(() {
      _failed = false;
      _result = 'Disconnected – the app keeps working offline.';
      _usage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(apiConfigProvider).value;
    if (config != null && !_loaded) {
      _loaded = true;
      _url.text = config.baseUrl;
      _key.text = config.apiKey;
      if (config.isConfigured) {
        ApiClient(config).usage().then<void>((u) {
          if (mounted) setState(() => _usage = u);
        }, onError: (_) {});
      }
    }
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud & coach')),
      body: ListView(padding: pagePadding(context), children: [
        if (config?.isConfigured == true) ...[
          const _SyncCard(),
          const SectionTitle('Connection', padding: EdgeInsets.fromLTRB(4, 20, 4, 14)),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text('Optional: backs up your data and adds the coach.', style: t.textTheme.bodyMedium),
          ),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'API URL', hintText: 'https://<your-function-app>.azurewebsites.net'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'API key',
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show key' : 'Hide key',
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _testing ? null : _connect,
          child: _testing
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect'),
        ),
        if (_result != null) ...[
          const SizedBox(height: 12),
          Text(_result!, style: TextStyle(color: _failed ? t.colorScheme.error : t.colorScheme.primary)),
        ],
        if (_usage != null) ...[
          const SectionTitle('Coach usage'),
          StatRow(children: [
            StatTile(
              label: 'calls today',
              value: '${_usage!['callsToday'] ?? 0}/${_usage!['dailyCallLimit'] ?? '–'}',
              icon: Icons.auto_awesome,
            ),
            StatTile(
              label: 'tokens this month',
              value: '${(((_usage!['tokensThisMonth'] as num?) ?? 0) / 1000).toStringAsFixed(0)}k / '
                  '${(((_usage!['monthlyTokenLimit'] as num?) ?? 0) / 1000).toStringAsFixed(0)}k',
              icon: Icons.data_usage,
            ),
          ]),
          if (_usage!['enabled'] == false)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('AI is disabled on the server.')),
        ],
        if (config?.isConfigured == true) ...[
          const SizedBox(height: 24),
          TextButton.icon(onPressed: _disconnect, icon: const Icon(Icons.link_off), label: const Text('Disconnect')),
        ],
      ]),
    );
  }
}

/// When the last sync was, what is waiting, and a button to sync now.
class _SyncCard extends ConsumerWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final s = Theme.of(context).colorScheme;
    final failed = sync.error != null;
    return Card(
      child: ListTile(
        leading: Icon(failed ? Icons.cloud_off_outlined : Icons.cloud_done_outlined, color: failed ? s.error : s.primary),
        title: Text(failed
            ? 'Last sync failed'
            : sync.lastSync == null
                ? 'Not synced yet'
                : 'Synced ${DateFormat('d MMM HH:mm').format(sync.lastSync!)}'),
        subtitle: Text(failed
            ? 'Your changes are safe on this phone (${sync.pending} waiting)'
            : sync.pending == 0
                ? 'All changes uploaded'
                : '${sync.pending} changes waiting'),
        trailing: sync.syncing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(
                onPressed: () => ref.read(syncControllerProvider.notifier).syncNow(),
                child: const Text('Sync now'),
              ),
      ),
    );
  }
}
