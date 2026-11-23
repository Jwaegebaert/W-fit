import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/api/api_client.dart';
import 'data/api/sync_service.dart';
import 'data/db/database.dart';
import 'data/repositories/repository.dart';
import 'domain/catalog.dart';
import 'domain/progression.dart';
import 'services/coach_service.dart';
import 'services/health_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Overridden in main() with the catalog loaded from assets.
final catalogProvider = Provider<Catalog>((ref) => throw UnimplementedError('catalog not loaded'));

final repositoryProvider = Provider<Repository>((ref) {
  Catalog? catalog;
  try {
    catalog = ref.watch(catalogProvider);
  } catch (_) {
    catalog = null; // Storage-only tests run without a catalog (no bar weights then).
  }
  return Repository(ref.watch(databaseProvider), catalog: catalog);
});

/// Bar weights (catalog defaults + the user's overrides) for turning logged plates into real load.
final loadModelProvider = Provider<LoadModel>((ref) => LoadModel(
      ref.watch(catalogProvider),
      LoadModel.parseOverrides(ref.watch(profileProvider).value?.barWeightsJson),
    ));

final apiConfigStoreProvider = Provider<ApiConfigStore>((ref) => ApiConfigStore());

class ApiConfigNotifier extends AsyncNotifier<ApiConfig> {
  @override
  Future<ApiConfig> build() => ref.read(apiConfigStoreProvider).load();

  Future<void> save(ApiConfig config) async {
    await ref.read(apiConfigStoreProvider).save(config);
    state = AsyncData(config);
  }
}

final apiConfigProvider = AsyncNotifierProvider<ApiConfigNotifier, ApiConfig>(ApiConfigNotifier.new);

final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(apiConfigProvider).value ?? ApiConfig.empty;
  return ApiClient(config);
});

final syncServiceProvider = Provider<SyncService>((ref) => SyncService(ref.watch(databaseProvider)));

class SyncState {
  const SyncState({this.syncing = false, this.lastSync, this.error, this.pending = 0});

  final bool syncing;
  final DateTime? lastSync;
  final String? error;
  final int pending;

  SyncState copyWith({bool? syncing, DateTime? lastSync, String? error, bool clearError = false, int? pending}) =>
      SyncState(
        syncing: syncing ?? this.syncing,
        lastSync: lastSync ?? this.lastSync,
        error: clearError ? null : (error ?? this.error),
        pending: pending ?? this.pending,
      );
}

class SyncController extends Notifier<SyncState> {
  @override
  SyncState build() {
    Future.microtask(_loadStatus);
    return const SyncState();
  }

  Future<void> _loadStatus() async {
    final svc = ref.read(syncServiceProvider);
    final last = await svc.lastSuccess();
    final pending = await svc.pendingCount();
    if (!ref.mounted) return;
    state = state.copyWith(lastSync: last?.toLocal(), pending: pending);
  }

  /// Best-effort sync. Never throws; errors are surfaced through [SyncState.error].
  Future<bool> syncNow({bool onlyIfStale = false}) async {
    if (state.syncing) return false;
    final api = ref.read(apiClientProvider);
    if (!api.config.isConfigured) {
      await _loadStatus();
      return false;
    }
    if (onlyIfStale && state.lastSync != null && DateTime.now().difference(state.lastSync!).inMinutes < 10) {
      final pending = await ref.read(syncServiceProvider).pendingCount();
      if (pending == 0) return true;
    }
    state = state.copyWith(syncing: true, clearError: true);
    try {
      await ref.read(syncServiceProvider).sync(api);
      final pending = await ref.read(syncServiceProvider).pendingCount();
      if (!ref.mounted) return true;
      state = state.copyWith(syncing: false, lastSync: DateTime.now(), pending: pending);
      return true;
    } catch (e) {
      final pending = await ref.read(syncServiceProvider).pendingCount();
      if (!ref.mounted) return false;
      state = state.copyWith(syncing: false, error: e.toString(), pending: pending);
      return false;
    }
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncState>(SyncController.new);

final profileProvider = StreamProvider<Profile>((ref) => ref.watch(repositoryProvider).watchProfile());

final equipmentProvider =
    StreamProvider<Map<String, bool>>((ref) => ref.watch(repositoryProvider).watchEquipment());

final preferencesProvider =
    StreamProvider<Map<String, String>>((ref) => ref.watch(repositoryProvider).watchPreferences());

final activeSessionProvider =
    StreamProvider<WorkoutSession?>((ref) => ref.watch(repositoryProvider).watchActiveSession());

final completedSessionsProvider =
    StreamProvider<List<WorkoutSession>>((ref) => ref.watch(repositoryProvider).watchCompletedSessions());

final bodyMetricsProvider =
    StreamProvider<List<BodyMetric>>((ref) => ref.watch(repositoryProvider).watchBodyMetrics());

/// All completed sets; recomputed whenever the list of finished sessions changes.
final allLoggedSetsProvider = FutureProvider<List<LoggedSet>>((ref) async {
  await ref.watch(completedSessionsProvider.future);
  ref.watch(loadModelProvider); // bar weights changed → recompute loads
  return ref.read(repositoryProvider).loggedSets();
});

final coachServiceProvider = Provider<CoachService>((ref) => CoachService(ref));

/// Health Connect platform bridge (overridden with a fake in tests).
final healthBridgeProvider = Provider<HealthBridge>((ref) => HealthConnectBridge());

final healthSyncProvider =
    Provider<HealthSync>((ref) => HealthSync(ref.watch(repositoryProvider), ref.watch(healthBridgeProvider)));

final activeFeedbackProvider =
    StreamProvider<List<FeedbackEntry>>((ref) => ref.watch(repositoryProvider).watchActiveFeedback());

/// Pain / discomfort entries whose check-in date has come.
final dueCheckInsProvider =
    StreamProvider<List<FeedbackEntry>>((ref) => ref.watch(repositoryProvider).watchDueCheckIns(DateTime.now()));

/// Program, balance, limitations and trends as of today; recomputed when sessions or feedback change.
final coachSnapshotProvider = FutureProvider<CoachSnapshot>((ref) async {
  await ref.watch(completedSessionsProvider.future);
  await ref.watch(activeFeedbackProvider.future);
  return ref.read(coachServiceProvider).snapshot();
});

/// Latest cached AI insights from the last 7 days (for the coach's focus muscles), or null.
final cachedInsightsProvider = FutureProvider<Insights?>((ref) async {
  final i = await ref.read(coachServiceProvider).cachedInsights();
  final at = i?.generatedAt;
  return at != null && DateTime.now().difference(at).inDays > 7 ? null : i;
});

/// Date key of the plan the AI coach is refining in the background (null when idle).
class CoachPreparingNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void prepare(String? dateKey) => state = dateKey;
}

final coachPreparingProvider = NotifierProvider<CoachPreparingNotifier, String?>(CoachPreparingNotifier.new);

/// Equipment temporarily occupied during the current gym visit.
class OccupiedEquipmentNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(Iterable<String> ids) => state = {...state, ...ids};
  void remove(String id) => state = {...state}..remove(id);
  void clear() => state = const {};
}

final occupiedEquipmentProvider =
    NotifierProvider<OccupiedEquipmentNotifier, Set<String>>(OccupiedEquipmentNotifier.new);
