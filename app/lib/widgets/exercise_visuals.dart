import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';
import '../domain/catalog.dart';
import '../providers.dart';
import 'common.dart';

/// What an exercise is done with, as shown to the user (icon + label).
enum ExerciseKind {
  machine('Machine', 'machine'),
  cable('Cable', 'cable'),
  barbell('Free weight · Barbell', 'barbell'),
  dumbbell('Free weight · Dumbbell', 'dumbbell'),
  kettlebell('Free weight · Kettlebell', 'kettlebell'),
  band('Resistance band', 'band'),
  bench('Bench', 'bench'),
  bodyweight('Bodyweight', 'bodyweight'),
  cardio('Cardio', 'cardio'),
  mobility('Mobility', 'mobility'),
  plyo('Plyometric', 'plyo');

  const ExerciseKind(this.label, this._icon);

  final String label;
  final String _icon;

  String get asset => 'assets/icons/$_icon.svg';

  static final _cache = Expando<ExerciseKind>('ExerciseKind');

  /// Classifies [e] using the equipment groups of [catalog] (cached per exercise instance).
  static ExerciseKind of(Exercise e, Catalog catalog) =>
      _cache[e] ??= classify(e, (id) => catalog.equipmentById(id)?.group);

  /// Pure classifier; [groupOf] maps an equipment id to its catalog group. First matching rule wins:
  /// cardio pattern → mobility/stretch (incl. all cool-downs) → plyometrics → dedicated machine (machines group
  /// except the cable station, or Smith machine) → cable → barbell/EZ/trap bar → dumbbells → kettlebell → band →
  /// benches only → bodyweight.
  static ExerciseKind classify(Exercise e, String? Function(String equipmentId) groupOf) {
    final eq = e.equipment.toSet();
    if (e.pattern == 'cardio') return cardio;
    if (e.category == 'cooldown' || e.pattern == 'mobility' || e.pattern == 'stretch') return mobility;
    if (e.pattern.startsWith('plyo')) return plyo;
    if (eq.contains('smith_machine') || eq.any((id) => id != 'cable_machine' && groupOf(id) == 'machines')) {
      return machine;
    }
    if (eq.contains('cable_machine')) return cable;
    if (eq.contains('barbell') || eq.contains('ez_bar') || eq.contains('trap_bar')) return barbell;
    if (eq.contains('dumbbells')) return dumbbell;
    if (eq.contains('kettlebell')) return kettlebell;
    if (eq.contains('resistance_band')) return band;
    final gear = eq.difference(const {'bodyweight', Exercise.floorEquipmentId});
    if (gear.isNotEmpty && gear.every((id) => groupOf(id) == 'benches')) return bench;
    return bodyweight;
  }
}

/// Monochrome line icon for an [ExerciseKind], tinted with [color] (defaults to the ambient icon colour).
class KindIcon extends StatelessWidget {
  const KindIcon(this.kind, {super.key, this.size = 24, this.color});

  final ExerciseKind kind;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        kind.asset,
        width: size,
        height: size,
        excludeFromSemantics: true,
        colorFilter: ColorFilter.mode(color ?? IconTheme.of(context).color ?? Colors.black, BlendMode.srcIn),
      );
}

/// Line-art illustration of a piece of equipment (viewBox 160×120), tinted with [color].
class EquipmentIllustration extends StatelessWidget {
  const EquipmentIllustration(this.equipmentId, {super.key, this.color, this.width, this.height});

  final String equipmentId;
  final Color? color;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        'assets/equipment/$equipmentId.svg',
        width: width,
        height: height,
        excludeFromSemantics: true,
        colorFilter: ColorFilter.mode(color ?? Theme.of(context).colorScheme.primary, BlendMode.srcIn),
      );
}

/// Bundled start/end photos per exercise id (see `assets/exercises/index.json`).
class ExerciseMediaIndex {
  const ExerciseMediaIndex({required this.frames, this.attribution});

  factory ExerciseMediaIndex.fromJson(Map<String, dynamic> j) => ExerciseMediaIndex(
        frames: {
          for (final MapEntry(:key, :value) in (j['exercises'] as Map<String, dynamic>).entries)
            key: (value as Map<String, dynamic>)['frames'] as int? ?? 2,
        },
        attribution: (j['source'] as Map<String, dynamic>?)?['attribution'] as String?,
      );

  static const empty = ExerciseMediaIndex(frames: {});

  final Map<String, int> frames;
  final String? attribution;

  bool has(String exerciseId) => (frames[exerciseId] ?? 0) >= 2;

  static String frame(String exerciseId, int i) => 'assets/exercises/${exerciseId}_$i.jpg';
}

final exerciseMediaProvider = FutureProvider<ExerciseMediaIndex>((ref) async {
  try {
    // Read once and kept by this provider, so the bundle's string cache is not needed.
    final raw = await rootBundle.loadString('assets/exercises/index.json', cache: false);
    return ExerciseMediaIndex.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return ExerciseMediaIndex.empty;
  }
});

/// The equipment that best represents [e] in an illustration: the first real piece of gear, else the mat.
String? primaryEquipmentId(Exercise e) {
  final gear = e.equipment.where((id) => id != 'bodyweight');
  return gear.where((id) => id != Exercise.floorEquipmentId).firstOrNull ?? gear.firstOrNull;
}

/// Photos keep their own light background, even in dark mode.
const _photoSurface = Color(0xFFF4F6F5);
const _demoAspect = 3 / 2;
const _framePeriod = Duration(milliseconds: 1100);
const _fadePortion = 0.3;

/// Hero visual of an exercise: alternates the start and end photo with a crossfade so the movement reads at a glance.
/// Tapping opens both frames full screen. Without photos it shows the equipment illustration instead.
class ExerciseDemo extends ConsumerWidget {
  const ExerciseDemo({super.key, required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.watch(exerciseMediaProvider);
    final s = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Gap.radius),
      child: switch (media) {
        AsyncData(:final value) when value.has(exercise.id) => _PhotoDemo(exercise: exercise, attribution: value.attribution),
        AsyncData() || AsyncError() => _IllustrationDemo(exercise: exercise),
        _ => AspectRatio(aspectRatio: _demoAspect, child: ColoredBox(color: s.surfaceContainerHigh)),
      },
    );
  }
}

class _PhotoDemo extends StatefulWidget {
  const _PhotoDemo({required this.exercise, this.attribution});

  final Exercise exercise;
  final String? attribution;

  @override
  State<_PhotoDemo> createState() => _PhotoDemoState();
}

class _PhotoDemoState extends State<_PhotoDemo> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: _framePeriod * 2);
  bool _playing = false;
  int _frame = 0;
  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;
    if (!MediaQuery.disableAnimationsOf(context)) {
      _playing = true;
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setPlaying(bool play) {
    setState(() => _playing = play);
    if (play) {
      _controller.value = _frame == 0 ? 0 : 0.5;
      _controller.repeat();
    } else {
      _frame = _endOpacity(_controller.value) >= 0.5 ? 1 : 0;
      _controller.stop();
    }
  }

  /// Opacity of the end frame for a looping animation value t ∈ [0, 1): start frame, fade in, end frame, fade out.
  static double _endOpacity(double t) {
    const f = _fadePortion / 2;
    double ease(double x) => Curves.easeInOut.transform(x.clamp(0.0, 1.0));
    if (t < 0.5 - f) return 0;
    if (t < 0.5) return ease((t - (0.5 - f)) / f);
    if (t < 1 - f) return 1;
    return 1 - ease((t - (1 - f)) / f);
  }

  void _openFullScreen() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _DemoFullScreen(exercise: widget.exercise, attribution: widget.attribution),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.exercise.id;
    final t = Theme.of(context);
    return Semantics(
      label: 'Demo photos of ${widget.exercise.name}',
      button: true,
      onTapHint: 'view full screen',
      child: AspectRatio(
        aspectRatio: _demoAspect,
        child: Material(
          color: _photoSurface,
          child: InkWell(
            onTap: _openFullScreen,
            child: Stack(fit: StackFit.expand, children: [
              _DemoPhoto(ExerciseMediaIndex.frame(id, 0)),
              AnimatedBuilder(
                animation: _controller,
                builder: (_, child) => Opacity(
                  opacity: _playing ? _endOpacity(_controller.value) : _frame.toDouble(),
                  child: child,
                ),
                child: _DemoPhoto(ExerciseMediaIndex.frame(id, 1)),
              ),
              Positioned(
                left: 10,
                bottom: 10,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (_, _) {
                    final end = _playing ? _endOpacity(_controller.value) >= 0.5 : _frame == 1;
                    return _OverlayChip(
                      child: Text(end ? 'End' : 'Start',
                          style: t.textTheme.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                    );
                  },
                ),
              ),
              Positioned(
                right: 6,
                bottom: 6,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!_playing)
                    _OverlayButton(
                      icon: Icons.swap_horiz_rounded,
                      tooltip: 'Show ${_frame == 0 ? 'end' : 'start'} position',
                      onPressed: () => setState(() => _frame = 1 - _frame),
                    ),
                  _OverlayButton(
                    icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    tooltip: _playing ? 'Pause demo' : 'Play demo',
                    onPressed: () => _setPlaying(!_playing),
                  ),
                  _OverlayButton(icon: Icons.fullscreen_rounded, tooltip: 'Full screen', onPressed: _openFullScreen),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DemoPhoto extends StatelessWidget {
  const _DemoPhoto(this.asset);

  final String asset;

  @override
  Widget build(BuildContext context) => Image.asset(
        asset,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, color: Colors.black38)),
      );
}

class _OverlayChip extends StatelessWidget {
  const _OverlayChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(999)),
        child: child,
      );
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.55),
          foregroundColor: Colors.white,
          minimumSize: const Size(36, 36),
          fixedSize: const Size(36, 36),
          padding: EdgeInsets.zero,
        ),
      );
}

class _IllustrationDemo extends ConsumerWidget {
  const _IllustrationDemo({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final s = t.colorScheme;
    final equipmentId = primaryEquipmentId(exercise);
    final kind = ExerciseKind.of(exercise, ref.watch(catalogProvider));
    final fg = s.onPrimaryContainer;
    return AspectRatio(
      aspectRatio: 2,
      child: ColoredBox(
        color: s.primaryContainer.withValues(alpha: 0.55),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(children: [
            Expanded(
              child: equipmentId == null
                  ? FittedBox(child: KindIcon(kind, size: 72, color: fg.withValues(alpha: 0.8)))
                  : EquipmentIllustration(equipmentId, color: fg.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              'No demo photo yet — use Watch a demo',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodySmall?.copyWith(color: fg),
            ),
          ]),
        ),
      ),
    );
  }
}

class _DemoFullScreen extends StatelessWidget {
  const _DemoFullScreen({required this.exercise, this.attribution});

  final Exercise exercise;
  final String? attribution;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(exercise.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(padding: pagePadding(context), children: [
        for (final (i, label) in const [(0, 'Start position'), (1, 'End position')]) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, Gap.sm, 4, Gap.sm),
            child: Text(label, style: t.textTheme.titleSmall),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(Gap.radiusMd),
            child: ColoredBox(
              color: _photoSurface,
              child: AspectRatio(
                aspectRatio: _demoAspect,
                child: InteractiveViewer(
                  maxScale: 4,
                  child: _DemoPhoto(ExerciseMediaIndex.frame(exercise.id, i)),
                ),
              ),
            ),
          ),
        ],
        if (attribution != null) ...[
          const SizedBox(height: Gap.md),
          Text(
            'Pinch to zoom. $attribution',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ]),
    );
  }
}
