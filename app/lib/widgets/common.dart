import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../domain/catalog.dart';
import '../providers.dart';
import 'exercise_visuals.dart';

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(4, 20, 4, 8)});

  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          ?trailing,
        ]),
      );
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.color});

  final String label;
  final String value;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = color ?? t.colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null) Icon(icon, color: c, size: 22),
          if (icon != null) const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// A row of [StatTile]s (or similar cards) with equal widths, equal heights and the standard gap.
class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: Gap.item, children: [
          for (final c in children) Expanded(child: c),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: t.colorScheme.primaryContainer,
            child: Icon(icon, size: 36, color: t.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: Gap.md),
          Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: Gap.sm),
            Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: Gap.md), action!],
        ]),
      ),
    );
  }
}

/// Renders an [AsyncValue] with consistent loading and error states.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.builder});

  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
        error: (e, _) => EmptyState(icon: Icons.error_outline, title: 'Something went wrong', message: '$e'),
      );
}

/// Rounded square with the equipment-kind icon (dumbbell, machine, cable…) tinted by the exercise's section colour.
class ExerciseAvatar extends ConsumerWidget {
  const ExerciseAvatar({super.key, required this.exercise, this.size = 44});

  final Exercise? exercise;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Theme.of(context).colorScheme;
    final e = exercise;
    final section = switch (e?.category) {
      'warmup' => Section.warmup,
      'core' => Section.core,
      'cooldown' => Section.cooldown,
      _ => Section.main,
    };
    final color = section.color(s);
    final kind = e == null ? null : ExerciseKind.of(e, ref.watch(catalogProvider));
    return Semantics(
      label: kind?.label,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(size / 3)),
        child: kind == null
            ? Icon(Icons.fitness_center_rounded, color: color, size: size * 0.55)
            : KindIcon(kind, color: color, size: size * 0.58),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.icon});

  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = color ?? t.colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: c), const SizedBox(width: 4)],
        Text(text, style: t.textTheme.labelMedium?.copyWith(color: c, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Padding for the scrollable body of a page without sticky bottom UI: [base] (default [Gap.page]) plus the
/// system navigation bar height, so the last item can scroll clear of Android's nav bar in edge-to-edge mode.
/// Pages with a `bottomNavigationBar` (e.g. [BottomActionBar] or the app's tab bar) don't need the inset: use
/// [base] directly. The keyboard is not added: the Scaffold already resizes its body for it.
EdgeInsets pagePadding(BuildContext context, [EdgeInsets base = Gap.page]) =>
    base.copyWith(bottom: base.bottom + MediaQuery.paddingOf(context).bottom);

/// Padding for modal bottom sheet content shown with [showAppSheet]: the sheet extends behind the navigation bar
/// and is not resized for the keyboard, so both are added.
EdgeInsets sheetPadding(BuildContext context) => Gap.sheet.copyWith(
    bottom: Gap.sheet.bottom + MediaQuery.paddingOf(context).bottom + MediaQuery.viewInsetsOf(context).bottom);

/// Shows a modal bottom sheet with the app defaults: scroll-controlled, below the status bar, drag handle.
/// Pad the content with [sheetPadding] so its last button stays above the navigation bar and keyboard.
Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder}) =>
    showModalBottomSheet<T>(context: context, isScrollControlled: true, useSafeArea: true, builder: builder);

/// Sticky bottom actions (primary button, timers, …). Use it as `Scaffold.bottomNavigationBar`, never as
/// `Scaffold.bottomSheet`: the scaffold strips the bottom inset from bottom sheets, which pushes them behind the
/// Android navigation bar. Draws its surface behind the system bar and keeps [child] above it.
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.child, this.padding = Gap.bar});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Material(
      color: s.surfaceContainer,
      shape: Border(top: BorderSide(color: s.outlineVariant.withValues(alpha: 0.6))),
      child: SafeArea(top: false, child: Padding(padding: padding, child: child)),
    );
  }
}

/// App bar title with a secondary line (date, timer…). Pair with `toolbarHeight: AppBarTitle.toolbarHeight`
/// so both lines fit at large text sizes.
class AppBarTitle extends StatelessWidget {
  const AppBarTitle(this.title, {super.key, required this.subtitle});

  static const double toolbarHeight = 64;

  final String title;
  final Widget subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      DefaultTextStyle.merge(
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: subtitle,
      ),
    ]);
  }
}
