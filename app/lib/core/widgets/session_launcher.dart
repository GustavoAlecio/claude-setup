import 'dart:async';
import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../data/docs_repository.dart';
import '../../data/orgs.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';

/// Row actions that create a session and open it: one create per [key] at a time, its error kept per key
/// until the next try.
mixin SessionLauncher<T extends StatefulWidget> on State<T> {
  final _creating = <String>{};
  final _createErrors = <String, String>{};

  String get logName;

  bool isCreating(String key) => _creating.contains(key);

  bool get isCreatingAny => _creating.isNotEmpty;

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
    String currentPath() => router.routerDelegate.currentConfiguration.uri.path;
    final originPath = currentPath();
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
      // The engine lists the session before `create` answers, and that update can unmount the widget that asked
      // while the route stays; a route the user went to meanwhile must not be taken over (it skips the unsaved-edit confirmation).
      if (mounted || currentPath() == originPath) router.go(sessionLocation(s));
    } on Exception catch (e, st) {
      log('cannot create $command session', name: logName, error: e, stackTrace: st);
      if (mounted) setState(() => _createErrors[key] = '$e');
    } finally {
      if (mounted) setState(() => _creating.remove(key));
    }
  }

  void openLink(Uri uri) => DocsScope.openExternal(context, uri, logName: logName);
}
