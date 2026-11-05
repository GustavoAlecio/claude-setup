enum SessionStatus { starting, running, idle, waitingPermission, done, stopped, error, detached }

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.project,
    required this.command,
    required this.title,
    required this.status,
    required this.createdAt,
    this.cost = 0,
    this.pendingPermissions = 0,
    this.resumable = false,
    this.model,
  });

  final String id;
  final String project;
  final String command;
  final String title;
  final SessionStatus status;

  /// ISO-8601 as sent by the engine.
  final String createdAt;
  final double cost;
  final int pendingPermissions;
  final bool resumable;
  final String? model;

  SessionSummary copyWith({SessionStatus? status, double? cost, int? pendingPermissions, String? model}) =>
      SessionSummary(
        id: id,
        project: project,
        command: command,
        title: title,
        status: status ?? this.status,
        createdAt: createdAt,
        cost: cost ?? this.cost,
        pendingPermissions: pendingPermissions ?? this.pendingPermissions,
        resumable: resumable,
        model: model ?? this.model,
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
  const UserText(super.at, this.text);

  final String text;
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
  });

  final bool isError;
  final double cost;
  final int seconds;
  final int turns;
}

class SessionError extends SessionEvent {
  const SessionError(super.at, this.message);

  final String message;
}

class PaletteSkill {
  const PaletteSkill(this.name, this.description);

  final String name;
  final String description;
}
