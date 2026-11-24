import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../providers.dart';
import '../../widgets/auto_save_field.dart';
import '../../widgets/common.dart';

/// About you: name, goals and body facts. Saved while typing.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final repo = ref.read(repositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('About you')),
      body: ListView(padding: pagePadding(context), children: [
        AutoSaveField(
          label: 'Name',
          value: profile.name,
          onSave: (v) => repo.saveProfile(ProfilesCompanion(name: Value(v))),
        ),
        const SizedBox(height: 12),
        AutoSaveField(
          label: 'Goals',
          value: profile.goals,
          maxLines: 3,
          onSave: (v) => repo.saveProfile(ProfilesCompanion(goals: Value(v))),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: AutoSaveField(
              label: 'Height (cm)',
              value: profile.heightCm?.toStringAsFixed(0) ?? '',
              number: true,
              onSave: (v) =>
                  repo.saveProfile(ProfilesCompanion(heightCm: Value(double.tryParse(v.replaceAll(',', '.'))))),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AutoSaveField(
              label: 'Birth year',
              value: profile.birthYear?.toString() ?? '',
              number: true,
              onSave: (v) => repo.saveProfile(ProfilesCompanion(birthYear: Value(int.tryParse(v)))),
            ),
          ),
        ]),
      ]),
    );
  }
}
