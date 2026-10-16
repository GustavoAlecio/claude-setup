import 'dart:typed_data';

import '../engine/engine_config.dart';

enum SessionStatus { starting, running, idle, waitingPermission, done, stopped, error, detached }

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.project,
    required this.command,
    this.skill,
    this.asideOf,
    required this.title,
    required this.status,
    required this.createdAt,
    this.cost = 0,
    this.pendingPermissions = 0,
    this.resumable = false,
    this.model,
    this.cwd,
    this.org,
    this.additionalDirectories = const [],
    this.permissionMode = PermissionMode.defaultMode,
    this.interrupted = false,
    this.provider = AgentProvider.anthropic,
    this.account,
  });

  final String id;

  /// `""` for an org session: it belongs to no project.
  final String project;
  final String command;

  /// Last `/skill` sent in the session, the first message included: a free conversation that ran `/kickoff` is a
  /// pipeline session from then on.
  final String? skill;

  /// Set on a side question: the session it forked from, whose context it never enters.
  final String? asideOf;
  final String title;
  final SessionStatus status;

  /// ISO-8601 as sent by the engine.
  final String createdAt;
  final double cost;
  final int pendingPermissions;
  final bool resumable;
  final String? model;
  final String? cwd;

  /// Set only for org sessions, which run in the org's first root with the others as [additionalDirectories].
  final String? org;
  final List<String> additionalDirectories;

  /// The session's own mode, fixed at creation and changed only through the session; the engine's absent value is
  /// `default`.
  final PermissionMode permissionMode;

  /// The last process event is `reattached` (the engine restarted and killed the previous process) and no message
  /// was sent since. Known only from the session's own event log, never from the list.
  final bool interrupted;

  /// Fixed at creation (ADR 0023); sessions from engines before 0.6.0 are Anthropic.
  final AgentProvider provider;

  /// Antigravity account the session runs as; `null` for Anthropic.
  final String? account;

  bool get isOrgSession => org != null;

  /// Only an idle session can be waiting on a message after the engine killed its process.
  bool get showsInterrupted => interrupted && status == SessionStatus.idle;

  SessionSummary copyWith({
    SessionStatus? status,
    double? cost,
    int? pendingPermissions,
    String? model,
    PermissionMode? permissionMode,
    bool? interrupted,
    String? skill,
  }) => SessionSummary(
    id: id,
    project: project,
    command: command,
    skill: skill ?? this.skill,
    asideOf: asideOf,
    title: title,
    status: status ?? this.status,
    createdAt: createdAt,
    cost: cost ?? this.cost,
    pendingPermissions: pendingPermissions ?? this.pendingPermissions,
    resumable: resumable,
    model: model ?? this.model,
    cwd: cwd,
    org: org,
    additionalDirectories: additionalDirectories,
    permissionMode: permissionMode ?? this.permissionMode,
    interrupted: interrupted ?? this.interrupted,
    provider: provider,
    account: account,
  );
}

class SessionDetail {
  const SessionDetail({
    required this.summary,
    this.events = const [],
    this.partialText = '',
    this.partialThinking = '',
    this.lastSeq = 0,
    this.closed = false,
  });

  final SessionSummary summary;
  final List<SessionEvent> events;

  /// Streaming deltas not yet replaced by the final `assistant_text`/`thinking` event.
  final String partialText;
  final String partialThinking;
  final int lastSeq;

  /// The engine sent `closed`: the process behind the session ended.
  final bool closed;

  SessionDetail copyWith({
    SessionSummary? summary,
    List<SessionEvent>? events,
    String? partialText,
    String? partialThinking,
    int? lastSeq,
    bool? closed,
  }) => SessionDetail(
    summary: summary ?? this.summary,
    events: events ?? this.events,
    partialText: partialText ?? this.partialText,
    partialThinking: partialThinking ?? this.partialThinking,
    lastSeq: lastSeq ?? this.lastSeq,
    closed: closed ?? this.closed,
  );
}

sealed class SessionEvent {
  const SessionEvent(this.at);

  final String at;
}

class UserText extends SessionEvent {
  const UserText(super.at, this.text, {this.images = const []});

  final String text;

  /// Attachment names kept by the engine (`/api/sessions/:id/attachments/:name`).
  final List<String> images;
}

class AssistantText extends SessionEvent {
  const AssistantText(super.at, this.text);

  final String text;
}

class Thinking extends SessionEvent {
  const Thinking(super.at, this.text, {this.seconds});

  final String text;
  final int? seconds;
}

class ToolCall extends SessionEvent {
  const ToolCall(
    super.at, {
    required this.id,
    required this.name,
    required this.summary,
    this.result,
    this.isError = false,
    this.interrupted = false,
  });

  final String id;
  final String name;
  final String summary;
  final String? result;
  final bool isError;
  final bool interrupted;

  bool get running => result == null && !interrupted;

  ToolCall copyWith({String? result, bool? isError, bool? interrupted}) => ToolCall(
    at,
    id: id,
    name: name,
    summary: summary,
    result: result ?? this.result,
    isError: isError ?? this.isError,
    interrupted: interrupted ?? this.interrupted,
  );
}

enum PermissionDecision { allow, always, deny, answer, aborted }

class DiffLine {
  const DiffLine(this.kind, this.text, [this.number]);

  /// ' ' context, '+' added, '-' removed
  final String kind;
  final String text;
  final int? number;
}

/// A `permission` (or `AskUserQuestion`) the engine is holding until the user decides.
sealed class PendingRequest extends SessionEvent {
  const PendingRequest(super.at, {required this.requestId, required this.seq, this.decision, this.expired = false});

  final String requestId;
  final int seq;
  final PermissionDecision? decision;

  /// No `permission_resolved` and the process that asked is gone (detached or reattached since).
  final bool expired;

  bool get pending => decision == null && !expired;

  PendingRequest resolve(PermissionDecision decision, {Map<String, String>? answers});

  PendingRequest expire();
}

class PermissionRequest extends PendingRequest {
  const PermissionRequest(
    super.at, {
    required super.requestId,
    required super.seq,
    required this.toolName,
    required this.target,
    this.diff = const [],
    this.command,
    super.decision,
    super.expired,
  });

  final String toolName;
  final String target;
  final List<DiffLine> diff;
  final String? command;

  PermissionRequest _copy({PermissionDecision? decision, bool? expired}) => PermissionRequest(
    at,
    requestId: requestId,
    seq: seq,
    toolName: toolName,
    target: target,
    diff: diff,
    command: command,
    decision: decision ?? this.decision,
    expired: expired ?? this.expired,
  );

  @override
  PermissionRequest resolve(PermissionDecision decision, {Map<String, String>? answers}) => _copy(decision: decision);

  @override
  PermissionRequest expire() => _copy(expired: true);
}

class QuestionOption {
  const QuestionOption(this.label, this.description);

  final String label;
  final String description;
}

class Question {
  const Question({required this.question, required this.header, required this.options, this.multiSelect = false});

  final String question;
  final String header;
  final List<QuestionOption> options;
  final bool multiSelect;
}

class QuestionRequest extends PendingRequest {
  const QuestionRequest(
    super.at, {
    required super.requestId,
    required super.seq,
    required this.questions,
    this.answers,
    super.decision,
    super.expired,
  });

  final List<Question> questions;

  /// `{question: label}`; only known when the answer was sent from this client.
  final Map<String, String>? answers;

  QuestionRequest _copy({PermissionDecision? decision, Map<String, String>? answers, bool? expired}) => QuestionRequest(
    at,
    requestId: requestId,
    seq: seq,
    questions: questions,
    answers: answers ?? this.answers,
    decision: decision ?? this.decision,
    expired: expired ?? this.expired,
  );

  @override
  QuestionRequest resolve(PermissionDecision decision, {Map<String, String>? answers}) =>
      _copy(decision: decision, answers: answers);

  @override
  QuestionRequest expire() => _copy(expired: true);
}

class SessionResult extends SessionEvent {
  const SessionResult(
    super.at, {
    required this.isError,
    required this.cost,
    required this.seconds,
    required this.turns,
    this.message,
  });

  final bool isError;
  final double cost;
  final int seconds;
  final int turns;

  /// The provider's text for a failed turn; `null` on success.
  final String? message;
}

class SessionError extends SessionEvent {
  const SessionError(super.at, this.message);

  final String message;
}

enum SessionNoteKind { imported, forked }

/// A line between turns about the session itself, not the conversation.
class SessionNote extends SessionEvent {
  const SessionNote(super.at, this.kind, {this.dropped = 0});

  final SessionNoteKind kind;

  /// Older terminal events left out when the session was imported (the engine keeps the last ones).
  final int dropped;
}

/// The terminal's `/app` asking the app to bring session [sdkSessionId] (run at [cwd]) in and open it.
typedef TerminalHandoff = ({String sdkSessionId, String cwd});

/// A Claude Code session started in a terminal, as the engine lists it from the CLI's transcripts.
class TerminalSession {
  const TerminalSession({
    required this.sdkSessionId,
    required this.cwd,
    required this.title,
    required this.updatedAt,
    this.firstPrompt,
    this.live,
  });

  final String sdkSessionId;

  /// Where the terminal ran it: the project root or one of its subfolders. Resuming has to happen there.
  final String cwd;
  final String title;
  final String? firstPrompt;
  final DateTime updatedAt;

  /// The CLI's status (`busy`, `idle`) while its process is alive; `null` once the terminal closed it.
  final String? live;
}

class PaletteSkill {
  const PaletteSkill(this.name, this.description);

  final String name;
  final String description;
}

class AgentAccountStatus {
  const AgentAccountStatus({required this.account, required this.loggedIn, required this.loginCommand});

  final String account;
  final bool loggedIn;
  final String loginCommand;
}

class AgentModel {
  const AgentModel(this.id, this.label, {this.quota});

  final String id;
  final String label;

  /// Weekly quota of the model's group (Antigravity `/quota`); `null` when unknown (Anthropic, or `/quota` failed).
  final AgentQuota? quota;
}

class AgentQuota {
  const AgentQuota({required this.remaining, this.resetsAt});

  /// 0..1 of the weekly limit left.
  final double remaining;
  final DateTime? resetsAt;

  bool get exhausted => remaining <= 0;

  /// `97% · renova em 6d 19h`, or `esgotado · renova em 2h 5min`.
  String label(DateTime now) {
    final left = exhausted ? 'esgotado' : '${(remaining * 100).round()}%';
    final reset = resetsAt;
    if (reset == null) return left;
    final wait = reset.difference(now);
    if (wait.isNegative) return '$left · renovando';
    final parts = [
      if (wait.inDays > 0) '${wait.inDays}d',
      if (wait.inHours % 24 > 0) '${wait.inHours % 24}h',
      if (wait.inDays == 0 && wait.inMinutes % 60 > 0) '${wait.inMinutes % 60}min',
    ];
    return '$left · renova em ${parts.isEmpty ? 'instantes' : parts.join(' ')}';
  }
}

/// File the Antigravity agent wrote to its conversation folder ("artefato de sessão").
class SessionArtifact {
  const SessionArtifact({required this.name, required this.size, required this.modifiedAt});

  final String name;
  final int size;
  final String modifiedAt;
}

/// Image picked or pasted in the composer, sent with the next message.
class ImageAttachment {
  const ImageAttachment(this.mediaType, this.bytes);

  final String mediaType;
  final Uint8List bytes;

  /// `null` when [bytes] is not PNG, JPEG, GIF or WebP, the formats the models read.
  static String? mediaTypeOf(Uint8List bytes) {
    bool starts(List<int> magic, [int offset = 0]) =>
        bytes.length >= offset + magic.length &&
        Iterable<int>.generate(magic.length).every((i) => bytes[offset + i] == magic[i]);
    if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
    if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
    if (starts(const [0x52, 0x49, 0x46, 0x46]) && starts(const [0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp';
    return null;
  }
}

/// What the app needs before the first session (`GET /api/readiness`): Claude Code and `gh` logged in.
class Readiness {
  const Readiness({
    required this.claudeOk,
    this.claudeAccount,
    this.claudePlan,
    this.claudeError,
    required this.ghOk,
    this.ghActive,
    this.ghError,
  });

  final bool claudeOk;
  final String? claudeAccount;
  final String? claudePlan;
  final String? claudeError;
  final bool ghOk;
  final String? ghActive;
  final String? ghError;
}
