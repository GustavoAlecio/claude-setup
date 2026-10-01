import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../features/flow/flow_page.dart';
import '../features/landing/landing_page.dart';
import '../features/placeholder/planned_page.dart';
import '../features/runs/runs_page.dart';
import '../features/runs/task_detail_page.dart';
import '../features/sessions/sessions_page.dart';
import '../features/shell/shell_page.dart';

GoRouter buildRouter() {
  const route = String.fromEnvironment('INITIAL_ROUTE');
  return GoRouter(
    initialLocation: route.isEmpty ? '/' : route,
    routes: [
      GoRoute(path: '/', pageBuilder: (_, state) => _instant(state, const LandingPage())),
      ShellRoute(
        builder: (context, state, child) => ShellPage(
          projectName: state.pathParameters['project']!,
          tab: AppTab.parse(state.pathParameters['tab'] ?? state.uri.pathSegments[2]),
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/p/:project/runs/:run/:task',
            pageBuilder: (_, state) => _instant(
              state,
              TaskDetailPage(
                projectName: state.pathParameters['project']!,
                runId: state.pathParameters['run']!,
                taskId: state.pathParameters['task']!,
              ),
            ),
          ),
          GoRoute(
            path: '/p/:project/sessions/:session',
            pageBuilder: (_, state) => _instant(
              state,
              SessionsPage(projectName: state.pathParameters['project']!, sessionId: state.pathParameters['session']),
            ),
          ),
          GoRoute(
            path: '/p/:project/:tab',
            pageBuilder: (_, state) {
              final project = state.pathParameters['project']!;
              return _instant(state, switch (AppTab.parse(state.pathParameters['tab'])) {
                AppTab.flow => FlowPage(projectName: project),
                AppTab.runs => RunsPage(projectName: project),
                AppTab.sessions => SessionsPage(projectName: project),
                final tab => PlannedPage(tab: tab),
              });
            },
          ),
        ],
      ),
    ],
  );
}

/// Desktop tabs and drill-downs swap content in place; a page transition here reads as the whole shell sliding.
Page<void> _instant(GoRouterState state, Widget child) => NoTransitionPage<void>(key: state.pageKey, child: child);
