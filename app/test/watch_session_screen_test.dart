import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/features/watch/watch_sync.dart';
import 'package:wfit/features/workout/session_screen.dart';
import 'package:wfit/features/workout/workout_actions.dart';
import 'package:wfit/features/workout/workout_timer.dart';
import 'package:wfit/providers.dart';

import 'helpers.dart';
import 'ux_helpers.dart' show settle;
import 'watch_sync_test.dart' show FakeWatchBridge;

/// The live workout screen together with the watch.
void main() {
  final catalog = loadTestCatalog();

  Future<(ProviderContainer, FakeWatchBridge, String planId)> pump(
    WidgetTester tester, {
    required Widget Function(String planId) home,
    required List<PlanItem> items,
    Section section = Section.main,
  }) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(NativeDatabase.memory());
    final bridge = FakeWatchBridge();
    late String planId;
    await tester.runAsync(() async {
      planId = await Repository(db).savePlanned(
        date: DateTime.now(),
        day: DayType.push,
        title: 'Push B',
        source: 'rules',
        coachNote: '',
        blocks: [PlanBlock(section: section, items: items)],
      );
    });
    final container = ProviderContainer(overrides: [
      catalogProvider.overrideWithValue(catalog),
      databaseProvider.overrideWithValue(db),
      watchBridgeProvider.overrideWithValue(bridge),
    ]);
    await tester.runAsync(() => container.read(watchSyncProvider).start());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home(planId)),
    ));
    await settle(tester);
    addTearDown(() => tester.runAsync(() async {
          container.dispose();
          await db.close();
        }));
    return (container, bridge, planId);
  }

  testWidgets('a set logged on the watch fills and checks its row', (tester) async {
    late String sessionId;
    final (container, bridge, planId) = await pump(
      tester,
      items: [PlanItem.fromExercise(catalog.exercise('barbell-bench-press')!, targetWeightKg: 40)],
      home: (_) => const SizedBox(),
    );
    await tester.runAsync(() async => sessionId = await container
        .read(repositoryProvider)
        .startSession(plannedWorkoutId: planId, day: DayType.push, title: 'Push B'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: SessionScreen(sessionId: sessionId)),
    ));
    await settle(tester);
    expect(find.widgetWithText(TextField, '40'), findsNWidgets(3));

    bridge.deliver!(jsonEncode({
      'v': 1, 'type': 'log', 'id': 'e1', 'at': DateTime.now().millisecondsSinceEpoch, 'sessionId': sessionId,
      'order': 0, 'exerciseId': 'barbell-bench-press', 'section': 'main', 'set': 1,
      'weight': 47.5, 'reps': 6, 'seconds': null, //
    }));
    await settle(tester);
    expect(find.byTooltip('Undo set 1'), findsOneWidget);
    expect(find.widgetWithText(TextField, '47.5'), findsNWidgets(3), reason: 'later sets follow, as on the watch');
    expect(find.widgetWithText(TextField, '6'), findsOneWidget);

    // Changing the reps on the phone afterwards goes back to the watch.
    await tester.enterText(find.widgetWithText(TextField, '6'), '8');
    await settle(tester);
    expect((bridge.exercise(0)['logged'] as List).single, allOf(containsPair('reps', 8), containsPair('weight', 47.5)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening another exercise on the phone moves the watch there', (tester) async {
    late String sessionId;
    final (container, bridge, planId) = await pump(
      tester,
      items: [
        PlanItem.fromExercise(catalog.exercise('barbell-bench-press')!, targetWeightKg: 40),
        PlanItem.fromExercise(catalog.exercise('bar-dip')!),
      ],
      home: (_) => const SizedBox(),
    );
    await tester.runAsync(() async => sessionId = await container
        .read(repositoryProvider)
        .startSession(plannedWorkoutId: planId, day: DayType.push, title: 'Push B'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: SessionScreen(sessionId: sessionId)),
    ));
    await settle(tester);
    expect(bridge.last['current'], isNull);
    await tester.scrollUntilVisible(find.text('Parallel Bar Dip'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Parallel Bar Dip'));
    await settle(tester);
    expect(bridge.last['current'], 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a hold started on the phone is logged after leaving the screen', (tester) async {
    late String sessionId;
    final (container, _, planId) = await pump(
      tester,
      items: [PlanItem.fromExercise(catalog.exercise('side-plank')!).copyWith(durationSeconds: 1)],
      home: (_) => const SizedBox(),
    );
    await tester.runAsync(() async => sessionId = await container
        .read(repositoryProvider)
        .startSession(plannedWorkoutId: planId, day: DayType.push, title: 'Push B'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: SessionScreen(sessionId: sessionId)),
    ));
    await settle(tester);
    await tester.tap(find.text('Start').first);
    await tester.pump();
    expect(find.text('Side 1 · Side Plank'), findsOneWidget);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const SizedBox()));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 250));
    }
    final sets = await tester.runAsync(() => container.read(repositoryProvider).setsForSession(sessionId));
    expect(sets!.single.completed, isTrue);
    container.read(workoutTimerProvider.notifier).skip();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a warm-up timer logs its set without a rest, also after leaving the screen', (tester) async {
    late String sessionId;
    final drill = catalog.exercises.firstWhere((e) => e.category == 'warmup' && e.isTimed && !e.unilateral);
    final (container, bridge, planId) = await pump(
      tester,
      items: [PlanItem.fromExercise(drill).copyWith(sets: 1, durationSeconds: 1, restSeconds: 60)],
      section: Section.warmup,
      home: (_) => const SizedBox(),
    );
    await tester.runAsync(() async => sessionId = await container
        .read(repositoryProvider)
        .startSession(plannedWorkoutId: planId, day: DayType.push, title: 'Push B'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: SessionScreen(sessionId: sessionId)),
    ));
    await settle(tester);
    await tester.tap(find.byTooltip('Start timer: ${drill.name}'));
    await tester.pump();
    expect((bridge.last['exercises'] as List).single, allOf(containsPair('checklist', true), containsPair('rest', 0)));
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const SizedBox()));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 250));
    }
    final sets = await tester.runAsync(() => container.read(repositoryProvider).setsForSession(sessionId));
    expect((sets!.single.completed, sets.single.durationSeconds), (true, 1));
    expect(container.read(workoutTimerProvider), isNull, reason: 'no rest in a warm-up');
  });

  testWidgets('after a finished exercise the watch is free to move on by itself', (tester) async {
    late String sessionId;
    final (container, bridge, planId) = await pump(
      tester,
      items: [
        PlanItem.fromExercise(catalog.exercise('barbell-bench-press')!, targetWeightKg: 40).copyWith(sets: 1),
        PlanItem.fromExercise(catalog.exercise('bar-dip')!),
      ],
      home: (_) => const SizedBox(),
    );
    await tester.runAsync(() async => sessionId = await container
        .read(repositoryProvider)
        .startSession(plannedWorkoutId: planId, day: DayType.push, title: 'Push B'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: SessionScreen(sessionId: sessionId)),
    ));
    await settle(tester);
    container.read(openExerciseProvider.notifier).open(sessionId, 0);
    await settle(tester);
    expect(bridge.last['current'], 0);
    await tester.tap(find.byTooltip('Log set 1').first);
    await settle(tester);
    expect(bridge.last['current'], isNull, reason: 'a later tap on the same card must count as new');
    container.read(workoutTimerProvider.notifier).skip();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('starting a workout opens the watch app', (tester) async {
    final (container, bridge, planId) = await pump(
      tester,
      items: [PlanItem.fromExercise(catalog.exercise('bar-dip')!)],
      home: (_) => const SizedBox(),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => TextButton(
            onPressed: () async {
              final plan = await ref.read(repositoryProvider).plannedById(planId);
              if (!context.mounted) return;
              // No router in this test: opening the session screen itself fails after the watch was told.
              try {
                await startWorkout(context, ref, plan!);
              } catch (_) {}
            },
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await settle(tester, frames: 5);
    tester.takeException();
    expect(bridge.opened, 1);
    expect(bridge.last['sessionId'], isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
