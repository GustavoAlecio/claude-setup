import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/claude_home.dart';
import '../data/orgs.dart';
import '../features/about/about_page.dart';
import '../features/artifacts/artifacts_page.dart';
import '../features/flow/flow_page.dart';
import '../features/inbox/inbox_page.dart';
import '../features/landing/landing_page.dart';
import '../features/placeholder/planned_page.dart';
import '../features/prs/prs_page.dart';
import '../features/reviews/reviews_page.dart';
import '../features/runs/runs_page.dart';
import '../features/runs/task_detail_page.dart';
import '../features/sessions/sessions_page.dart';
import '../features/settings/settings_page.dart';
import '../features/shell/shell_page.dart';
import '../features/shell/shell_scope.dart';

GoRouter buildRouter(EffectivePaths paths) {
  const route = String.fromEnvironment('INITIAL_ROUTE');
  var lastShellRoute = isShellLocation(route) ? route : '/';
  final router = GoRouter(
    initialLocation: route.isEmpty ? '/' : route,
    routes: [
      GoRoute(path: '/', pageBuilder: (_, state) => _instant(state, const LandingPage())),
      GoRoute(
        path: '/settings',
        pageBuilder: (_, state) => _instant(state, SettingsPage(backTo: () => lastShellRoute)),
      ),
      GoRoute(
        path: '/about',
        pageBuilder: (_, state) => _instant(state, AboutPage(backTo: () => lastShellRoute, paths: paths)),
      ),
      ShellRoute(
        builder: (context, state, child) => switch (state.uri.pathSegments.first) {
          'o' => ShellPage(scope: ShellOrgScope(state.pathParameters['org']!), tab: AppTab.sessions, child: child),
          _ => ShellPage(
            scope: ShellProjectScope(state.pathParameters['project']!),
            tab: AppTab.parse(state.pathParameters['tab'] ?? state.uri.pathSegments[2]),
            child: child,
          ),
        },
        routes: [
          GoRoute(
            path: '/o/:org/sessions',
            pageBuilder: (_, state) =>
                _instant(state, SessionsPage(scope: ShellOrgScope(state.pathParameters['org']!))),
          ),
          GoRoute(
            path: '/o/:org/sessions/:session',
            pageBuilder: (_, state) => _instant(
              state,
              SessionsPage(
                scope: ShellOrgScope(state.pathParameters['org']!),
                sessionId: state.pathParameters['session'],
              ),
            ),
          ),
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
              SessionsPage(
                scope: ShellProjectScope(state.pathParameters['project']!),
                sessionId: state.pathParameters['session'],
              ),
            ),
          ),
          GoRoute(
            path: '/p/:project/:tab',
            pageBuilder: (_, state) {
              final project = state.pathParameters['project']!;
              final query = state.uri.queryParameters;
              return _instant(state, switch (AppTab.parse(state.pathParameters['tab'])) {
                AppTab.flow => FlowPage(projectName: project),
                AppTab.runs => RunsPage(projectName: project),
                AppTab.sessions => SessionsPage(scope: ShellProjectScope(project)),
                AppTab.artifacts => ArtifactsPage(key: ValueKey(project), projectName: project, doc: query['doc']),
                AppTab.reviews => ReviewsPage(
                  key: ValueKey(project),
                  projectName: project,
                  pr: int.tryParse(query['pr'] ?? ''),
                ),
                AppTab.prs => PrsPage(key: ValueKey(project), projectName: project),
                AppTab.inbox => const InboxPage(),
                final tab => PlannedPage(tab: tab),
              });
            },
          ),
        ],
      ),
    ],
  );
  // `/settings` and `/about` sit outside the shell and `go` keeps no history, so "Voltar" needs the last shell route.
  router.routerDelegate.addListener(() {
    final uri = router.routerDelegate.currentConfiguration.uri;
    if (isShellLocation(uri.path)) lastShellRoute = uri.toString();
  });
  return router;
}

/// Desktop tabs and drill-downs swap content in place; a page transition here reads as the whole shell sliding.
Page<void> _instant(GoRouterState state, Widget child) => NoTransitionPage<void>(key: state.pageKey, child: child);
