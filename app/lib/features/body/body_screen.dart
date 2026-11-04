import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../data/repositories/repository.dart';
import '../../domain/progression.dart';
import '../../providers.dart';
import '../../widgets/charts.dart';
import '../../widgets/common.dart';

class BodyScreen extends ConsumerWidget {
  const BodyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(bodyMetricsProvider);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Body tracking')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Log'),
      ),
      body: AsyncView(
        value: metrics,
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.monitor_weight_outlined,
              title: 'Track your body',
              message: 'Log body weight (and optionally waist, chest, arms…) once a week, same time of day.',
              action: FilledButton(onPressed: () => _edit(context, ref, null), child: const Text('Log first entry')),
            );
          }
          final weights = list.where((b) => b.weightKg != null).toList().reversed.toList();
          final waist = list.where((b) => b.waistCm != null).toList().reversed.toList();
          final latest = weights.isEmpty ? null : weights.last;
          final first = weights.isEmpty ? null : weights.first;
          return ListView(padding: pagePadding(context, Gap.page.copyWith(bottom: Gap.fabClearance)), children: [
            StatRow(children: [
              StatTile(
                label: 'current weight',
                value: latest == null ? '–' : '${formatKg(latest.weightKg)} kg',
                icon: Icons.monitor_weight_outlined,
              ),
              StatTile(
                label: 'change',
                value: latest == null || first == null
                    ? '–'
                    : '${(latest.weightKg! - first.weightKg!) >= 0 ? '+' : ''}${(latest.weightKg! - first.weightKg!).toStringAsFixed(1)} kg',
                icon: Icons.trending_flat,
              ),
              StatTile(label: 'entries', value: '${list.length}', icon: Icons.list_alt),
            ]),
            if (weights.length >= 2) ...[
              const SectionTitle('Weight'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                  child: TrendLineChart(
                    values: weights.map((b) => b.weightKg!).toList(),
                    labels: weights.map((b) => DateFormat('d/M').format(parseDateKey(b.date))).toList(),
                    unit: ' kg',
                  ),
                ),
              ),
            ],
            if (waist.length >= 2) ...[
              const SectionTitle('Waist'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
                  child: TrendLineChart(
                    values: waist.map((b) => b.waistCm!).toList(),
                    labels: waist.map((b) => DateFormat('d/M').format(parseDateKey(b.date))).toList(),
                    unit: ' cm',
                    color: t.colorScheme.tertiary,
                  ),
                ),
              ),
            ],
            const SectionTitle('Entries'),
            Card(
              child: Column(children: [
                for (final b in list)
                  ListTile(
                    onTap: () => _edit(context, ref, b),
                    title: Text(DateFormat('EEE d MMM yyyy').format(parseDateKey(b.date))),
                    subtitle: Text(_summary(b)),
                    trailing: Text(b.weightKg == null ? '' : '${formatKg(b.weightKg)} kg',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }

  static String _summary(BodyMetric b) {
    final parts = <String>[
      if (b.bodyFatPct != null) '${formatKg(b.bodyFatPct)}% fat',
      if (b.waistCm != null) 'waist ${formatKg(b.waistCm)}',
      if (b.chestCm != null) 'chest ${formatKg(b.chestCm)}',
      if (b.armCm != null) 'arm ${formatKg(b.armCm)}',
      if (b.thighCm != null) 'thigh ${formatKg(b.thighCm)}',
      if (b.hipsCm != null) 'hips ${formatKg(b.hipsCm)}',
      if (b.notes.isNotEmpty) b.notes,
    ];
    return parts.isEmpty ? 'Weight only' : parts.join(' · ');
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, BodyMetric? existing) async {
    await showAppSheet<void>(context, builder: (_) => _BodyForm(existing: existing));
  }
}

class _BodyForm extends ConsumerStatefulWidget {
  const _BodyForm({this.existing});

  final BodyMetric? existing;

  @override
  ConsumerState<_BodyForm> createState() => _BodyFormState();
}

class _BodyFormState extends ConsumerState<_BodyForm> {
  late DateTime _date = widget.existing == null ? DateTime.now() : parseDateKey(widget.existing!.date);
  late final _weight = _c(widget.existing?.weightKg);
  late final _fat = _c(widget.existing?.bodyFatPct);
  late final _waist = _c(widget.existing?.waistCm);
  late final _chest = _c(widget.existing?.chestCm);
  late final _arm = _c(widget.existing?.armCm);
  late final _thigh = _c(widget.existing?.thighCm);
  late final _hips = _c(widget.existing?.hipsCm);
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  bool _more = false;

  static TextEditingController _c(double? v) => TextEditingController(text: v == null ? '' : formatKg(v));
  static double? _p(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.'));

  @override
  void dispose() {
    for (final c in [_weight, _fat, _waist, _chest, _arm, _thigh, _hips, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(repositoryProvider).saveBodyMetric(BodyMetricsCompanion(
          id: widget.existing == null ? const Value.absent() : Value(widget.existing!.id),
          date: Value(dateKey(_date)),
          weightKg: Value(_p(_weight)),
          bodyFatPct: Value(_p(_fat)),
          waistCm: Value(_p(_waist)),
          chestCm: Value(_p(_chest)),
          armCm: Value(_p(_arm)),
          thighCm: Value(_p(_thigh)),
          hipsCm: Value(_p(_hips)),
          notes: Value(_notes.text.trim()),
        ));
    ref.read(syncControllerProvider.notifier).syncNow(onlyIfStale: true);
    if (mounted) Navigator.pop(context);
  }

  Widget _field(TextEditingController c, String label, String suffix) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: suffix),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SingleChildScrollView(
      padding: sheetPadding(context),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(widget.existing == null ? 'New entry' : 'Edit entry',
                style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ),
          if (widget.existing != null)
            IconButton(
              tooltip: 'Delete entry',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await ref.read(repositoryProvider).deleteBodyMetric(widget.existing!.id);
                if (context.mounted) Navigator.pop(context);
              },
            ),
        ]),
        const SizedBox(height: Gap.sm),
        ActionChip(
          avatar: const Icon(Icons.event, size: 18),
          label: Text(DateFormat('EEE d MMM yyyy').format(_date)),
          onPressed: () async {
            final d = await showDatePicker(
              context: context,
              initialDate: _date,
              firstDate: DateTime(2020),
              lastDate: DateTime.now(),
            );
            if (d != null) setState(() => _date = d);
          },
        ),
        const SizedBox(height: 12),
        _field(_weight, 'Body weight', 'kg'),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => setState(() => _more = !_more),
          icon: Icon(_more ? Icons.expand_less : Icons.expand_more),
          label: const Text('Measurements (optional)'),
        ),
        if (_more) ...[
          Row(children: [
            Expanded(child: _field(_waist, 'Waist', 'cm')),
            const SizedBox(width: 8),
            Expanded(child: _field(_fat, 'Body fat', '%')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _field(_chest, 'Chest', 'cm')),
            const SizedBox(width: 8),
            Expanded(child: _field(_arm, 'Arm', 'cm')),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _field(_thigh, 'Thigh', 'cm')),
            const SizedBox(width: 8),
            Expanded(child: _field(_hips, 'Hips', 'cm')),
          ]),
          const SizedBox(height: 8),
        ],
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes')),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('Save'))),
      ]),
    );
  }
}
