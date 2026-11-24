import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../domain/catalog.dart';
import '../providers.dart';
import 'common.dart';

/// How often an exercise may be planned.
const preferenceChoices = {
  'liked': ('Like', 'Picked more often', Icons.thumb_up_outlined),
  'neutral': ('Neutral', 'Normal rotation', Icons.thumbs_up_down_outlined),
  'disliked': ('Dislike', 'Picked less often', Icons.thumb_down_outlined),
  'banned': ('Exclude', 'Left out of your plans', Icons.block),
};

Future<void> showPreferenceSheet(BuildContext context, Exercise exercise) =>
    showAppSheet<void>(context, builder: (_) => _PreferenceSheet(exercise: exercise));

class _PreferenceSheet extends ConsumerWidget {
  const _PreferenceSheet({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final current = ref.watch(preferencesProvider).value?[exercise.id] ?? 'neutral';
    return SingleChildScrollView(
      padding: sheetPadding(context),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(exercise.name, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: Gap.sm),
        for (final MapEntry(key: id, value: (label, hint, icon)) in preferenceChoices.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, color: current == id ? t.colorScheme.primary : null),
            title: Text(label, style: TextStyle(fontWeight: current == id ? FontWeight.w700 : null)),
            subtitle: Text(hint),
            trailing: current == id ? Icon(Icons.check, color: t.colorScheme.primary) : null,
            onTap: () async {
              await ref.read(repositoryProvider).setPreference(exercise.id, id);
              if (context.mounted) Navigator.pop(context);
            },
          ),
      ]),
    );
  }
}
