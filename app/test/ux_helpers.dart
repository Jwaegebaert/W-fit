import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:wfit/data/db/database.dart';
import 'package:wfit/data/repositories/repository.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/features/dashboard/dashboard_screen.dart';
import 'package:wfit/main.dart';
import 'package:wfit/providers.dart';
import 'package:wfit/services/health_service.dart' show HealthBridge;
import 'package:wfit/router.dart';
import 'package:wfit/widgets/common.dart';

import 'helpers.dart';

/// Simulated Android edge-to-edge insets (status bar on top, 3-button navigation bar at the bottom).
const statusBarHeight = 24.0;
const navBarHeight = 48.0;

/// Pumps frames with some real time for drift without waiting for periodic timers to settle.
Future<void> settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Loads the real Roboto and MaterialIcons fonts from the Flutter SDK cache so text metrics match a phone
/// (the default test font renders every glyph 1em wide). Returns false when the SDK fonts are not found.
Future<bool> loadRealFonts() async {
  final dir = _materialFontsDir();
  if (dir == null) return false;
  final roboto = FontLoader('Roboto');
  for (final f in ['thin', 'light', 'regular', 'medium', 'bold', 'black', 'italic', 'mediumitalic', 'bolditalic']) {
    final file = File('${dir.path}${Platform.pathSeparator}roboto-$f.ttf');
    if (file.existsSync()) roboto.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(
        File('${dir.path}${Platform.pathSeparator}materialicons-regular.otf').readAsBytesSync())));
  await icons.load();
  return true;
}

Directory? _materialFontsDir() {
  final candidates = <String>[
    ?Platform.environment['FLUTTER_ROOT'],
  ];
  // flutter_tester lives in <flutter>/bin/cache/artifacts/engine/<platform>/.
  var d = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    candidates.add(d.path);
    d = d.parent;
  }
  for (final c in candidates) {
    final dir = Directory('$c${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}'
        'artifacts${Platform.pathSeparator}material_fonts');
    if (dir.existsSync()) return dir;
  }
  return null;
}

/// Configures the fake device: logical [size], [dpr], edge-to-edge insets and [textScale].
void setUpDevice(WidgetTester tester, {required Size size, double dpr = 2.75, double textScale = 1.0}) {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  const insets = FakeViewPadding(top: statusBarHeight, bottom: navBarHeight);
  tester.view.padding = FakeViewPadding(top: insets.top * dpr, bottom: insets.bottom * dpr);
  tester.view.viewPadding = FakeViewPadding(top: insets.top * dpr, bottom: insets.bottom * dpr);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
}

/// Pumps the full app on an in-memory database and returns its provider container.
Future<ProviderContainer> pumpWFit(
  WidgetTester tester, {
  AppDatabase? db,
  Widget Function(Widget app)? wrap,
  HealthBridge? health,
}) async {
  await initializeDateFormatting();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final database = db ?? AppDatabase(NativeDatabase.memory());
  const app = WFitApp();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      catalogProvider.overrideWithValue(loadTestCatalog()),
      databaseProvider.overrideWithValue(database),
      if (health != null) healthBridgeProvider.overrideWithValue(health),
    ],
    child: wrap == null ? app : wrap(app),
  ));
  router.go('/');
  await settle(tester);
  return ProviderScope.containerOf(tester.element(find.byType(WFitApp)));
}

/// Tears the app down so periodic timers (clock, rest timer) are disposed.
Future<void> unpumpWFit(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await settle(tester, frames: 5);
}

Future<void> go(WidgetTester tester, String location, {int frames = 20}) async {
  router.go(location);
  await settle(tester, frames: frames);
}

/// Runs [work] in the test zone, pumping frames (and letting real time pass for drift) until it completes.
Future<T> pumpUntil<T>(WidgetTester tester, Future<T> Function() work) async {
  T? result;
  Object? error;
  var done = false;
  work().then((v) => result = v, onError: (Object e) => error = e).whenComplete(() => done = true);
  for (var i = 0; !done && i < 2000; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (error != null) throw error!;
  if (!done) throw StateError('pumpUntil timed out');
  return result as T;
}

/// Seeds three finished workouts over the last week plus three body-weight entries.
Future<void> seedHistory(WidgetTester tester, ProviderContainer container) async {
  await pumpUntil(tester, () async {
    final repo = container.read(repositoryProvider);
    final db = container.read(databaseProvider);
    final plan = await container.read(nextPlanProvider.future);
    final blocks = Repository.decodeBlocks(plan.blocksJson);
    final catalog = container.read(catalogProvider);
    for (final (i, daysAgo) in const [(0, 9), (1, 5), (2, 2)]) {
      final id = await repo.startSession(day: DayType.parse(plan.dayType), title: plan.title);
      var order = 0;
      for (final b in blocks) {
        for (final item in b.items) {
          final weighted = catalog.exercise(item.exerciseId)?.isWeighted ?? false;
          for (var n = 1; n <= item.sets; n++) {
            await repo.logSet(
              sessionId: id,
              exerciseId: item.exerciseId,
              section: b.section,
              exerciseOrder: order,
              setNumber: n,
              weightKg: item.isTimed || !weighted ? null : (item.targetWeightKg ?? 20) + i * 2.5,
              reps: item.isTimed ? null : (item.repMax ?? 10),
              durationSeconds: item.isTimed ? item.durationSeconds : null,
              completed: true,
            );
          }
          order++;
        }
      }
      await repo.finishSession(id, rating: 4, effort: 7, notes: i == 2 ? 'Felt strong, gym was busy' : '');
      final start = DateTime.now().toUtc().subtract(Duration(days: daysAgo, hours: 1));
      await (db.update(db.workoutSessions)..where((t) => t.id.equals(id))).write(WorkoutSessionsCompanion(
        startedAt: Value(start),
        endedAt: Value(start.add(const Duration(minutes: 58))),
        durationSeconds: const Value(58 * 60),
      ));
    }
    for (final (daysAgo, kg) in [(14, 81.4), (7, 80.9), (1, 80.2)]) {
      await repo.saveBodyMetric(BodyMetricsCompanion(
        date: Value(dateKey(DateTime.now().subtract(Duration(days: daysAgo)))),
        weightKg: Value(kg),
        waistCm: Value(86 - daysAgo / 14),
      ));
    }
  });
  await settle(tester);
}

/// Height of the area not covered by the simulated system navigation bar.
double safeBottom(WidgetTester tester) => tester.view.physicalSize.height / tester.view.devicePixelRatio - navBarHeight;

/// The top edge of any sticky bottom UI (navigation bar, bottom action bar) or the system bar.
double contentLimit(WidgetTester tester) {
  var limit = safeBottom(tester);
  for (final f in [find.byType(NavigationBar), find.byType(BottomActionBar)]) {
    for (final e in f.evaluate()) {
      final top = tester.getRect(find.byWidget(e.widget)).top;
      if (top < limit) limit = top;
    }
  }
  return limit;
}

void expectFullyVisible(WidgetTester tester, Finder finder, {String? reason}) {
  expect(finder, findsWidgets, reason: reason);
  final rect = tester.getRect(finder.first);
  expect(rect.bottom, lessThanOrEqualTo(safeBottom(tester) + 0.5),
      reason: '${reason ?? finder.describeMatch(Plurality.one)} ends at ${rect.bottom}, hidden by the navigation bar');
  expect(rect.top, greaterThanOrEqualTo(statusBarHeight - 0.5), reason: '$reason is under the status bar');
}

/// Scrolls [scrollable] to its end and checks its last item is above sticky bottom UI and the system bar.
/// Set [overSheet] for modal sheets, which cover the page's sticky bars.
Future<void> expectScrollEndClear(WidgetTester tester, {Finder? scrollable, String? reason, bool overSheet = false}) async {
  final target = scrollable ?? find.byType(Scrollable).first;
  final state = tester.state<ScrollableState>(target);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  // Lazy lists may grow their extent as items get built: jump until the extent is stable.
  for (var i = 0; i < 6; i++) {
    final extent = state.position.maxScrollExtent;
    state.position.jumpTo(extent);
    await tester.pump();
    if (state.position.maxScrollExtent == extent) break;
  }
  final maxBottom = _lastItemBottom(tester.renderObject(target));
  final limit = overSheet ? safeBottom(tester) : contentLimit(tester);
  state.position.jumpTo(0);
  await tester.pump();
  expect(maxBottom, lessThanOrEqualTo(limit + 0.5),
      reason: '${reason ?? 'scroll end'}: last content ends at $maxBottom, below $limit');
}

Rect _globalRect(RenderBox box) => box.localToGlobal(Offset.zero) & box.size;

/// Bottom edge of the last laid-out item inside the first viewport below [root] (scroll padding excluded).
double _lastItemBottom(RenderObject root) {
  RenderObject? viewport;
  void findViewport(RenderObject o) {
    if (viewport != null) return;
    if (o is RenderViewportBase || o.runtimeType.toString() == '_RenderSingleChildViewport') {
      viewport = o;
      return;
    }
    o.visitChildren(findViewport);
  }

  findViewport(root);
  var maxBottom = 0.0;
  void visit(RenderObject o) {
    if (o is RenderSliverMultiBoxAdaptor) {
      final last = o.lastChild;
      if (last != null && last.hasSize) maxBottom = math.max(maxBottom, _globalRect(last).bottom);
      return;
    }
    if (o is RenderSliverSingleBoxAdapter) {
      final child = o.child;
      if (child != null && child.hasSize) maxBottom = math.max(maxBottom, _globalRect(child).bottom);
      return;
    }
    o.visitChildren(visit);
  }

  final v = viewport;
  if (v is RenderViewportBase) {
    v.visitChildren(visit);
  } else if (v != null) {
    v.visitChildren((child) {
      final content = child is RenderPadding && child.child != null ? child.child! : child;
      if (content is RenderBox && content.hasSize) maxBottom = math.max(maxBottom, _globalRect(content).bottom);
    });
  }
  return maxBottom;
}
