import 'dart:math' as math;

/// Countdown shared by the phone and the watch.
///
/// Everything is derived from absolute end times (epoch milliseconds), so both devices work out the same phase,
/// remaining time and follow-up rest without talking to each other. Mirrored by `Countdown.kt` in `watch/`; both run
/// the cases in `watch/fixtures/timers.json`.

enum CountdownKind { none, rest, work }

/// Device that started a countdown. Only the owner logs the set when a work countdown ends.
enum CountdownOwner { phone, watch }

/// The set a work countdown belongs to.
class SetRef {
  const SetRef({
    required this.sessionId,
    required this.order,
    required this.exerciseId,
    required this.section,
    required this.set,
    required this.seconds,
    required this.rest,
    required this.last,
    this.count = 1,
  });

  factory SetRef.fromJson(Map<String, dynamic> j) => SetRef(
        sessionId: j['sessionId'] as String,
        order: (j['order'] as num).toInt(),
        exerciseId: j['exerciseId'] as String,
        section: j['section'] as String,
        set: (j['set'] as num).toInt(),
        seconds: (j['seconds'] as num).toInt(),
        rest: (j['rest'] as num).toInt(),
        last: j['last'] as bool,
        count: (j['count'] as num?)?.toInt() ?? 1,
      );

  final String sessionId;
  final int order;
  final String exerciseId;
  final String section;
  final int set;

  /// Seconds stored for the set (per side for one-sided holds).
  final int seconds;

  /// Rest after the set, in seconds.
  final int rest;

  /// Last set of the exercise: the rest leads to the next exercise.
  final bool last;

  /// Sets one work countdown runs through in a row, starting with [set] (one-sided stretches: all of them).
  final int count;

  /// One reference per set the countdown covers.
  Iterable<SetRef> get each sync* {
    for (var n = 0; n < count; n++) {
      yield SetRef(
        sessionId: sessionId,
        order: order,
        exerciseId: exerciseId,
        section: section,
        set: set + n,
        seconds: seconds,
        rest: rest,
        last: last && n == count - 1,
      );
    }
  }

  bool isSameSet(SetRef o) =>
      sessionId == o.sessionId && order == o.order && exerciseId == o.exerciseId && set == o.set;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'order': order,
        'exerciseId': exerciseId,
        'section': section,
        'set': set,
        'seconds': seconds,
        'rest': rest,
        'last': last,
        if (count > 1) 'count': count,
      };
}

class CountdownPhase {
  const CountdownPhase({required this.label, required this.seconds, required this.endsAt, this.pause = false});

  factory CountdownPhase.fromJson(Map<String, dynamic> j) => CountdownPhase(
        label: j['label'] as String,
        seconds: (j['seconds'] as num).toInt(),
        endsAt: (j['endsAt'] as num).toInt(),
        pause: j['pause'] as bool? ?? false,
      );

  final String label;
  final int seconds;

  /// Epoch milliseconds.
  final int endsAt;

  /// Time to change sides inside a work countdown, not work itself.
  final bool pause;

  Map<String, dynamic> toJson() => {'label': label, 'seconds': seconds, 'endsAt': endsAt, if (pause) 'pause': true};
}

class Countdown {
  const Countdown({
    required this.kind,
    required this.owner,
    required this.changedAt,
    this.phases = const [],
    this.set,
  });

  factory Countdown.fromJson(Map<String, dynamic> j) => Countdown(
        kind: CountdownKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => CountdownKind.none),
        owner: CountdownOwner.values.firstWhere((o) => o.name == j['owner'], orElse: () => CountdownOwner.phone),
        changedAt: (j['changedAt'] as num).toInt(),
        phases: [
          for (final p in j['phases'] as List? ?? const []) CountdownPhase.fromJson((p as Map).cast<String, dynamic>()),
        ],
        set: j['set'] == null ? null : SetRef.fromJson((j['set'] as Map).cast<String, dynamic>()),
      );

  /// A stopped countdown; its [changedAt] makes it win from an older running one on the other device.
  factory Countdown.none(int at, CountdownOwner owner) =>
      Countdown(kind: CountdownKind.none, owner: owner, changedAt: at);

  factory Countdown.rest(String label, int seconds, {required int from, required CountdownOwner owner}) => Countdown(
        kind: CountdownKind.rest,
        owner: owner,
        changedAt: from,
        phases: [CountdownPhase(label: label, seconds: seconds, endsAt: from + seconds * 1000)],
      );

  /// Work countdown for [set]; one-sided exercises run one phase per side with [sideSwitchSeconds] in between, and go
  /// round again for every further set it covers.
  factory Countdown.work(
    String name,
    SetRef set, {
    required bool perSide,
    required int from,
    required CountdownOwner owner,
  }) {
    final phases = <CountdownPhase>[];
    var end = from;
    void add(String label, int seconds, {bool pause = false}) {
      end += seconds * 1000;
      phases.add(CountdownPhase(label: label, seconds: seconds, endsAt: end, pause: pause));
    }

    for (var round = 1; round <= set.count; round++) {
      final of = set.count > 1 ? ' ($round/${set.count})' : '';
      for (var side = 1; side <= (perSide ? 2 : 1); side++) {
        if (perSide && phases.isNotEmpty) add('$switchLabel · $name', sideSwitchSeconds, pause: true);
        add(perSide ? 'Side $side$of · $name' : '$name$of', set.seconds);
      }
    }
    return Countdown(kind: CountdownKind.work, owner: owner, changedAt: from, set: set, phases: phases);
  }

  /// Time to change sides in a one-sided hold.
  static const sideSwitchSeconds = 5;
  static const switchLabel = 'Switch sides';

  static const restLabel = 'Rest';
  static const restNextLabel = 'Rest · next exercise';

  final CountdownKind kind;
  final CountdownOwner owner;

  /// Epoch milliseconds of the last change by a person (start, extend, stop); the newest one wins between devices.
  final int changedAt;
  final List<CountdownPhase> phases;
  final SetRef? set;

  bool get isWork => kind == CountdownKind.work;

  /// Epoch milliseconds at which the last phase ends.
  int get endsAt => phases.isEmpty ? changedAt : phases.last.endsAt;

  bool isOver(int now) => kind == CountdownKind.none || now >= endsAt;

  /// Index of the phase running at [now] (the last one once it is over).
  int phaseIndex(int now) {
    for (var i = 0; i < phases.length; i++) {
      if (now < phases[i].endsAt) return i;
    }
    return math.max(0, phases.length - 1);
  }

  CountdownPhase? phaseAt(int now) => phases.isEmpty ? null : phases[phaseIndex(now)];

  /// Whole seconds left in the phase running at [now], rounded up.
  int remaining(int now) {
    final p = phaseAt(now);
    if (p == null) return 0;
    return math.max(0, ((p.endsAt - now) / 1000).ceil());
  }

  double progress(int now) {
    final p = phaseAt(now);
    if (p == null || p.seconds <= 0) return 1;
    return (1 - remaining(now) / p.seconds).clamp(0, 1).toDouble();
  }

  /// Lengthens (or shortens) the running phase and moves the later ones along. A phase cannot end before [now].
  Countdown extend(int seconds, int now) {
    if (isOver(now)) return this;
    final i = phaseIndex(now);
    final shift = math.max(seconds * 1000, now - phases[i].endsAt);
    return Countdown(
      kind: kind,
      owner: owner,
      changedAt: now,
      set: set,
      phases: [
        for (var p = 0; p < phases.length; p++)
          p < i
              ? phases[p]
              : CountdownPhase(
                  label: phases[p].label,
                  seconds: p == i ? math.max(0, phases[p].seconds + seconds) : phases[p].seconds,
                  endsAt: phases[p].endsAt + shift,
                  pause: phases[p].pause,
                ),
      ],
    );
  }

  /// Rest that follows this work countdown, starting when the work ended; null when there is none.
  Countdown? get restAfter {
    final s = set;
    if (!isWork || s == null || s.rest <= 0) return null;
    return Countdown.rest(s.last ? restNextLabel : restLabel, s.rest, from: endsAt, owner: owner);
  }

  /// What is running at [now]: this countdown, the rest after it, or null.
  Countdown? at(int now) {
    if (kind == CountdownKind.none) return null;
    if (!isOver(now)) return this;
    return restAfter?.at(now);
  }

  /// The most recently changed of two countdowns (phone and watch each keep one).
  static Countdown? newest(Countdown? a, Countdown? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.changedAt > a.changedAt ? b : a;
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'owner': owner.name,
        'changedAt': changedAt,
        'phases': [for (final p in phases) p.toJson()],
        'set': set?.toJson(),
      };
}
