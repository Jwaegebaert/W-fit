import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/theme.dart';
import 'domain/catalog.dart';
import 'providers.dart';
import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android 15+ always draws edge-to-edge; opt in everywhere so system bars overlay the app consistently.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
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
    // Warm the Function host and sync once the API config has loaded.
    ref.read(apiConfigProvider.future).then((config) {
      if (!mounted) return;
      if (config.isConfigured) ref.read(apiClientProvider).health().ignore();
      ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    });
    ref.read(healthSyncProvider).catchUp();
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
      ref.read(healthSyncProvider).catchUp(); // the watch's heart rate may have arrived meanwhile
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
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemBarsStyle(Theme.of(context).brightness),
          child: child!,
        ),
      );
}

/// Transparent status and navigation bars with icons that contrast with the app surface. App bars override the
/// status bar part; the bottom bars (NavigationBar, BottomActionBar) draw their surface behind the system bar.
SystemUiOverlayStyle systemBarsStyle(Brightness brightness) {
  final icons = brightness == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: icons,
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );
}
