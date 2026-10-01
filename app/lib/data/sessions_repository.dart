import 'package:flutter/widgets.dart';

import '../engine/engine_config.dart';
import '../engine/engine_supervisor.dart';
import 'session_models.dart';

abstract interface class SessionsRepository {
  Stream<List<SessionSummary>> watchSessions();
  Stream<SessionDetail> watchSession(String id);
  Future<List<PaletteSkill>> skills();

  /// [cwd] overrides the engine's own lookup (`cwds` + scan); `null` lets the engine resolve it.
  /// [githubAccount] is the `gh` login the session's `gh` runs as; `null` keeps the active account.
  /// [permissionMode] comes from `effectivePermissionMode`; required to track sessions' modes.
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
  });

  /// Session of the org itself, outside any project: [cwd] is its first root, [additionalDirectories] the others.
  Future<SessionSummary> createInOrg(
    String org,
    String command, {
    required String cwd,
    List<String> additionalDirectories = const [],
    String? githubAccount,
    required PermissionMode permissionMode,
  });

  /// Changes the mode of a live or detached session. Throws [SessionsException] with the engine text on a refusal
  /// (409) and on 404 (unknown session, or an engine older than the route).
  Future<void> setPermissionMode(String id, PermissionMode mode);
  Future<void> send(String id, String text);
  Future<void> answer(String id, String requestId, PermissionDecision decision, {Map<String, String>? answers});
  Future<void> resume(String id);
  Future<void> interrupt(String id);
}

class SessionsException implements Exception {
  const SessionsException(this.message, {this.statusCode});

  /// Engine error text, shown to the user as is (e.g. the missing cwd message).
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class SessionsScope extends InheritedWidget {
  const SessionsScope({super.key, required this.sessions, required this.engine, required super.child});

  final SessionsRepository sessions;
  final EngineController engine;

  static SessionsScope _of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SessionsScope>()!;

  static SessionsRepository of(BuildContext context) => _of(context).sessions;

  static EngineController engineOf(BuildContext context) => _of(context).engine;

  @override
  bool updateShouldNotify(SessionsScope oldWidget) => sessions != oldWidget.sessions || engine != oldWidget.engine;
}
