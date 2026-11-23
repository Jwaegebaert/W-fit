import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/features/workout/session_screen.dart';
import 'package:wfit/features/workout/workout_timer.dart';
import 'package:wfit/providers.dart';

import 'health_service_test.dart' show FakeHealthBridge;
import 'ux_helpers.dart';

/// Visual review harness: writes PNGs of every screen (with simulated Android system bars drawn on top) to
/// `%TEMP%\wfit-shots\`. Skipped unless run with `flutter test test/screenshots_test.dart --dart-define=SCREENSHOTS=true`.
const _enabled = bool.fromEnvironment('SCREENSHOTS');

void main() {
  setUpAll(() async {
    if (_enabled) await loadRealFonts();
  });

  final outDir = Directory('${Platform.environment['TEMP'] ?? Directory.systemTemp.path}${Platform.pathSeparator}wfit-shots');

  for (final (prefix, size, scale, dark) in const [
    ('393x851', Size(393, 851), 1.0, false),
    ('360x640-x1.3', Size(360, 640), 1.3, false),
    ('393x851-dark', Size(393, 851), 1.0, true),
  ]) {
    testWidgets('screenshots $prefix', skip: !_enabled, (tester) async {
      setUpDevice(tester, size: size, textScale: scale);
      if (dark) tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      outDir.createSync(recursive: true);
      final boundaryKey = GlobalKey();
      final container = await pumpWFit(
        tester,
        health: FakeHealthBridge(),
        wrap: (app) => RepaintBoundary(
          key: boundaryKey,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(children: [app, const Positioned.fill(child: IgnorePointer(child: _FakeSystemBars()))]),
          ),
        ),
      );

      Future<void> shot(String name) async {
        await settle(tester, frames: 6);
        final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('${outDir.path}${Platform.pathSeparator}$prefix-$name.png').writeAsBytesSync(png!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> shotEnd(String name, {Finder? scrollable}) async {
        final state = tester.state<ScrollableState>(scrollable ?? find.byType(Scrollable).first);
        state.position.jumpTo(state.position.maxScrollExtent);
        await tester.pump();
        state.position.jumpTo(state.position.maxScrollExtent);
        await shot(name);
        state.position.jumpTo(0);
        await tester.pump();
      }

      await shot('01-dashboard-empty');
      if (!dark) {
        for (final (route, name) in [('/history', '02-history-empty'), ('/stats', '03-stats-empty'), ('/body', '04-body-empty')]) {
          await go(tester, route);
          await shot(name);
        }
        await go(tester, '/');
      }

      await tester.ensureVisible(find.text('View plan'));
      await tester.pump();
      await tester.tap(find.text('View plan'));
      await settle(tester);
      await shot('05-plan');
      await shotEnd('06-plan-end');

      await tester.tap(find.text('Start workout'));
      await settle(tester);
      await shot('07-session');
      // Open the first main exercise (after the warm-up block) to see the set-logging rows.
      await tester.scrollUntilVisible(find.text('Workout'), 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      final workoutTop = tester.getRect(find.text('Workout')).bottom;
      final mainCard = find.byType(ExerciseCard).evaluate().map((e) => find.byKey(e.widget.key!)).firstWhere(
          (f) => tester.getRect(f).top > workoutTop);
      await tester.ensureVisible(mainCard);
      await tester.pump();
      await tester.tap(find.descendant(of: mainCard, matching: find.byType(InkWell)).first);
      await settle(tester, frames: 10);
      await tester.ensureVisible(mainCard);
      await shot('07b-session-main-exercise');
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
      container.read(workoutTimerProvider.notifier).start('Rest · next exercise', 90);
      await shot('08-session-timer');
      await shotEnd('09-session-end');
      if (!dark) {
        await tester.tap(find.byTooltip('Swap exercise').first);
        await settle(tester);
        await shot('10-swap-sheet');
        await shotEnd('11-swap-sheet-end',
            scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first);
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await settle(tester, frames: 10);
      }
      await tester.tap(find.text('Finish'));
      await settle(tester);
      await shot('12-finish-sheet');
      await tester.tap(find.text('Save workout'));
      await settle(tester, frames: 30);
      await shot('13-summary');
      await tester.tap(find.text('Done'));
      await settle(tester);

      await seedHistory(tester, container);
          await pumpUntil(tester, () => container.read(healthSyncProvider).setEnabled(true));
      final sets = await pumpUntil(tester, () => container.read(repositoryProvider).loggedSets());
      final weightedId = sets.firstWhere((s) => (s.weightKg ?? 0) > 0).exerciseId;
      final sessionId = sets.first.sessionId;
      final routes = [
        ('/', '20-dashboard'),
        ('/history', '21-history'),
        ('/history/$sessionId', '22-session-detail'),
        ('/stats', '23-stats'),
        ('/progress/$weightedId', '24-exercise-progress'),
        ('/coach', '25-coach'),
        ('/balance', '25b-balance'),
        ('/body', '26-body'),
        ('/library', '27-library'),
        ('/exercise/$weightedId', '28-exercise-detail'),
        ('/settings', '29-settings'),
        ('/settings/profile', '30-profile'),
        ('/settings/equipment', '31-equipment'),
        ('/settings/connection', '32-connection'),
        ('/settings/focus', '32b-focus'),
        ('/settings/health', '32c-health'),
        ('/settings/health/send', '32d-health-send'),
      ];
      for (final (route, name) in dark ? routes.take(4) : routes) {
        await go(tester, route);
        await shot(name);
        await shotEnd('$name-end');
      }
      if (!dark) {
        await go(tester, '/body');
        await tester.tap(find.text('Log'));
        await settle(tester);
        await tester.tap(find.text('Measurements (optional)'));
        await shot('33-body-form');
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await settle(tester, frames: 10);

        await go(tester, '/coach');
        await tester.ensureVisible(find.text('Report pain / tell your coach'));
        await tester.pump();
        await tester.tap(find.text('Report pain / tell your coach'));
        await settle(tester);
        await tester.ensureVisible(find.text('Neck'));
        await tester.pump();
        await tester.tap(find.text('Neck'));
        await shot('34-report-sheet');
        await shotEnd('35-report-sheet-end',
            scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first);
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await settle(tester, frames: 10);
      }

      await unpumpWFit(tester);
    });
  }
}

/// Semi-transparent stand-ins for the Android status bar and 3-button navigation bar.
class _FakeSystemBars extends StatelessWidget {
  const _FakeSystemBars();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontFamily: 'Roboto', fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600);
    const icon = Color(0xDDFFFFFF);
    return Column(children: [
      Container(
        height: statusBarHeight,
        color: const Color(0x55000000),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: const Row(children: [
          Text('9:41', style: style),
          Spacer(),
          Icon(Icons.signal_cellular_alt, size: 14, color: icon),
          SizedBox(width: 4),
          Icon(Icons.battery_full, size: 14, color: icon),
        ]),
      ),
      const Spacer(),
      Container(
        height: navBarHeight,
        color: const Color(0x55000000),
        child: const Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          Icon(Icons.menu, size: 22, color: icon),
          Icon(Icons.circle_outlined, size: 22, color: icon),
          Icon(Icons.arrow_back_ios_new, size: 18, color: icon),
        ]),
      ),
    ]);
  }
}
