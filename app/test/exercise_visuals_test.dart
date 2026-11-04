import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/features/exercises/exercise_detail_screen.dart';
import 'package:wfit/providers.dart';
import 'package:wfit/widgets/equipment_sheet.dart';
import 'package:wfit/widgets/exercise_visuals.dart';

import 'helpers.dart';
import 'ux_helpers.dart';

void main() {
  final catalog = loadTestCatalog();
  final index = jsonDecode(File('assets/exercises/index.json').readAsStringSync()) as Map<String, dynamic>;
  final media = (index['exercises'] as Map<String, dynamic>).keys.toSet();

  ExerciseKind kindOf(String id) {
    final e = catalog.exercise(id);
    expect(e, isNotNull, reason: 'catalog has $id');
    return ExerciseKind.of(e!, catalog);
  }

  group('ExerciseKind.of', () {
    test('classifies by equipment with a clear priority', () {
      expect(kindOf('machine-chest-press'), ExerciseKind.machine);
      expect(kindOf('smith-squat'), ExerciseKind.machine);
      expect(kindOf('leg-press'), ExerciseKind.machine);
      expect(kindOf('dumbbell-bench-press'), ExerciseKind.dumbbell);
      expect(kindOf('cable-triceps-pushdown'), ExerciseKind.cable);
      expect(kindOf('seated-cable-row'), ExerciseKind.machine);
      expect(kindOf('barbell-back-squat'), ExerciseKind.barbell);
      expect(kindOf('ez-bar-curl'), ExerciseKind.barbell);
      expect(kindOf('kettlebell-goblet-squat'), ExerciseKind.kettlebell);
      expect(kindOf('band-pull-apart'), ExerciseKind.band);
      expect(kindOf('bench-dip'), ExerciseKind.bench);
      expect(kindOf('hamstring-stretch'), ExerciseKind.mobility);
      expect(kindOf('bench-hamstring-stretch'), ExerciseKind.mobility);
      expect(kindOf('cat-cow'), ExerciseKind.mobility);
      expect(kindOf('bike-easy'), ExerciseKind.cardio);
      expect(kindOf('lateral-shuffle'), ExerciseKind.cardio);
      expect(kindOf('box-jump'), ExerciseKind.plyo);
      expect(kindOf('medicine-ball-slam'), ExerciseKind.plyo);
      expect(kindOf('push-up'), ExerciseKind.bodyweight);
      expect(kindOf('hanging-knee-raise'), ExerciseKind.bodyweight);
    });

    test('every exercise gets a kind', () {
      for (final e in catalog.exercises) {
        expect(ExerciseKind.of(e, catalog), isA<ExerciseKind>());
      }
    });
  });

  group('visual assets', () {
    test('every equipment id has an illustration and every kind an icon', () {
      for (final eq in catalog.equipment) {
        expect(File('assets/equipment/${eq.id}.svg').existsSync(), isTrue, reason: eq.id);
      }
      for (final kind in ExerciseKind.values) {
        expect(File(kind.asset).existsSync(), isTrue, reason: kind.asset);
      }
    });

    test('every media index entry is a catalog exercise with both frames on disk', () {
      expect(media, isNotEmpty);
      for (final id in media) {
        expect(catalog.exercise(id), isNotNull, reason: '$id is not in the catalog');
        for (final i in [0, 1]) {
          expect(File(ExerciseMediaIndex.frame(id, i)).existsSync(), isTrue, reason: '$id frame $i');
        }
      }
    });
  });

  group('exercise detail at 360x640, text x1.3', () {
    setUpAll(() async {
      if (!await loadRealFonts()) debugPrint('Roboto not found in the Flutter SDK cache; using the test font.');
    });

    for (final id in ['barbell-back-squat', 'goblet-squat', 'lateral-lunge', 'hamstring-stretch']) {
      testWidgets(id, (tester) async {
        setUpDevice(tester, size: const Size(360, 640), textScale: 1.3);
        await pumpWFit(tester);
        await go(tester, '/exercise/$id');
        expect(find.byType(ExerciseDetailScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.byType(ExerciseDemo), findsOneWidget);
        expect(find.text('No demo photo yet — use Watch a demo'), media.contains(id) ? findsNothing : findsOneWidget);
        await expectScrollEndClear(tester, reason: id);
        expect(tester.takeException(), isNull);
        await unpumpWFit(tester);
      });
    }

    testWidgets('reduced motion: demo does not auto-play', (tester) async {
      setUpDevice(tester, size: const Size(360, 640), textScale: 1.3);
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      await pumpWFit(tester);
      await go(tester, '/exercise/barbell-back-squat');
      expect(find.byTooltip('Play demo'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
      await tester.tap(find.byTooltip('Show end position'));
      await tester.pump();
      expect(find.text('End'), findsOneWidget);
      await unpumpWFit(tester);
    });

    testWidgets('equipment card opens the equipment sheet and toggles availability', (tester) async {
      setUpDevice(tester, size: const Size(360, 640), textScale: 1.3);
      final container = await pumpWFit(tester);
      await go(tester, '/exercise/barbell-back-squat');
      final card = find.text('Squat rack / power rack');
      await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      await tester.tap(card);
      await settle(tester);
      expect(find.byType(EquipmentSheet), findsOneWidget);
      expect(find.textContaining('Used in'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final sheetScroll = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first;
      await expectScrollEndClear(tester, scrollable: sheetScroll, reason: 'equipment sheet');

      await tester.tap(find.text('Available in my gym'));
      await settle(tester);
      expect(container.read(equipmentProvider).value?['squat_rack'], isFalse);
      expect(find.text('Workouts and suggestions skip it'), findsOneWidget);
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await settle(tester, frames: 10);
      expect(find.text('Not in your gym'), findsOneWidget);
      await unpumpWFit(tester);
    });
  });

  group('screenshots', skip: !const bool.fromEnvironment('SCREENSHOTS'), () {
    setUpAll(() async {
      await loadRealFonts();
    });

    final outDir = Directory('${Platform.environment['TEMP'] ?? Directory.systemTemp.path}'
        '${Platform.pathSeparator}wfit-shots${Platform.pathSeparator}detail');
    const shotKey = ValueKey('shot');

    Future<void> shot(WidgetTester tester, String name) async {
      await settle(tester, frames: 6);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        outDir.createSync(recursive: true);
        File('${outDir.path}${Platform.pathSeparator}$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    Widget wrap(Widget app) => RepaintBoundary(
          key: shotKey,
          child: Stack(textDirection: TextDirection.ltr, children: [
            app,
            // Simulated translucent navigation bar so clearance is visible.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: navBarHeight,
              child: IgnorePointer(child: ColoredBox(color: Color(0x33000000))),
            ),
          ]),
        );

    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';
      for (final id in ['barbell-back-squat', 'goblet-squat', 'bulgarian-split-squat']) {
        testWidgets('$id $mode', (tester) async {
          setUpDevice(tester, size: const Size(393, 851));
          tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
          await pumpWFit(tester, wrap: wrap);
          await go(tester, '/exercise/$id');
          final context = tester.element(find.byType(ExerciseDetailScreen));
          await tester.runAsync(() async {
            for (final i in [0, 1]) {
              await precacheImage(AssetImage(ExerciseMediaIndex.frame(id, i)), context, onError: (_, _) {});
            }
          });
          await shot(tester, '${id}_${mode}_1top');
          final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
          list.position.jumpTo(list.position.maxScrollExtent / 2);
          await shot(tester, '${id}_${mode}_2mid');
          list.position.jumpTo(list.position.maxScrollExtent);
          await shot(tester, '${id}_${mode}_3end');

          if (id == 'barbell-back-squat') {
            final card = find.text('Squat rack / power rack');
            await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
            await tester.tap(card);
            await settle(tester, frames: 30);
            await shot(tester, 'equipment_sheet_$mode');
            Navigator.of(tester.element(find.byType(BottomSheet))).pop();
            await settle(tester, frames: 10);
            tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
            await tester.pump();
            await tester.tap(find.byTooltip('Full screen'));
            await settle(tester, frames: 20);
            await shot(tester, 'fullscreen_$mode');
            await go(tester, '/library');
            await shot(tester, 'library_$mode');
          }
          await unpumpWFit(tester);
        });
      }
    }
  });
}
