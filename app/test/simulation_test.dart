// 12+ week simulation of a synthetic athlete following every generated plan (docs/IMPROVEMENT-PLAN.md §6.2).
//
// Run with `flutter test test/simulation_test.dart` – the output contains a weekly effective-set table per muscle
// and the variation metrics, which help when tuning templates or targets.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/equipment_presets.dart';
import 'package:wfit/domain/limitations.dart';
import 'package:wfit/domain/muscles.dart';
import 'package:wfit/domain/plan.dart';
import 'package:wfit/domain/program.dart';
import 'package:wfit/domain/progression.dart';
import 'package:wfit/domain/rule_engine.dart';
import 'package:wfit/domain/stats.dart';
import 'package:wfit/domain/training_load.dart';

import 'helpers.dart';

/// Muscles judged at 80 % of `min` for the 4-week windows (§6.2).
const minorMuscles = {'traps', 'forearms', 'adductors', 'abductors', 'lower_back'};

class SimPlan {
  SimPlan(this.index, this.date, this.day, this.workout, this.program);
  final int index;
  final DateTime date;
  final DayType day;
  final GeneratedWorkout workout;
  final ProgramState program;

  int get week => index ~/ 3;
  List<PlanItem> get main => workout.blocks.firstWhere((b) => b.section == Section.main).items;
  Set<String> get mainIds => main.map((i) => i.exerciseId).toSet();
  Iterable<PlanItem> get allItems => workout.blocks.expand((b) => b.items);
  List<String> idsWithRole(SlotRole role) =>
      workout.roles.entries.where((e) => e.value == role).map((e) => e.key).toList();
}

class SimResult {
  SimResult(this.plans, this.sets, this.weeks, this.start);
  final List<SimPlan> plans;
  final List<LoggedSet> sets;
  final int weeks;
  final DateTime start;

  /// Effective sets per muscle for simulated week [w] (0-based).
  late final List<MuscleWeek> volume = weeklyMuscleVolume(
    sets,
    loadTestCatalog(),
    weeks: weeks,
    now: addDays(start, 7 * (weeks - 1)),
  );

  double vol(String muscle, int week) => volume[week].of(muscle);
}

/// Deterministic athlete: true strength per exercise (Epley e1RM) that grows with every exposure, stops each set
/// at the target RIR, loses a rep on later sets and occasionally misses.
class Athlete {
  Athlete(this.catalog);
  final Catalog catalog;
  final capacity = <String, double>{};
  final bodyweightReps = <String, double>{};
  final exposures = <String, int>{};
  var _setCounter = 0;

  double _base(Exercise e) {
    final legs = e.splits.contains('legs');
    var c = e.compound ? (legs ? 90.0 : 55.0) : (legs ? 45.0 : 18.0);
    if (e.equipment.contains('leg_press')) c = 160;
    if (e.equipment.contains('dumbbells') || e.equipment.contains('kettlebell')) c *= 0.45;
    if (e.unilateral) c *= 0.7;
    return c;
  }

  List<LoggedSet> perform(PlanItem item, Section section, String sessionId, DateTime date, int rir) {
    final e = catalog.exercise(item.exerciseId)!;
    final out = <LoggedSet>[];
    final n = exposures[e.id] = (exposures[e.id] ?? 0) + 1;
    for (var k = 0; k < item.sets; k++) {
      _setCounter++;
      if (item.isTimed || item.repMin == null) {
        out.add(LoggedSet(
            sessionId: sessionId, exerciseId: e.id, date: date, durationSeconds: item.durationSeconds, section: section.name));
        continue;
      }
      final lo = item.repMin!;
      final hi = item.repMax ?? lo;
      int reps;
      double? weight;
      if (e.isWeighted && (section == Section.main || section == Section.core)) {
        final cap = capacity.putIfAbsent(e.id, () => _base(e));
        weight = item.targetWeightKg ?? roundToStep(cap / (1 + (lo + 2 + rir) / 30), e.incrementKg);
        if (weight <= 0) weight = e.incrementKg;
        final toFailure = 30 * (cap / weight - 1);
        reps = math.min(hi, toFailure.floor() - rir - (k >= 2 ? 1 : 0));
      } else {
        final cap = bodyweightReps.putIfAbsent(e.id, () => hi + 1.0);
        reps = math.min(hi, cap.floor() - (section == Section.main ? rir : 0) - (k >= 2 ? 1 : 0));
      }
      if (_setCounter % 17 == 0) reps -= 3; // occasional miss
      out.add(LoggedSet(
        sessionId: sessionId,
        exerciseId: e.id,
        date: date,
        weightKg: weight,
        reps: math.max(1, reps),
        section: section.name,
      ));
    }
    // Novice adaptation with diminishing returns.
    if (capacity.containsKey(e.id)) capacity[e.id] = capacity[e.id]! * (1 + 0.03 / (1 + n / 8));
    if (bodyweightReps.containsKey(e.id)) bodyweightReps[e.id] = bodyweightReps[e.id]! + 0.4;
    return out;
  }
}

SimResult runSimulation(
  Catalog catalog, {
  int weeks = 14,
  int? skipBicepsWeek,
  int? neckPainWeek,
  int neckPainWeeks = 2,
  int sessionMinutes = 60,
}) {
  final start = DateTime(2026, 1, 5); // Monday
  final athlete = Athlete(catalog);
  final sessions = <SessionInfo>[];
  final sets = <LoggedSet>[];
  final plans = <SimPlan>[];
  final feedback = <FeedbackRecord>[];
  final equipment = EquipmentPreset.classicMachineGym.availability(catalog);
  var index = 0;
  for (var w = 0; w < weeks; w++) {
    if (neckPainWeek != null && w == neckPainWeek) {
      feedback.add(FeedbackRecord(
        id: 'neck',
        createdAt: addDays(start, 7 * w),
        kind: FeedbackKind.pain,
        region: 'neck',
        severity: 2,
        note: 'Neck hurts when loading the shoulders',
        reviewOn: addDays(start, 7 * w + 7),
      ));
    }
    if (neckPainWeek != null && w == neckPainWeek + neckPainWeeks) {
      feedback[feedback.indexWhere((f) => f.id == 'neck')] =
          feedback.firstWhere((f) => f.id == 'neck').copyWith(status: 'resolved', resolvedAt: addDays(start, 7 * w));
    }
    for (final offset in const [0, 2, 4]) {
      final date = addDays(start, 7 * w + offset);
      final day = sessions.isEmpty ? DayType.push : sessions.last.dayType.next;
      final pre = computeProgramState(sessions, now: date, day: day);
      final trends = exerciseTrends(sets, excludeSessionIds: pre.deloadSessionIds);
      final program = computeProgramState(sessions, now: date, day: day, trends: trends, catalog: catalog);
      final balance = analyzeBalance(
        weeklyMuscleVolume(sets, catalog, weeks: 8, now: date),
        sets,
        catalog,
        now: date,
        deloadWeeks: program.deloadWeekStarts,
      );
      final ctx = TrainingContext(
        catalog: catalog,
        equipmentAvailability: equipment,
        limitations: LimitationPolicy.fromFeedback(feedback, catalog, now: date),
        program: program,
        balance: balance,
        trends: trends,
        history: groupHistory(sets),
      );
      final workout = RuleEngine(ctx).generate(day: day, date: date, sessionMinutes: sessionMinutes);
      plans.add(SimPlan(index, date, day, workout, program));

      final sessionId = 's$index';
      final when = DateTime(date.year, date.month, date.day, 18);
      for (final block in workout.blocks) {
        for (final item in block.items) {
          final e = catalog.exercise(item.exerciseId)!;
          if (skipBicepsWeek == w && e.primary.contains('biceps')) continue;
          sets.addAll(athlete.perform(item, block.section, sessionId, when, program.targetRir));
        }
      }
      final performedMain = workout.blocks
          .firstWhere((b) => b.section == Section.main)
          .items
          .map((i) => i.exerciseId)
          .where((id) => !(skipBicepsWeek == w && catalog.exercise(id)!.primary.contains('biceps')))
          .toList();
      sessions.add(SessionInfo(
        id: sessionId,
        date: when,
        dayType: day,
        rating: 4,
        effort: 7,
        mainExerciseIds: performedMain,
        meta: workout.meta,
      ));
      index++;
    }
  }
  return SimResult(plans, sets, weeks, start);
}

String _f(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

void printTable(String title, SimResult r) {
  final b = StringBuffer('\n$title\nweek        ');
  for (var w = 0; w < r.weeks; w++) {
    final p = r.plans[w * 3].program;
    b.write('${w + 1}${p.deload ? 'd' : ''}'.padLeft(5));
  }
  b.writeln('   target');
  for (final m in trackedMuscleInfo) {
    b.write(m.id.padRight(12));
    for (var w = 0; w < r.weeks; w++) {
      final v = r.vol(m.id, w);
      final mark = v < m.target.min ? '-' : (v > m.target.max ? '+' : ' ');
      b.write('${_f(v)}$mark'.padLeft(5));
    }
    b.writeln('   ${_f(m.target.min)}–${_f(m.target.max)}');
  }
  b.write('minutes     ');
  for (var w = 0; w < r.weeks; w++) {
    final mins = r.plans.where((p) => p.week == w).map((p) => p.workout.estimatedMinutes).reduce(math.max);
    b.write('$mins'.padLeft(5));
  }
  b.writeln('   (max per week)');
  // ignore: avoid_print
  print(b);
}

void main() {
  final catalog = loadTestCatalog();
  const weeks = 14;
  const deficitWeek = 7; // block 2, week 2 (0-based week index)
  const neckWeek = 9;

  final base = runSimulation(catalog, weeks: weeks);
  final injected = runSimulation(catalog, weeks: weeks, skipBicepsWeek: deficitWeek, neckPainWeek: neckWeek);
  printTable('Baseline: effective sets per muscle and week ("-" below min, "+" above max, "d" deload week)', base);
  printTable('Injected: biceps skipped in week ${deficitWeek + 1}, neck pain (severity 2) weeks '
      '${neckWeek + 1}–${neckWeek + 2}', injected);

  for (final p in base.plans.take(6)) {
    // ignore: avoid_print
    print('${p.workout.meta.program}: ${p.main.map((i) => '${i.exerciseId}×${i.sets}').join(', ')} '
        '(${p.workout.estimatedMinutes} min)\n  ${p.workout.rationale.join('\n  ')}');
  }
  if (Platform.environment['WFIT_SIM_VERBOSE'] == '1') {
    for (final p in [...base.plans, ...injected.plans]) {
      // ignore: avoid_print
      print('${p.date.toIso8601String().substring(0, 10)} ${p.workout.meta.program}: '
          '${p.main.map((i) => '${i.exerciseId}×${i.sets}@${i.targetWeightKg ?? '-'}').join(', ')} '
          '| core ${p.workout.blocks.where((b) => b.section == Section.core).expand((b) => b.items).map((i) => i.exerciseId).join(', ')} '
          '(${p.workout.estimatedMinutes} min)\n  ${p.workout.rationale.join('\n  ')}');
    }
  }

  group('variation', () {
    test('consecutive same-day-type sessions share < 80 % of main exercises', () {
      final shares = <double>[];
      for (final day in DayType.values) {
        final ps = base.plans.where((p) => p.day == day).toList();
        for (var i = 1; i < ps.length; i++) {
          final a = ps[i - 1].mainIds;
          final b = ps[i].mainIds;
          final share = a.intersection(b).length / math.min(a.length, b.length);
          shares.add(share);
          expect(share, lessThan(0.8), reason: '${ps[i - 1].workout.meta.program} → ${ps[i].workout.meta.program}');
        }
      }
      // ignore: avoid_print
      print('A/B overlap: max ${(shares.reduce(math.max) * 100).round()} %, '
          'mean ${(shares.reduce((a, b) => a + b) / shares.length * 100).round()} %');
    });

    test('at least one anchor per variant persists through each block', () {
      final groups = <String, List<SimPlan>>{};
      for (final p in base.plans) {
        groups.putIfAbsent('${p.program.blockNumber}-${p.day.name}-${p.program.variant}', () => []).add(p);
      }
      for (final entry in groups.entries.where((e) => e.value.length >= 2)) {
        final anchors = entry.value.map((p) => p.idsWithRole(SlotRole.anchor).toSet()).reduce((a, b) => a.intersection(b));
        expect(anchors, isNotEmpty, reason: entry.key);
      }
    });

    test('≥ 60 % of accessory exercises change between blocks', () {
      final byBlock = <int, Set<String>>{};
      for (final p in base.plans) {
        byBlock.putIfAbsent(p.program.blockNumber, () => {}).addAll(p.idsWithRole(SlotRole.accessory));
      }
      final blocks = byBlock.keys.toList()..sort();
      expect(blocks.length, greaterThanOrEqualTo(3), reason: '$weeks weeks must cover 3 blocks');
      for (var i = 1; i < blocks.length; i++) {
        final prev = byBlock[blocks[i - 1]]!;
        final cur = byBlock[blocks[i]]!;
        final changed = cur.difference(prev).length / cur.length;
        // ignore: avoid_print
        print('Accessories block ${blocks[i - 1]} → ${blocks[i]}: ${(changed * 100).round()} % new '
            '(${cur.difference(prev).join(', ')})');
        expect(changed, greaterThanOrEqualTo(0.6), reason: 'block ${blocks[i]}: kept ${cur.intersection(prev)}');
      }
    });
  });

  group('balance', () {
    test('every 4-week window: avg ≥ min (80 % for small muscles) and ≤ 1.5 × max', () {
      for (var w = 0; w + 4 <= weeks; w++) {
        for (final m in trackedMuscleInfo) {
          final avg = List.generate(4, (i) => base.vol(m.id, w + i)).reduce((a, b) => a + b) / 4;
          final floor = minorMuscles.contains(m.id) ? 0.8 * m.target.min : m.target.min;
          expect(avg, greaterThanOrEqualTo(floor), reason: '${m.id} weeks ${w + 1}–${w + 4}: ${_f(avg)}');
          expect(avg, lessThanOrEqualTo(1.5 * m.target.max), reason: '${m.id} weeks ${w + 1}–${w + 4}: ${_f(avg)}');
        }
      }
    });

    test('no muscle below min for more than 2 consecutive weeks', () {
      for (final m in trackedMuscleInfo) {
        var run = 0;
        for (var w = 0; w < weeks; w++) {
          run = base.vol(m.id, w) < m.target.min ? run + 1 : 0;
          expect(run, lessThanOrEqualTo(2), reason: '${m.id} below ${m.target.min} in weeks ${w - run + 2}–${w + 1}');
        }
      }
    });
  });

  group('adaptivity', () {
    test('a biceps deficit raises biceps volume the next week', () {
      expect(injected.vol('biceps', deficitWeek), lessThan(base.vol('biceps', deficitWeek)));
      expect(injected.vol('biceps', deficitWeek + 1), greaterThan(base.vol('biceps', deficitWeek + 1)),
          reason: 'baseline ${_f(base.vol('biceps', deficitWeek + 1))}, '
              'after deficit ${_f(injected.vol('biceps', deficitWeek + 1))}');
      final focused = injected.plans.where((p) => p.week == deficitWeek + 1).any((p) => p.workout.focusMuscles.contains('biceps'));
      expect(focused, isTrue);
    });

    test('neck pain (severity 2) removes every neck-stress exercise until resolved', () {
      final during = injected.plans.where((p) => p.week >= neckWeek && p.week < neckWeek + 2).toList();
      expect(during, hasLength(6));
      for (final p in during) {
        for (final i in p.allItems) {
          expect(catalog.exercise(i.exerciseId)!.stress, isNot(contains('neck')),
              reason: '${p.workout.meta.program}: ${i.exerciseId}');
        }
        expect(p.workout.rationale.any((l) => l.toLowerCase().contains('neck')),
            catalog.exercises.any((e) => e.stress.contains('neck')) ? isTrue : isFalse);
      }
      final neckInBaseline = base.plans
          .where((p) => p.week >= neckWeek && p.week < neckWeek + 2)
          .expand((p) => p.allItems)
          .where((i) => catalog.exercise(i.exerciseId)!.stress.contains('neck'))
          .map((i) => i.exerciseId)
          .toSet();
      // ignore: avoid_print
      print('Neck-stress exercises removed by the limitation: ${neckInBaseline.isEmpty ? '(catalog has no neck stress tags)' : neckInBaseline.join(', ')}');
    });
  });

  group('badminton and time budget', () {
    test('≤ 1 power exercise per session, ≤ 2 per week; every plan within sessionMinutes + 5', () {
      final perWeek = <int>[];
      for (final r in [base, injected]) {
        for (var w = 0; w < weeks; w++) {
          var week = 0;
          for (final p in r.plans.where((p) => p.week == w)) {
            final power = p.main.where((i) => catalog.exercise(i.exerciseId)!.category == 'power').length;
            expect(power, lessThanOrEqualTo(1), reason: p.workout.meta.program);
            week += power;
            expect(p.workout.estimatedMinutes, lessThanOrEqualTo(65), reason: p.workout.meta.program);
          }
          expect(week, lessThanOrEqualTo(2), reason: 'week ${w + 1}');
          if (identical(r, base)) perWeek.add(week);
        }
      }
      // ignore: avoid_print
      print('Power exercises per week: $perWeek');
    });
  });

  group('progression', () {
    test('anchor target loads never decrease within a block (except deload)', () {
      final series = <String, List<double>>{};
      for (final p in base.plans.where((p) => !p.program.deload)) {
        for (final id in p.idsWithRole(SlotRole.anchor)) {
          final w = p.main.firstWhere((i) => i.exerciseId == id).targetWeightKg;
          if (w == null) continue;
          series.putIfAbsent('${p.program.blockNumber}-${p.day.name}-${p.program.variant}-$id', () => []).add(w);
        }
      }
      expect(series, isNotEmpty);
      var increases = 0;
      for (final e in series.entries) {
        for (var i = 1; i < e.value.length; i++) {
          expect(e.value[i], greaterThanOrEqualTo(e.value[i - 1]), reason: '${e.key}: ${e.value}');
          if (e.value[i] > e.value[i - 1]) increases++;
        }
      }
      expect(increases, greaterThan(0), reason: 'anchors should actually progress');
    });

    test('deload plans use fewer sets and lighter loads', () {
      final deloads = base.plans.where((p) => p.program.deload).toList();
      expect(deloads, isNotEmpty);
      for (final p in deloads) {
        expect(p.workout.meta.deload, isTrue);
        expect(p.main.every((i) => i.sets <= 3), isTrue, reason: p.workout.meta.program);
        expect(p.main.any((i) => catalog.exercise(i.exerciseId)!.category == 'power'), isFalse);
      }
    });
  });
}
