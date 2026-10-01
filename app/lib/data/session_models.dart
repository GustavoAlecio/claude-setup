enum SessionStatus { starting, running, idle, waitingPermission, done, stopped, error, detached }

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.project,
    required this.command,
    required this.title,
    required this.status,
    required this.startedAt,
    required this.cost,
    required this.model,
    required this.cwd,
    required this.events,
    this.resumable = false,
  });

  final String id;
  final String project;
  final String command;
  final String title;
  final SessionStatus status;
  final String startedAt;
  final double cost;
  final String model;
  final String cwd;
  final List<SessionEvent> events;
  final bool resumable;

  int get pendingPermissions => events
      .where((e) => (e is PermissionRequest && e.decision == null) || (e is QuestionRequest && e.answer == null))
      .length;
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
  const Thinking(super.at, this.text, {required this.seconds});

  final String text;
  final int seconds;
}

class ToolCall extends SessionEvent {
  const ToolCall(super.at, {required this.name, required this.summary, this.result, this.isError = false});

  final String name;
  final String summary;
  final String? result;
  final bool isError;

  bool get running => result == null;
}

enum PermissionDecision { allow, always, deny }

class DiffLine {
  const DiffLine(this.kind, this.text, [this.number]);

  /// ' ' context, '+' added, '-' removed
  final String kind;
  final String text;
  final int? number;
}

class PermissionRequest extends SessionEvent {
  const PermissionRequest(
    super.at, {
    required this.toolName,
    required this.target,
    this.diff = const [],
    this.command,
    this.decision,
  });

  final String toolName;
  final String target;
  final List<DiffLine> diff;
  final String? command;
  final PermissionDecision? decision;
}

class QuestionOption {
  const QuestionOption(this.label, this.description);

  final String label;
  final String description;
}

class QuestionRequest extends SessionEvent {
  const QuestionRequest(
    super.at, {
    required this.header,
    required this.question,
    required this.options,
    this.multiSelect = false,
    this.answer,
  });

  final String header;
  final String question;
  final List<QuestionOption> options;
  final bool multiSelect;
  final String? answer;
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
