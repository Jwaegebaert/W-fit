import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/main.dart';
import 'package:wfit/providers.dart';

import 'helpers.dart';

/// Pumps frames with some real time for drift without waiting for periodic timers (clock, rest timer) to settle.
Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('core flow: plan, start, log set, finish, history, stats, coach', (tester) async {
    await initializeDateFormatting();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        catalogProvider.overrideWithValue(loadTestCatalog()),
        databaseProvider.overrideWithValue(db),
      ],
      child: const WFitApp(),
    ));
    await settle(tester);

    debugPrint('STEP dashboard');
    expect(find.byKey(const ValueKey('start-workout')), findsOneWidget);

    debugPrint('STEP plan preview');
    await tester.tap(find.text('View plan'));
    await settle(tester);
    expect(find.text('Warm-up'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Cool-down'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Cool-down'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);

    debugPrint('STEP start workout');
    await tester.tap(find.byKey(const ValueKey('start-workout')));
    await settle(tester);
    expect(find.text('Finish'), findsOneWidget);

    debugPrint('STEP log set');
    await tester.tap(find.byIcon(Icons.check).first);
    await settle(tester);
    final sets = await tester.runAsync(() => db.select(db.setLogs).get());
    expect(sets!.where((s) => s.completed), isNotEmpty);

    debugPrint('STEP finish');
    await tester.tap(find.text('Finish'));
    await settle(tester);
    await tester.tap(find.text('Save workout'));
    await settle(tester, frames: 30);
    expect(find.text('Workout saved'), findsOneWidget);

    debugPrint('STEP progress');
    await tester.tap(find.text('Progress'));
    await settle(tester);
    expect(find.text('Consistency'), findsOneWidget);

    debugPrint('STEP history');
    await tester.tap(find.text('All'));
    await settle(tester);
    expect(find.text('Workouts'), findsOneWidget);
    expect(find.textContaining('1 set'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);

    debugPrint('STEP balance');
    await tester.scrollUntilVisible(find.text('Muscle balance'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Muscle balance'));
    await settle(tester);
    expect(find.text('Last 8 weeks'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);

    debugPrint('STEP coach');
    await tester.tap(find.text('Coach'));
    await settle(tester);
    expect(find.text('Do next'), findsOneWidget);

    debugPrint('STEP done');
    await tester.pumpWidget(const SizedBox());
    await settle(tester, frames: 5);
  });
}
