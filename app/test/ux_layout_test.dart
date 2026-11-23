import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/features/workout/workout_timer.dart';
import 'package:wfit/providers.dart';

import 'health_service_test.dart' show FakeHealthBridge;
import 'ux_helpers.dart';

/// Layout checks on small and tall Android phones in edge-to-edge mode (status bar 24dp, 3-button nav bar 48dp),
/// at normal and large text: no overflow / layout exceptions, sticky actions above the navigation bar and every
/// scrollable page able to scroll its last item clear of it.
void main() {
  setUpAll(() async {
    if (!await loadRealFonts()) debugPrint('Roboto not found in the Flutter SDK cache; using the test font.');
  });

  const sizes = {'360x640': Size(360, 640), '393x851': Size(393, 851)};
  for (final MapEntry(key: name, value: size) in sizes.entries) {
    for (final scale in [1.0, 1.3]) {
      group('$name text x$scale', () {
        testWidgets('empty states, plan, live session, swap sheet and finish', (tester) async {
          setUpDevice(tester, size: size, textScale: scale);
          final container = await pumpWFit(tester, health: FakeHealthBridge());

          Future<void> check(String screen) async {
            expect(tester.takeException(), isNull, reason: screen);
            await expectScrollEndClear(tester, reason: screen);
            expect(tester.takeException(), isNull, reason: screen);
          }

          await check('dashboard');
          // The primary action must be visible without scrolling, above the tab bar.
          expect(tester.getRect(find.text('Start workout')).bottom, lessThanOrEqualTo(contentLimit(tester)),
              reason: 'dashboard Start workout below the fold');
          expectFullyVisible(tester, find.text('Coach'), reason: 'navigation bar label');
          for (final route in ['/history', '/stats', '/coach']) {
            await go(tester, route);
            expect(tester.takeException(), isNull, reason: route);
          }
          await go(tester, '/body');
          expect(tester.takeException(), isNull, reason: 'body empty');
          await go(tester, '/');

          await tester.ensureVisible(find.text('View plan'));
          await tester.pump();
          await tester.tap(find.text('View plan'));
          await settle(tester);
          await check('plan');
          expectFullyVisible(tester, find.text('Start workout'), reason: 'plan Start workout');

          await tester.tap(find.text('Start workout'));
          await settle(tester);
          expectFullyVisible(tester, find.text('Finish'), reason: 'session Finish');
          await check('session');

          final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
          await tester.ensureVisible(find.byIcon(Icons.check).first);
          await tester.pump();
          await tester.tap(find.byIcon(Icons.check).first);
          await settle(tester);
          // Warm-ups have no rest, so start the rest timer the way a main exercise would.
          container.read(workoutTimerProvider.notifier).start('Rest · next exercise', 90);
          await settle(tester, frames: 5);
          expect(tester.takeException(), isNull, reason: 'session with rest timer');
          expectFullyVisible(tester, find.text('Finish'), reason: 'Finish with timer');
          expectFullyVisible(tester, find.byTooltip('Skip'), reason: 'timer skip');
          await check('session with rest timer');

          list.position.jumpTo(0);
          await tester.pump();
          await tester.ensureVisible(find.byTooltip('Swap exercise').first);
          await tester.pump();
          await tester.tap(find.byTooltip('Swap exercise').first);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'swap sheet');
          final sheetScroll = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first;
          await expectScrollEndClear(tester, scrollable: sheetScroll, reason: 'swap sheet', overSheet: true);
          await tester.tap(find.text('Not in my gym'));
          await settle(tester, frames: 5);
          expect(tester.takeException(), isNull, reason: 'swap sheet: not in my gym');
          Navigator.of(tester.element(find.byType(BottomSheet))).pop();
          await settle(tester, frames: 10);

          await tester.tap(find.text('Finish'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'finish sheet');
          expectFullyVisible(tester, find.text('Save workout'), reason: 'finish sheet Save workout');

          // With the keyboard open (Android then reports no bottom padding) Save must still be reachable above it.
          const keyboard = 280.0;
          final dpr = tester.view.devicePixelRatio;
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
          tester.view.padding = FakeViewPadding(top: statusBarHeight * dpr);
          await settle(tester, frames: 5);
          await tester.ensureVisible(find.text('Save workout'));
          await tester.pump();
          expect(tester.takeException(), isNull, reason: 'finish sheet with keyboard');
          expect(tester.getRect(find.text('Save workout')).bottom, lessThanOrEqualTo(size.height - keyboard),
              reason: 'Save workout hidden by the keyboard');
          tester.view.resetViewInsets();
          tester.view.padding = FakeViewPadding(top: statusBarHeight * dpr, bottom: navBarHeight * dpr);
          await settle(tester, frames: 5);
          await tester.tap(find.text('Save workout'));
          await settle(tester, frames: 30);
          expect(tester.takeException(), isNull, reason: 'summary dialog');
          expectFullyVisible(tester, find.text('Done'), reason: 'summary Done');
          await tester.tap(find.text('Done'));
          await settle(tester);

          await unpumpWFit(tester);
        });

        testWidgets('screens with training history', (tester) async {
          setUpDevice(tester, size: size, textScale: scale);
          final container = await pumpWFit(tester, health: FakeHealthBridge());
          await seedHistory(tester, container);
          await pumpUntil(tester, () => container.read(healthSyncProvider).setEnabled(true));
          final sets = await pumpUntil(tester, () => container.read(repositoryProvider).loggedSets());
          final weightedId = sets.firstWhere((s) => (s.weightKg ?? 0) > 0).exerciseId;
          final sessionId = sets.first.sessionId;

          final routes = [
            '/',
            '/history',
            '/history/$sessionId',
            '/stats',
            '/progress/$weightedId',
            '/coach',
            '/balance',
            '/body',
            '/library',
            '/exercise/$weightedId',
            '/settings',
            '/settings/profile',
            '/settings/equipment',
            '/settings/connection',
            '/settings/focus',
            '/settings/health',
            '/settings/health/send',
          ];
          for (final route in routes) {
            await go(tester, route);
            expect(tester.takeException(), isNull, reason: route);
            await expectScrollEndClear(tester, reason: route);
            expect(tester.takeException(), isNull, reason: route);
          }

          await go(tester, '/body');
          await tester.tap(find.text('Log'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'body form');
          await tester.tap(find.text('Measurements (optional)'));
          await settle(tester, frames: 5);
          await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
          await tester.pump();
          expectFullyVisible(tester, find.widgetWithText(FilledButton, 'Save'), reason: 'body form Save');
          Navigator.of(tester.element(find.byType(BottomSheet))).pop();
          await settle(tester, frames: 10);

          // Report an issue: severe pain shows the safety note; saving shows the instant plan changes.
          await go(tester, '/coach');
          await tester.ensureVisible(find.text('Report pain / tell your coach'));
          await tester.pump();
          await tester.tap(find.text('Report pain / tell your coach'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: 'report sheet');
          await tester.ensureVisible(find.text('Neck'));
          await tester.pump();
          await tester.tap(find.text('Neck'));
          await tester.ensureVisible(find.text('Severe'));
          await tester.pump();
          await tester.tap(find.text('Severe'));
          await settle(tester, frames: 5);
          expect(find.textContaining('see a doctor'), findsOneWidget);
          final reportScroll = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first;
          await expectScrollEndClear(tester, scrollable: reportScroll, reason: 'report sheet', overSheet: true);
          await tester.scrollUntilVisible(find.text('Save report'), 200, scrollable: reportScroll);
          await tester.pump();
          await tester.tap(find.text('Save report'));
          await settle(tester, frames: 30);
          expect(tester.takeException(), isNull, reason: 'report result');
          expect(find.text('Saved – thanks'), findsOneWidget);
          await expectScrollEndClear(tester, scrollable: reportScroll, reason: 'report result', overSheet: true);
          await tester.tap(find.text('Done'));
          await settle(tester, frames: 10);
          expect(find.text('Active limitations'), findsOneWidget);

          await unpumpWFit(tester);
        });
      });
    }
  }
}
