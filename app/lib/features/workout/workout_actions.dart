import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/database.dart';
import '../../domain/catalog.dart';
import '../../providers.dart';
import '../watch/watch_sync.dart';

/// Starts a session for [plan] and opens the live workout screen.
Future<void> startWorkout(BuildContext context, WidgetRef ref, PlannedWorkout plan) async {
  final repo = ref.read(repositoryProvider);
  final active = await repo.watchActiveSession().first;
  if (active != null) {
    if (context.mounted) context.push('/session/${active.id}');
    return;
  }
  ref.read(occupiedEquipmentProvider.notifier).clear();
  final id = await repo.startSession(
    plannedWorkoutId: plan.id,
    day: DayType.parse(plan.dayType),
    title: plan.title,
  );
  unawaited(ref.read(watchSyncProvider).openOnWatch());
  if (context.mounted) context.push('/session/$id');
}
