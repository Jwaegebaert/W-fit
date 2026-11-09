import 'package:flutter_test/flutter_test.dart';
import 'package:wfit/domain/catalog.dart';
import 'package:wfit/domain/limitations.dart';
import 'package:wfit/domain/stats.dart';

Exercise ex(String id, {List<String> primary = const ['chest'], List<String> stress = const []}) => Exercise(
      id: id,
      name: id[0].toUpperCase() + id.substring(1),
      category: 'strength',
      splits: const ['push'],
      primary: primary,
      secondary: const [],
      pattern: 'x',
      equipment: const [],
      difficulty: 1,
      compound: false,
      unilateral: false,
      isTimed: false,
      sets: 3,
      repMin: 8,
      repMax: 12,
      rest: 60,
      incrementKg: 2.5,
      instructions: const [],
      stress: stress,
    );

final catalog = Catalog(version: 3, equipment: const [], exercises: [
  ex('shrug', primary: ['traps'], stress: ['neck']),
  ex('ohp', primary: ['front_delts'], stress: ['neck', 'shoulder', 'lower_back']),
  ex('chest-press', stress: ['shoulder']),
  ex('face-pull', primary: ['rear_delts']),
  ex('farmer-hold', primary: ['traps', 'forearms']),
  ex('curl', primary: ['biceps'], stress: ['elbow']),
  ex('leg-press', primary: ['quads'], stress: ['knee', 'hip']),
]);

final now = DateTime(2026, 11, 9);

FeedbackRecord fb(
  String id,
  FeedbackKind kind, {
  String? region,
  int? severity,
  String? exerciseId,
  int daysAgo = 2,
  String status = 'active',
  bool deleted = false,
  String note = '',
}) =>
    FeedbackRecord(
      id: id,
      createdAt: addDays(now, -daysAgo),
      kind: kind,
      region: region,
      severity: severity,
      exerciseId: exerciseId,
      status: status,
      deleted: deleted,
      note: note,
      reviewOn: FeedbackRecord.defaultReviewOn(kind, addDays(now, -daysAgo)),
    );

LimitationPolicy policy(List<FeedbackRecord> records) => LimitationPolicy.fromFeedback(records, catalog, now: now);
Exercise e(String id) => catalog.exercise(id)!;

void main() {
  test('empty policy changes nothing', () {
    const p = LimitationPolicy.empty();
    expect(p.isEmpty, isTrue);
    for (final x in catalog.exercises) {
      expect(p.excludes(x), isFalse);
      expect(p.penalty(x), 0);
      expect(p.reason(x), isNull);
    }
    expect(p.toBrief(now: now), {'limitations': [], 'exerciseFeedback': []});
  });

  group('region pain / discomfort', () {
    test('severity 1: strong penalty, not excluded', () {
      final p = policy([fb('n', FeedbackKind.pain, region: 'neck', severity: 1)]);
      expect(p.excludes(e('shrug')), isFalse);
      expect(p.penalty(e('shrug')), LimitationPolicy.mildRegionPenalty);
      expect(p.penalty(e('face-pull')), 0);
      expect(p.reason(e('ohp')), 'Limits neck load (mild neck pain)');
    });

    test('severity 2: exercises stressing the region are excluded', () {
      final p = policy([fb('n', FeedbackKind.pain, region: 'neck', severity: 2, note: 'stiff neck')]);
      expect(p.excludes(e('shrug')), isTrue);
      expect(p.excludes(e('ohp')), isTrue);
      expect(p.excludes(e('farmer-hold')), isFalse, reason: 'direct traps work without neck stress is fine at severity 2');
      expect(p.excludes(e('chest-press')), isFalse);
      expect(p.reason(e('shrug')), 'Avoids neck load (neck pain)');
      expect(p.regionSeverity, {'neck': 2});
      final l = p.activeLimitations.single;
      expect(l.region, 'neck');
      expect(l.severity, 2);
      expect(l.effect, 'Excludes exercises that load the neck');
      expect(l.affectedExercises, 2);
    });

    test('severity 3: related muscles are excluded too', () {
      final p = policy([fb('n', FeedbackKind.pain, region: 'neck', severity: 3)]);
      expect(p.excludes(e('farmer-hold')), isTrue);
      expect(p.reason(e('farmer-hold')), 'Avoids direct traps work (severe neck pain)');
      expect(p.excludedMuscles, {'traps'});
      expect(p.activeLimitations.single.effect, contains('direct traps work'));
    });

    test('default severities: pain → 2, discomfort → 1; the highest active severity wins', () {
      expect(policy([fb('a', FeedbackKind.pain, region: 'elbow')]).excludes(e('curl')), isTrue);
      expect(policy([fb('a', FeedbackKind.discomfort, region: 'elbow')]).excludes(e('curl')), isFalse);
      final both = policy([
        fb('a', FeedbackKind.discomfort, region: 'knee', severity: 1, daysAgo: 5),
        fb('b', FeedbackKind.pain, region: 'knee', severity: 2, daysAgo: 1),
      ]);
      expect(both.regionSeverity, {'knee': 2});
      expect(both.excludes(e('leg-press')), isTrue);
      expect(both.activeLimitations.map((l) => l.id).toList(), ['b', 'a'], reason: 'newest first');
    });

    test('resolved and deleted entries are ignored', () {
      final p = policy([
        fb('a', FeedbackKind.pain, region: 'neck', severity: 3, status: 'resolved'),
        fb('b', FeedbackKind.pain, region: 'neck', severity: 3, deleted: true),
      ]);
      expect(p.isEmpty, isTrue);
      expect(p.excludes(e('shrug')), isFalse);
    });
  });

  group('exercise-specific feedback', () {
    test('pain excludes the exercise until resolved', () {
      final p = policy([fb('a', FeedbackKind.pain, exerciseId: 'chest-press', daysAgo: 60)]);
      expect(p.excludes(e('chest-press')), isTrue);
      expect(p.reason(e('chest-press')), 'Excluded: Chest-press caused pain');
      expect(p.activeLimitations.single.effect, 'Excludes Chest-press');
    });

    test('discomfort pauses the exercise for 4 weeks, then only penalises it', () {
      final recent = policy([fb('a', FeedbackKind.discomfort, exerciseId: 'chest-press', daysAgo: 10)]);
      expect(recent.excludes(e('chest-press')), isTrue);
      expect(recent.reason(e('chest-press')), contains('Paused for 4 weeks'));
      final old = policy([fb('a', FeedbackKind.discomfort, exerciseId: 'chest-press', daysAgo: 30)]);
      expect(old.excludes(e('chest-press')), isFalse);
      expect(old.penalty(e('chest-press')), LimitationPolicy.discomfortPenalty);
    });

    test('an entry with region and exercise applies both rules', () {
      final p = policy([fb('a', FeedbackKind.pain, region: 'shoulder', severity: 2, exerciseId: 'face-pull')]);
      expect(p.excludes(e('face-pull')), isTrue);
      expect(p.excludes(e('chest-press')), isTrue);
    });

    test('too_hard / too_easy: latest wins, only recent ones count', () {
      final p = policy([
        fb('a', FeedbackKind.tooHard, exerciseId: 'curl', daysAgo: 10),
        fb('b', FeedbackKind.tooEasy, exerciseId: 'curl', daysAgo: 3),
        fb('c', FeedbackKind.tooHard, exerciseId: 'leg-press', daysAgo: 4),
        fb('d', FeedbackKind.tooEasy, exerciseId: 'ohp', daysAgo: 60),
      ]);
      expect(p.exerciseFeedback['curl']!.incrementSteps, 1);
      expect(p.exerciseFeedback['leg-press']!.incrementSteps, -1);
      expect(p.exerciseFeedback.containsKey('ohp'), isFalse);
      expect(p.excludes(e('leg-press')), isFalse);
      expect(p.penalty(e('leg-press')), 0);
    });
  });

  group('review and brief', () {
    test('default review dates and due check', () {
      expect(FeedbackRecord.defaultReviewOn(FeedbackKind.pain, DateTime(2026, 11, 2, 15)), DateTime(2026, 11, 9));
      expect(FeedbackRecord.defaultReviewOn(FeedbackKind.discomfort, DateTime(2026, 11, 2)), DateTime(2026, 11, 16));
      expect(FeedbackRecord.defaultReviewOn(FeedbackKind.tooHard, DateTime(2026, 11, 2)), isNull);
      final due = fb('a', FeedbackKind.pain, region: 'neck', daysAgo: 7);
      final notYet = fb('b', FeedbackKind.discomfort, region: 'knee', daysAgo: 7);
      expect(due.isDueForReview(now), isTrue);
      expect(notYet.isDueForReview(now), isFalse);
      final p = policy([due, notYet]);
      expect(p.isDueForReview(now), isTrue);
      expect(p.dueForReview(now).map((r) => r.id), ['a']);
      expect(due.copyWith(status: 'resolved').isDueForReview(now), isFalse);
    });

    test('brief: active limitations and recent exercise feedback (≤ 30, 90 days)', () {
      final p = policy([
        fb('neck', FeedbackKind.pain, region: 'neck', severity: 2, note: 'neck hurts', daysAgo: 2),
        fb('hard', FeedbackKind.tooHard, exerciseId: 'leg-press', note: 'heavy', daysAgo: 6),
        fb('old', FeedbackKind.like, exerciseId: 'curl', daysAgo: 120),
        fb('fixed', FeedbackKind.pain, exerciseId: 'curl', status: 'resolved', daysAgo: 20),
        for (var i = 0; i < 40; i++) fb('n$i', FeedbackKind.note, exerciseId: 'ohp', daysAgo: 30 + i),
      ]);
      final brief = p.toBrief();
      expect(brief['limitations'], [
        {'id': 'neck', 'kind': 'pain', 'region': 'neck', 'severity': 2, 'exerciseId': null, 'note': 'neck hurts', 'since': '2026-11-07'},
      ]);
      final feedback = (brief['exerciseFeedback'] as List).cast<Map<String, dynamic>>();
      expect(feedback, hasLength(30));
      expect(feedback.first, {'exerciseId': 'leg-press', 'kind': 'too_hard', 'note': 'heavy', 'date': '2026-11-03'});
      expect(feedback[1]['kind'], 'pain', reason: 'resolved exercise pain is history');
      expect(feedback.any((f) => f['kind'] == 'like'), isFalse, reason: 'older than 90 days');
    });

    test('JSON roundtrip in the sync shape', () {
      final r = FeedbackRecord(
        id: 'x',
        createdAt: DateTime.utc(2026, 11, 7, 9),
        kind: FeedbackKind.discomfort,
        region: 'shoulder',
        severity: 1,
        note: 'tight',
        reviewOn: DateTime(2026, 11, 21),
        source: 'coach',
      );
      final back = FeedbackRecord.fromJson(r.toJson());
      expect(r.toJson()['kind'], 'discomfort');
      expect(r.toJson()['reviewOn'], '2026-11-21');
      expect(back.kind, FeedbackKind.discomfort);
      expect(back.region, 'shoulder');
      expect(back.severity, 1);
      expect(back.reviewOn, DateTime(2026, 11, 21));
      expect(back.source, 'coach');
      expect(back.isActive, isTrue);
      expect(FeedbackKind.parse('too_easy'), FeedbackKind.tooEasy);
      expect(FeedbackKind.parse('???'), FeedbackKind.note);
    });
  });
}
