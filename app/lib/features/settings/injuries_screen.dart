import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../providers.dart';
import '../../widgets/active_injuries.dart';
import '../../widgets/auto_save_field.dart';
import '../../widgets/common.dart';
import '../../widgets/report_issue_sheet.dart';

/// Everything about injuries in one place: what is active now and what the coach should always keep in mind.
class InjuriesScreen extends ConsumerWidget {
  const InjuriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    if (profile == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final none = !(ref.watch(activeFeedbackProvider).value ?? const []).any(isInjury);
    final repo = ref.read(repositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Injuries')),
      body: ListView(padding: pagePadding(context), children: [
        const SectionTitle('Active', padding: SectionTitle.first),
        if (none)
          const Card(child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('Nothing active')))
        else
          const ActiveInjuries(),
        const SizedBox(height: Gap.item),
        FilledButton.tonalIcon(
          onPressed: () => showReportPain(context),
          icon: const Icon(Icons.healing_outlined),
          label: const Text('Report pain'),
        ),
        const SectionTitle('Always keep in mind'),
        AutoSaveField(
          label: 'Old injuries, limitations',
          helper: 'Your coach reads this with every plan.',
          value: profile.injuries,
          maxLines: 4,
          onSave: (v) => repo.saveProfile(ProfilesCompanion(injuries: Value(v))),
        ),
      ]),
    );
  }
}
