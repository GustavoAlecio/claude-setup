import 'dart:developer';

import 'package:flutter/material.dart';

import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';

/// Picks a folder and adds it as a project of [org]: pinned to [org] only when the org roots would put it
/// elsewhere. Reports the outcome in a snackbar; `false` when nothing was added.
Future<bool> addProjectToOrg(BuildContext context, String org, DashboardConfig config) async {
  final repository = RepositoryScope.of(context);
  final pick = RepositoryScope.pickerOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final dir = await pick();
  if (dir == null) return false;
  final picked = await repository.inspectDirectory(dir);
  final byRoot = orgOf(picked.path, orgs: config.orgs, canonical: normalizePath);
  try {
    await repository.updateConfig(addProject(name: picked.name, path: picked.path, org: byRoot == org ? null : org));
  } on ConfigWriteException catch (e, st) {
    log('project write rejected', name: 'AddProject', error: e, stackTrace: st);
    messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
  messenger?.showSnackBar(
    SnackBar(
      content: Text('${picked.name} adicionado em $org${picked.divergence == null ? '' : ' · ${picked.divergence}'}'),
    ),
  );
  return true;
}
