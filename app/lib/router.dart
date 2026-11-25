import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/balance/balance_screen.dart';
import 'features/body/body_screen.dart';
import 'features/coach/coach_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/exercises/exercise_detail_screen.dart';
import 'features/exercises/library_screen.dart';
import 'features/history/history_screen.dart';
import 'features/history/session_detail_screen.dart';
import 'features/settings/connection_screen.dart';
import 'features/settings/equipment_screen.dart';
import 'features/settings/health_screen.dart';
import 'features/settings/health_send_screen.dart';
import 'features/settings/injuries_screen.dart';
import 'features/settings/muscle_focus_screen.dart';
import 'features/settings/numbered_stacks_screen.dart';
import 'features/settings/profile_screen.dart';
import 'features/settings/schedule_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/stats/exercise_progress_screen.dart';
import 'features/stats/stats_screen.dart';
import 'features/workout/plan_screen.dart';
import 'features/workout/session_screen.dart';

final _rootKey = GlobalKey<NavigatorState>();

final router = GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell: shell),
      branches: [
        StatefulShellBranch(routes: [GoRoute(path: '/', builder: (_, _) => const DashboardScreen())]),
        StatefulShellBranch(routes: [GoRoute(path: '/stats', builder: (_, _) => const StatsScreen())]),
        StatefulShellBranch(routes: [GoRoute(path: '/coach', builder: (_, _) => const CoachScreen())]),
      ],
    ),
    GoRoute(
      path: '/plan/:id',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => PlanScreen(plannedId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/session/:id',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => SessionScreen(sessionId: s.pathParameters['id']!),
    ),
    GoRoute(path: '/history', parentNavigatorKey: _rootKey, builder: (_, _) => const HistoryScreen()),
    GoRoute(
      path: '/history/:id',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => SessionDetailScreen(sessionId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/exercise/:id',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => ExerciseDetailScreen(exerciseId: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/progress/:id',
      parentNavigatorKey: _rootKey,
      builder: (_, s) => ExerciseProgressScreen(exerciseId: s.pathParameters['id']!),
    ),
    GoRoute(path: '/library', parentNavigatorKey: _rootKey, builder: (_, _) => const LibraryScreen()),
    GoRoute(path: '/body', parentNavigatorKey: _rootKey, builder: (_, _) => const BodyScreen()),
    GoRoute(path: '/balance', parentNavigatorKey: _rootKey, builder: (_, _) => const BalanceScreen()),
    GoRoute(path: '/settings', parentNavigatorKey: _rootKey, builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/settings/profile', parentNavigatorKey: _rootKey, builder: (_, _) => const ProfileScreen()),
    GoRoute(path: '/settings/schedule', parentNavigatorKey: _rootKey, builder: (_, _) => const ScheduleScreen()),
    GoRoute(path: '/settings/injuries', parentNavigatorKey: _rootKey, builder: (_, _) => const InjuriesScreen()),
    GoRoute(path: '/settings/equipment', parentNavigatorKey: _rootKey, builder: (_, _) => const EquipmentScreen()),
    GoRoute(
        path: '/settings/equipment/stacks', parentNavigatorKey: _rootKey, builder: (_, _) => const NumberedStacksScreen()),
    GoRoute(path: '/settings/focus', parentNavigatorKey: _rootKey, builder: (_, _) => const MuscleFocusScreen()),
    GoRoute(path: '/settings/health', parentNavigatorKey: _rootKey, builder: (_, _) => const HealthScreen()),
    GoRoute(path: '/settings/health/send', parentNavigatorKey: _rootKey, builder: (_, _) => const HealthSendScreen()),
    GoRoute(path: '/settings/connection', parentNavigatorKey: _rootKey, builder: (_, _) => const ConnectionScreen()),
  ],
);

class _Shell extends StatelessWidget {
  const _Shell({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: shell,
        bottomNavigationBar: NavigationBar(
          // Slightly shorter than the 80dp default so more content fits on small phones in edge-to-edge mode.
          height: 68,
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
            NavigationDestination(
                icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Progress'),
            NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: 'Coach'),
          ],
        ),
      );
}
