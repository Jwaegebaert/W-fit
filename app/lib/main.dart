import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/theme.dart';
import 'domain/catalog.dart';
import 'providers.dart';
import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  final catalog = await Catalog.load();
  runApp(ProviderScope(
    overrides: [catalogProvider.overrideWithValue(catalog)],
    child: const WFitApp(),
  ));
}

class WFitApp extends ConsumerStatefulWidget {
  const WFitApp({super.key});

  @override
  ConsumerState<WFitApp> createState() => _WFitAppState();
}

class _WFitAppState extends ConsumerState<WFitApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Sync once the API config has loaded.
    ref.read(apiConfigProvider.future).then((_) {
      if (mounted) ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'W-fit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        routerConfig: router,
      );
}
