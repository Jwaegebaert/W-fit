import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/features/workout/coach_strip.dart';

import 'helpers.dart';

/// The exercise-card guidance: one row of chips and one line, details only on tap.
void main() {
  final catalog = loadTestCatalog();
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

  testWidgets('one line with last time and the aim; advice and tip only after a tap', (tester) async {
    await pump(
      tester,
      CoachStrip(item: PlanItem.fromExercise(squat), exercise: squat, advice: advice),
    );
    expect(find.text('Last 40 kg × 8, 8, 8 · aim 5 reps'), findsOneWidget);
    expect(find.text(advice.message), findsNothing, reason: 'advice is behind the tap');
    expect(find.text(squat.tip!), findsNothing, reason: 'tip is behind the tap');
    expect(find.text('Coach'), findsNothing);

    await tester.tap(find.textContaining('Last 40 kg'));
    await tester.pump();
    expect(find.text(advice.message), findsOneWidget);
    expect(find.text(squat.tip!), findsOneWidget);
  });

  testWidgets('a coach-written note leads, with a Coach badge and the change reason on expand', (tester) async {
    final item = PlanItem.fromExercise(squat).copyWith(notes: 'Lighter today, knees felt sore');
    await pump(
      tester,
      CoachStrip(
        item: item,
        exercise: squat,
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

  testWidgets('a first time shows the aim and the hint for choosing a weight', (tester) async {
    const first = ProgressionAdvice(message: 'First time: choose a weight you could lift for ~3 more reps.');
    await pump(tester, CoachStrip(item: PlanItem.fromExercise(squat), exercise: squat, advice: first));
    expect(find.textContaining('Aim ${squat.repMax} reps'), findsOneWidget);
    expect(find.text(first.message), findsOneWidget);
  });
}
