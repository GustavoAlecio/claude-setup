import 'dart:typed_data';

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
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  });

  /// Session of the org itself, outside any project: [cwd] is its first root, [additionalDirectories] the others.
  Future<SessionSummary> createInOrg(
    String org,
    String command, {
    required String cwd,
    List<String> additionalDirectories = const [],
    String? githubAccount,
    required PermissionMode permissionMode,
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  });

  /// Login state of an Antigravity account and the terminal command that logs it in (login needs a TTY).
  Future<AgentAccountStatus> agentAccount(String account);

  /// Claude Code and `gh` login state for the first-use checklist; [fresh] skips the engine's one-minute cache.
  Future<Readiness> readiness({bool fresh = false});

  /// Side question about session [id]: a new read-only session that sees everything [id] did (a fork of its
  /// transcript) and never enters its context. [SessionsException] 409 for Antigravity or a session with no history.
  Future<SessionSummary> askAside(String id, String text);

  /// Requests from the terminal's `/app`, while [watchSessions] is listened (the app always is).
  Stream<TerminalHandoff> terminalHandoffs();

  /// Claude Code sessions started in a terminal at [cwd], newest first, without the ones the engine already has.
  Future<List<TerminalSession>> terminalSessions(String cwd);

  /// Brings terminal session [sdkSessionId] into the app as a `detached` session with its history; resuming it
  /// continues the same transcript, or a fork of it while the terminal still has it open. Importing again returns
  /// the same session.
  Future<SessionSummary> importTerminalSession({
    required String sdkSessionId,
    required String cwd,
    required String project,
    String? githubAccount,
    required PermissionMode permissionMode,
  });

  /// Files the Antigravity agent wrote for session [id], newest first; empty for Anthropic sessions.
  Future<List<SessionArtifact>> sessionArtifacts(String id);

  /// Content of one of [sessionArtifacts]; [SessionsException] 404 when [name] is not one of them.
  Future<String> sessionArtifact(String id, String name);

  /// Models Claude Code offers (`supportedModels()` of the SDK), for the session model pickers.
  Future<List<AgentModel>> claudeModels();

  /// Switches the model of session [id]; on Antigravity a refusal mid-turn is a [SessionsException] 409.
  Future<void> setModel(String id, String model);

  /// PNG of a mermaid diagram rendered by the engine in the app's [dark] or light palette, at 2x. A syntax error is
  /// a [SessionsException] 422 with the mermaid message; no Chrome on the machine is 501.
  Future<Uint8List> renderMermaid(String code, {required bool dark});

  /// Opens Finder with the artifact selected in the conversation folder.
  Future<void> revealArtifact(String id, String name);

  /// Pauses, resumes or archives (as abandoned) [project]'s active cycle through the engine's `bin/wf-cycle.py`;
  /// [SessionsException] 409 when there is no active cycle.
  Future<void> cycleAction(String project, CycleAction action);

  /// Opens Terminal on the account's `agy` so the user logs in there; [agentAccount] tells when it is done.
  Future<void> agentLogin(String account);

  /// Models the Antigravity [account] can use; [SessionsException] 409 when it is not logged in.
  Future<List<AgentModel>> agentModels(String account);

  /// Changes the mode of a live or detached session. Throws [SessionsException] with the engine text on a refusal
  /// (409) and on 404 (unknown session, or an engine older than the route).
  Future<void> setPermissionMode(String id, PermissionMode mode);

  /// [images] go with the message; the engine keeps them for the feed (see [attachmentUri]).
  Future<void> send(String id, String text, {List<ImageAttachment> images = const []});

  /// Where the feed loads an attachment of session [id] from; `null` without an engine.
  Uri? attachmentUri(String id, String name);
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

  /// `null` outside the app (widget tests that render markdown alone).
  static SessionsRepository? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionsScope>()?.sessions;

  static EngineController engineOf(BuildContext context) => _of(context).engine;

  @override
  bool updateShouldNotify(SessionsScope oldWidget) => sessions != oldWidget.sessions || engine != oldWidget.engine;
}

enum CycleAction { pause, resume, archive }
