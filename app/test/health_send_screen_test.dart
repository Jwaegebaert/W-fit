import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/providers.dart';

import 'health_service_test.dart' show FakeHealthBridge;
import 'ux_helpers.dart';

/// Settings → Samsung Health → Send workouts.
void main() {
  setUpAll(loadRealFonts);

  testWidgets('pick workouts, send them, see what Health Connect accepted', (tester) async {
    setUpDevice(tester, size: const Size(360, 640), textScale: 1.3);
    final bridge = FakeHealthBridge();
    final container = await pumpWFit(tester, health: bridge);
    await seedHistory(tester, container);
    await pumpUntil(tester, () => container.read(healthSyncProvider).setEnabled(true));
    final sessions = await pumpUntil(tester, () => container.read(repositoryProvider).completedSessions());
    expect(sessions, hasLength(3));
    bridge.refuse.add(sessions.last.id);
    // The watch recorded the middle one.
    final mid = sessions[1];
    bridge.others = [
      (
        app: 'com.sec.android.app.shealth',
        start: mid.startedAt.subtract(const Duration(minutes: 2)),
        end: mid.endedAt!.add(const Duration(minutes: 2)),
        cardio: false,
      ),
    ];

    await go(tester, '/settings/health/send');
    expect(tester.takeException(), isNull);
    expect(find.text('Select workouts'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);

    await tester.tap(find.text('Select not sent (3)'));
    await tester.pump();
    await tester.tap(find.text('Send 3'));
    await settle(tester, frames: 40);

    expect(bridge.written, [sessions.first.id]);
    expect(find.textContaining('1 workout saved, 1 workout left to your watch, 1 workout not accepted'), findsOneWidget);
    expect(find.text('Send 1'), findsOneWidget, reason: 'the refused one stays selected');
    expect(find.text('Select not sent (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unpumpWFit(tester);
  });
}
