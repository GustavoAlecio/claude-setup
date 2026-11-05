import 'dart:convert';
import 'dart:developer';

import 'session_models.dart';
import 'sse.dart';

const _liveTools = {SessionStatus.starting, SessionStatus.running, SessionStatus.waitingPermission};
const _awaitingUser = {SessionStatus.running, SessionStatus.waitingPermission, SessionStatus.idle};

SessionStatus parseStatus(Object? raw) => switch (raw) {
  'starting' => SessionStatus.starting,
  'running' => SessionStatus.running,
  'idle' => SessionStatus.idle,
  'waiting_permission' => SessionStatus.waitingPermission,
  'done' => SessionStatus.done,
  'stopped' => SessionStatus.stopped,
  'error' => SessionStatus.error,
  'detached' => SessionStatus.detached,
  _ => SessionStatus.error,
};

PermissionDecision? parseDecision(Object? raw) => PermissionDecision.values.where((d) => d.name == raw).firstOrNull;

SessionSummary parseSummary(Map<String, dynamic> json) => SessionSummary(
  id: json['id'] as String,
  project: json['project'] as String? ?? '',
  command: json['command'] as String? ?? '',
  title: json['title'] as String? ?? json['command'] as String? ?? '',
  status: parseStatus(json['status']),
  createdAt: json['createdAt'] as String? ?? '',
  cost: (json['cost'] as num?)?.toDouble() ?? 0,
  pendingPermissions: (json['pendingPermissions'] as num?)?.toInt() ?? 0,
  resumable: json['resumable'] == true,
  model: json['model'] as String?,
  cwd: json['cwd'] as String?,
  org: json['org'] as String?,
  additionalDirectories: [if (json['additionalDirectories'] case final List<dynamic> dirs) ...dirs.whereType<String>()],
);

/// Badge "aguardando você": only sessions whose process can still act on the answer.
int pendingOf(SessionSummary session) => _awaitingUser.contains(session.status) ? session.pendingPermissions : 0;

/// Project badges only: org sessions belong to no project.
Map<String, int> pendingByProject(List<SessionSummary> sessions) {
  final out = <String, int>{};
  for (final s in sessions) {
    final n = pendingOf(s);
    if (n == 0 || s.isOrgSession) continue;
    out[s.project] = (out[s.project] ?? 0) + n;
  }
  return out;
}

/// Global stream (`/api/sessions/stream`): `snapshot`, `summary` and `removed`.
List<SessionSummary> applySessionsFrame(List<SessionSummary> list, SseFrame frame) {
  final data = _decode(frame);
  switch (frame.event) {
    case 'snapshot' when data is List:
      return [for (final s in data.whereType<Map<String, dynamic>>()) parseSummary(s)];
    case 'summary' when data is Map<String, dynamic>:
      return upsertSummary(list, parseSummary(data));
    case 'removed' when data is Map<String, dynamic>:
      return list.where((s) => s.id != data['id']).toList();
    default:
      return list;
  }
}

List<SessionSummary> upsertSummary(List<SessionSummary> list, SessionSummary summary) {
  final i = list.indexWhere((s) => s.id == summary.id);
  if (i < 0) return [summary, ...list];
  return [...list]..[i] = summary;
}

/// Per-session stream (`/api/sessions/:id/stream`): `event`, `status`, `delta` and `closed`.
SessionDetail applyFrame(SessionDetail state, SseFrame frame) {
  switch (frame.event) {
    case 'event':
      final data = _decode(frame);
      if (data is! Map<String, dynamic>) return state;
      final seq = (data['seq'] as num?)?.toInt();
      if (seq == null || seq <= state.lastSeq) return state;
      return _applyEvent(state, data, seq).copyWith(lastSeq: seq);
    case 'status':
      final data = _decode(frame);
      if (data is! Map<String, dynamic>) return state;
      return _applyStatus(state, parseStatus(data['status']));
    case 'delta':
      final data = _decode(frame);
      if (data is! Map<String, dynamic>) return state;
      final text = data['text'] as String? ?? '';
      return data['kind'] == 'thinking'
          ? state.copyWith(partialThinking: state.partialThinking + text)
          : state.copyWith(partialText: state.partialText + text);
    case 'closed':
      return state.copyWith(closed: true);
    default:
      return state;
  }
}

/// Deltas are not in the replay log: whatever was buffered before a reconnect is stale.
SessionDetail withoutPartial(SessionDetail state) =>
    state.copyWith(partialText: '', partialThinking: '', closed: false);

/// `{question: label}`; multiSelect joins labels with `, ` in option order; free text replaces the selection.
Map<String, String> answersFor(
  List<Question> questions,
  Map<String, Set<String>> picked, {
  Map<String, String> free = const {},
}) {
  final out = <String, String>{};
  for (final q in questions) {
    final text = free[q.question]?.trim() ?? '';
    if (text.isNotEmpty) {
      out[q.question] = text;
      continue;
    }
    final chosen = picked[q.question] ?? const {};
    final labels = q.options.map((o) => o.label).where(chosen.contains);
    if (labels.isNotEmpty) out[q.question] = labels.join(', ');
  }
  return out;
}

String toolSummary(String name, Map<String, dynamic> input) {
  for (final key in const ['command', 'file_path', 'pattern', 'url']) {
    final v = input[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return name;
}

List<DiffLine> diffFor(String toolName, Map<String, dynamic> input) {
  switch (toolName) {
    case 'Edit':
      return lineDiff(input['old_string'] as String? ?? '', input['new_string'] as String? ?? '');
    case 'MultiEdit':
      final edits = (input['edits'] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
      return [for (final e in edits) ...lineDiff(e['old_string'] as String? ?? '', e['new_string'] as String? ?? '')];
    case 'Write':
      return [for (final l in (input['content'] as String? ?? '').split('\n')) DiffLine('+', l)];
    default:
      return const [];
  }
}

/// Line-level LCS; on a tie removals come before additions.
List<DiffLine> lineDiff(String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  final lcs = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      out.add(DiffLine(' ', a[i++]));
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add(DiffLine('-', a[i++]));
    } else {
      out.add(DiffLine('+', b[j++]));
    }
  }
  while (i < a.length) {
    out.add(DiffLine('-', a[i++]));
  }
  while (j < b.length) {
    out.add(DiffLine('+', b[j++]));
  }
  return out;
}

Object? _decode(SseFrame frame) {
  try {
    return jsonDecode(frame.data);
  } on FormatException catch (e) {
    log('malformed ${frame.event} frame', name: 'session_reducer', error: e);
    return null;
  }
}

SessionDetail _applyEvent(SessionDetail state, Map<String, dynamic> e, int seq) {
  final at = e['at'] as String? ?? '';
  final events = state.events;
  switch (e['kind']) {
    case 'user_text':
      return state.copyWith(events: [...events, UserText(at, e['text'] as String? ?? '')]);
    case 'assistant_text':
      return state.copyWith(
        events: [...events, AssistantText(at, e['text'] as String? ?? '')],
        partialText: '',
        partialThinking: '',
      );
    case 'thinking':
      return state.copyWith(events: [...events, Thinking(at, e['text'] as String? ?? '')], partialThinking: '');
    case 'tool_use':
      final name = e['name'] as String? ?? '';
      final call = ToolCall(at, id: e['id'] as String? ?? '', name: name, summary: toolSummary(name, _map(e['input'])));
      return state.copyWith(events: [...events, call]);
    case 'tool_result':
      return state.copyWith(
        events: [
          for (final ev in events)
            ev is ToolCall && ev.id == e['id']
                ? ev.copyWith(result: e['text'] as String? ?? '', isError: e['isError'] == true)
                : ev,
        ],
      );
    case 'permission':
      final request = _request(at, seq, e);
      final detached = state.summary.status == SessionStatus.detached;
      return _withRequests(state, [...events, if (detached) request.expire() else request]);
    case 'permission_resolved':
      final decision = parseDecision(e['decision']);
      if (decision == null) return state;
      final answers = e['answers'] is Map ? Map<String, String>.from(e['answers'] as Map) : null;
      return _withRequests(state, [
        for (final ev in events)
          ev is PendingRequest && ev.requestId == e['requestId'] ? ev.resolve(decision, answers: answers) : ev,
      ]);
    case 'reattached':
      // The engine sets `idle` right after `reattached`; replay only sends the final status at the end.
      final status = state.summary.status == SessionStatus.detached ? SessionStatus.idle : null;
      return _withRequests(state.copyWith(summary: state.summary.copyWith(status: status)), [
        for (final ev in events) ev is PendingRequest && ev.pending && ev.seq < seq ? ev.expire() : ev,
      ]);
    case 'result':
      final cost = (e['cost'] as num?)?.toDouble() ?? state.summary.cost;
      final result = SessionResult(
        at,
        isError: e['isError'] == true,
        cost: cost,
        seconds: ((e['durationMs'] as num?) ?? 0) ~/ 1000,
        turns: (e['numTurns'] as num?)?.toInt() ?? 0,
      );
      return state.copyWith(
        events: [...events, result],
        summary: state.summary.copyWith(cost: cost),
      );
    case 'error':
      return state.copyWith(events: [...events, SessionError(at, e['message'] as String? ?? '')]);
    case 'init':
      final model = e['model'] as String?;
      return model == null ? state : state.copyWith(summary: state.summary.copyWith(model: model));
    default:
      return state;
  }
}

SessionDetail _applyStatus(SessionDetail state, SessionStatus status) {
  final stopsTools = !_liveTools.contains(status);
  final detached = status == SessionStatus.detached;
  final events = [
    for (final ev in state.events)
      if (stopsTools && ev is ToolCall && ev.running)
        ev.copyWith(interrupted: true)
      else if (detached && ev is PendingRequest && ev.pending)
        ev.expire()
      else
        ev,
  ];
  return _withRequests(state.copyWith(summary: state.summary.copyWith(status: status)), events);
}

SessionDetail _withRequests(SessionDetail state, List<SessionEvent> events) => state.copyWith(
  events: events,
  summary: state.summary.copyWith(
    pendingPermissions: events.whereType<PendingRequest>().where((r) => r.pending).length,
  ),
);

PendingRequest _request(String at, int seq, Map<String, dynamic> e) {
  final requestId = e['requestId'] as String? ?? '';
  final toolName = e['toolName'] as String? ?? '';
  final input = _map(e['input']);
  if (toolName == 'AskUserQuestion') {
    return QuestionRequest(at, requestId: requestId, seq: seq, questions: _questions(input['questions']));
  }
  final command = input['command'] as String?;
  return PermissionRequest(
    at,
    requestId: requestId,
    seq: seq,
    toolName: toolName,
    target: command == null ? toolSummary(toolName, input) : input['description'] as String? ?? '',
    diff: diffFor(toolName, input),
    command: command,
  );
}

List<Question> _questions(Object? raw) => [
  for (final q in (raw is List ? raw : const []).whereType<Map<String, dynamic>>())
    Question(
      question: q['question'] as String? ?? '',
      header: q['header'] as String? ?? '',
      multiSelect: q['multiSelect'] == true,
      options: [
        for (final o in (q['options'] is List ? q['options'] as List : const []).whereType<Map<String, dynamic>>())
          QuestionOption(o['label'] as String? ?? '', o['description'] as String? ?? ''),
      ],
    ),
];

Map<String, dynamic> _map(Object? raw) => raw is Map<String, dynamic> ? raw : const {};
