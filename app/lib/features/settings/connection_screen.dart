import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  Map<String, dynamic>? _usage;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _test({bool save = false}) async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final config = ApiConfig(baseUrl: _url.text.trim(), apiKey: _key.text.trim());
    final api = ApiClient(config);
    try {
      await api.health();
      final usage = await api.usage(); // Validates the API key too.
      if (save) {
        await ref.read(apiConfigProvider.notifier).save(config);
        ref.read(syncControllerProvider.notifier).syncNow();
      }
      setState(() {
        _usage = usage;
        _result = save ? 'Connected and saved. Syncing…' : 'Connection OK';
      });
    } on ApiException catch (e) {
      setState(() => _result = e.message);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _disconnect() async {
    await ref.read(apiConfigProvider.notifier).save(ApiConfig.empty);
    _url.clear();
    _key.clear();
    setState(() {
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
      appBar: AppBar(title: const Text('Backend connection')),
      body: ListView(padding: pagePadding(context), children: [
        Text(
          'W-fit works fully offline. Connect your Azure backend to back up your data and unlock the AI coach.',
          style: t.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
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
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton(onPressed: _testing ? null : () => _test(), child: const Text('Test')),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: _testing ? null : () => _test(save: true),
              child: _testing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save & connect'),
            ),
          ),
        ]),
        if (_result != null) ...[
          const SizedBox(height: 12),
          Text(_result!, style: TextStyle(color: _result!.startsWith('Conn') ? t.colorScheme.primary : t.colorScheme.error)),
        ],
        if (_usage != null) ...[
          const SectionTitle('AI usage'),
          StatRow(children: [
            StatTile(
              label: 'AI calls today',
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
