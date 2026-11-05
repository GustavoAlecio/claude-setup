import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/config_mutations.dart';
import '../data/flow_repository.dart';
import '../data/models.dart';
import '../data/orgs.dart';

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

/// Persists `lastOrg`; from a project route of another org (or the landing) it also opens the org's
/// first visible project, or the landing when it has none. Other routes (`/settings`) stay put.
///
/// The landing is opened with `?org=` so it waits for the config to reflect the write: until then
/// `lastOrg` is the old org and it would reopen that org's project. If the write fails while that
/// landing is still waiting, it goes back to `/` so [landingFor] decides from the unchanged config.
void switchOrg({
  required FlowRepository repository,
  required GoRouter router,
  required List<Project> projects,
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
  final segments = router.routerDelegate.currentConfiguration.uri.pathSegments;
  final inProject = segments.length >= 2 && segments.first == 'p';
  final routeOrg = inProject ? projects.where((p) => p.name == segments[1]).firstOrNull?.org : null;
  if (inProject ? routeOrg == org : segments.isNotEmpty) return;
  final first = projectsInOrg(projects, org).firstOrNull;
  router.go(first == null ? Uri(path: '/', queryParameters: {'org': org}).toString() : '/p/${first.name}/flow');
}
