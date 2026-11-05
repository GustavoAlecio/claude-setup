import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/config_mutations.dart';
import '../data/flow_repository.dart';
import '../data/models.dart';
import '../data/orgs.dart';
import '../engine/engine_config.dart';

/// The only `lastOrg` writer of the UI (switcher and shell sync): `false` when the write failed, which
/// is logged and shown on [messenger].
Future<bool> saveLastOrg(FlowRepository repository, String org, {ScaffoldMessengerState? messenger}) async {
  try {
    await repository.updateConfig(setLastOrg(org));
    return true;
  } catch (e, st) {
    log('cannot save lastOrg $org', name: 'saveLastOrg', error: e, stackTrace: st);
    messenger?.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}

/// Persists `lastOrg`; from a shell route of another org (or the landing) it also opens the org: its first
/// visible project, else its activities when it has roots, else the landing. Other routes (`/settings`) stay put.
///
/// The landing is opened with `?org=` so it waits for the config to reflect the write: until then
/// `lastOrg` is the old org and it would reopen that org's project. If the write fails while that
/// landing is still waiting, it goes back to `/` so [landingFor] decides from the unchanged config.
void switchOrg({
  required FlowRepository repository,
  required GoRouter router,
  required List<Project> projects,
  required DashboardConfig? config,
  required String org,
  ScaffoldMessengerState? messenger,
}) {
  unawaited(
    saveLastOrg(repository, org, messenger: messenger).then((saved) {
      if (saved) return;
      final uri = router.routerDelegate.currentConfiguration.uri;
      if (uri.path == '/' && uri.queryParameters['org'] == org) router.go('/');
    }),
  );
  final uri = router.routerDelegate.currentConfiguration.uri;
  final inShell = isShellLocation(uri.toString());
  if (inShell ? routeOrg(uri.toString(), projects) == org : uri.pathSegments.isNotEmpty) return;
  router.go(orgHome(org, projects, config) ?? Uri(path: '/', queryParameters: {'org': org}).toString());
}
