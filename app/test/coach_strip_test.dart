import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/features/workout/coach_strip.dart';

import 'helpers.dart';

/// The exercise-card guidance: one row of chips and one line, details only on tap.
void main() {
  final catalog = loadTestCatalog();
  final loads = LoadModel(catalog);
  final squat = catalog.exercise('barbell-back-squat')!;
  const advice = ProgressionAdvice(
    weightKg: 42.5,
    targetReps: 5,
    message: 'All sets hit 8 reps last time – add 2.5 kg.',
    lastSummary: '40 kg × 8, 8, 8',
  );

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(width: 340, child: child))),
      );

  testWidgets('shows Last / Today / Aim and the advice on one line; details only after a tap', (tester) async {
    await pump(
      tester,
      CoachStrip(item: PlanItem.fromExercise(squat), exercise: squat, loads: loads, advice: advice),
    );
    expect(find.textContaining('40 kg × 8, 8, 8'), findsOneWidget);
    expect(find.textContaining('42.5 kg plates (+20 bar)'), findsOneWidget);
    expect(find.textContaining('5 reps'), findsOneWidget);
    expect(find.text(advice.message), findsOneWidget);
    expect(find.text(squat.tip!), findsNothing, reason: 'tip is behind the tap');
    expect(find.text('Coach'), findsNothing);

    await tester.tap(find.text(advice.message));
    await tester.pump();
    expect(find.text(squat.tip!), findsOneWidget);
  });

  testWidgets('a coach-written note leads, with a Coach badge and the change reason on expand', (tester) async {
    final item = PlanItem.fromExercise(squat).copyWith(notes: 'Lighter today, knees felt sore');
    await pump(
      tester,
      CoachStrip(
        item: item,
        exercise: squat,
        loads: loads,
        advice: advice,
        fromCoach: true,
        change: const PlanChange(from: 'leg-press', to: 'barbell-back-squat', reason: 'leg press is broken'),
      ),
    );
    expect(find.text('Coach'), findsOneWidget);
    expect(find.text('Lighter today, knees felt sore'), findsOneWidget);
    expect(find.text(advice.message), findsNothing);

    await tester.tap(find.text('Lighter today, knees felt sore'));
    await tester.pump();
    expect(find.text(advice.message), findsOneWidget);
    expect(find.text('Changed: leg press is broken'), findsOneWidget);
  });

  testWidgets('warm-up / cool-down items show only the note line', (tester) async {
    final stretch = catalog.exercises.firstWhere((e) => e.category == 'cooldown' && e.tip != null);
    await pump(
      tester,
      CoachStrip(item: PlanItem.fromExercise(stretch), exercise: stretch, loads: loads, showProgress: false),
    );
    expect(find.textContaining('Aim'), findsNothing);
    expect(find.text(stretch.tip!), findsOneWidget);
  });
}
