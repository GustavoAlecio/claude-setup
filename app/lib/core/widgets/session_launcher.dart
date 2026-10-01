import 'dart:async';
import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../data/docs_repository.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';

/// Row actions that create a session and open it: one create per [key] at a time, its error kept per key
/// until the next try.
mixin SessionLauncher<T extends StatefulWidget> on State<T> {
  final _creating = <String>{};
  final _createErrors = <String, String>{};

  String get logName;

  bool isCreating(String key) => _creating.contains(key);

  String? createError(String key) => _createErrors[key];

  /// [githubAccount] is the `gh` login the session runs as; `null` keeps the active account.
  Future<void> launchSession(
    String key,
    String project,
    String command, {
    required String cwd,
    required String? githubAccount,
    required PermissionMode permissionMode,
  }) async {
    if (_creating.contains(key)) return;
    final sessions = SessionsScope.of(context);
    final router = GoRouter.of(context);
    setState(() {
      _creating.add(key);
      _createErrors.remove(key);
    });
    try {
      final s = await sessions.create(
        project,
        command,
        cwd: cwd,
        githubAccount: githubAccount,
        permissionMode: permissionMode,
      );
      if (!mounted) return;
      router.go('/p/${s.project}/sessions/${s.id}');
    } on Exception catch (e, st) {
      log('cannot create $command session', name: logName, error: e, stackTrace: st);
      if (mounted) setState(() => _createErrors[key] = '$e');
    } finally {
      if (mounted) setState(() => _creating.remove(key));
    }
  }

  void openLink(Uri uri) {
    if (opensExternally(uri)) {
      unawaited(DocsScope.openerOf(context)(uri));
    } else {
      log('link ignored: $uri', name: logName);
    }
  }
}
