import 'package:flutter/widgets.dart';

import '../engine/engine_supervisor.dart';
import 'session_models.dart';

abstract interface class SessionsRepository {
  Stream<List<SessionSummary>> watchSessions();
  Stream<SessionDetail> watchSession(String id);
  Future<List<PaletteSkill>> skills();
  Future<SessionSummary> create(String project, String command);
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
