import 'dart:convert';

import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/session_reducer.dart';
import 'package:claude_flow/data/sse.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _summary = SessionSummary(
  id: 's1',
  project: 'demo',
  command: '/fix',
  title: '/fix',
  status: SessionStatus.running,
  createdAt: '2026-03-10T14:41:00Z',
);

SseFrame _event(int seq, Map<String, Object?> e) =>
    SseFrame('event', jsonEncode({'seq': seq, 'at': '2026-03-10T14:41:00Z', ...e}));

SseFrame _status(String s) => SseFrame('status', jsonEncode({'status': s}));

SseFrame _delta(String text, {String kind = 'text'}) => SseFrame('delta', jsonEncode({'kind': kind, 'text': text}));

SessionDetail _reduce(List<SseFrame> frames, {SessionSummary summary = _summary}) =>
    frames.fold(SessionDetail(summary: summary), applyFrame);

List<String> _lines(List<DiffLine> diff) => [for (final d in diff) '${d.kind}${d.text}'];

void main() {
  group('parseSse', () {
    test('splits complete frames and keeps the incomplete tail', () {
      final (frames, rest) = parseSse('event: status\ndata: {"status":"idle"}\n\nevent: ev');
      expect(frames.single.event, 'status');
      expect(frames.single.data, '{"status":"idle"}');
      expect(rest, 'event: ev');
    });

    test('a frame split across chunks is parsed once complete', () {
      var (frames, rest) = parseSse('event: delta\nda');
      expect(frames, isEmpty);
      (frames, rest) = parseSse('${rest}ta: {"text":"a"}\n\n');
      expect(frames.single.data, '{"text":"a"}');
      expect(rest, '');
    });

    test('ignores keepalive comments, handles CRLF and multi-line data', () {
      final (frames, _) = parseSse(': ping\r\n\r\ndata: a\r\ndata: b\r\n\r\n');
      expect(frames.single.event, 'message');
      expect(frames.single.data, 'a\nb');
    });
  });

  group('applyFrame', () {
    test('tool_use and tool_result fuse by id; summary picks command → file_path → pattern → url → name', () {
      final d = _reduce([
        _event(1, {
          'kind': 'tool_use',
          'id': 't1',
          'name': 'Bash',
          'input': {'command': 'ls', 'file_path': 'x'},
        }),
        _event(2, {
          'kind': 'tool_use',
          'id': 't2',
          'name': 'Read',
          'input': {'file_path': 'a.dart'},
        }),
        _event(3, {
          'kind': 'tool_use',
          'id': 't3',
          'name': 'Grep',
          'input': {'pattern': 'foo'},
        }),
        _event(4, {
          'kind': 'tool_use',
          'id': 't4',
          'name': 'WebFetch',
          'input': {'url': 'https://x'},
        }),
        _event(5, {'kind': 'tool_use', 'id': 't5', 'name': 'TodoWrite', 'input': <String, Object?>{}}),
        _event(6, {'kind': 'tool_result', 'id': 't2', 'text': '12 linhas', 'isError': true}),
      ]);
      final calls = d.events.cast<ToolCall>();
      expect(calls.map((c) => c.summary), ['ls', 'a.dart', 'foo', 'https://x', 'TodoWrite']);
      expect(calls[1].result, '12 linhas');
      expect(calls[1].isError, isTrue);
      expect(calls[1].running, isFalse);
      expect(calls[0].running, isTrue);
    });

    test('Edit becomes a line diff without numbers; MultiEdit concatenates; Write is all +', () {
      final d = _reduce([
        _event(1, {
          'kind': 'permission',
          'requestId': 'r1',
          'toolName': 'Edit',
          'input': {'file_path': 'a.txt', 'old_string': 'a\nb', 'new_string': 'a\nc', 'replace_all': true},
        }),
        _event(2, {
          'kind': 'permission',
          'requestId': 'r2',
          'toolName': 'MultiEdit',
          'input': {
            'file_path': 'b.txt',
            'edits': [
              {'old_string': 'x', 'new_string': 'y'},
              {'old_string': 'k', 'new_string': 'k\nz'},
            ],
          },
        }),
        _event(3, {
          'kind': 'permission',
          'requestId': 'r3',
          'toolName': 'Write',
          'input': {'file_path': 'c.txt', 'content': 'one\ntwo'},
        }),
        _event(4, {
          'kind': 'permission',
          'requestId': 'r4',
          'toolName': 'Bash',
          'input': {'command': 'rm -rf build', 'description': 'limpa build'},
        }),
      ]);
      final reqs = d.events.cast<PermissionRequest>();
      expect(_lines(reqs[0].diff), [' a', '-b', '+c']);
      expect(reqs[0].diff.every((l) => l.number == null), isTrue);
      expect(reqs[0].target, 'a.txt');
      expect(_lines(reqs[1].diff), ['-x', '+y', ' k', '+z']);
      expect(_lines(reqs[2].diff), ['+one', '+two']);
      expect(reqs[3].command, 'rm -rf build');
      expect(reqs[3].target, 'limpa build');
      expect(reqs[3].diff, isEmpty);
      expect(d.summary.pendingPermissions, 4);
    });

    test('AskUserQuestion becomes a QuestionRequest with every question', () {
      final d = _reduce([
        _event(1, {
          'kind': 'permission',
          'requestId': 'r1',
          'toolName': 'AskUserQuestion',
          'input': {
            'questions': [
              {
                'question': 'Qual?',
                'header': 'H1',
                'multiSelect': false,
                'options': [
                  {'label': 'A', 'description': 'a'},
                  {'label': 'B', 'description': 'b'},
                ],
              },
              {
                'question': 'Quais?',
                'header': 'H2',
                'multiSelect': true,
                'options': [
                  {'label': 'X', 'description': 'x'},
                  {'label': 'Y', 'description': 'y'},
                ],
              },
            ],
          },
        }),
      ]);
      final q = d.events.single as QuestionRequest;
      expect(q.requestId, 'r1');
      expect(q.questions.map((e) => e.header), ['H1', 'H2']);
      expect(q.questions[1].multiSelect, isTrue);
      expect(q.questions[0].options.map((o) => o.label), ['A', 'B']);
      expect(q.pending, isTrue);
    });

    test('permission_resolved resolves the matching request, including aborted', () {
      final d = _reduce([
        _event(1, {'kind': 'permission', 'requestId': 'r1', 'toolName': 'Read', 'input': <String, Object?>{}}),
        _event(2, {'kind': 'permission', 'requestId': 'r2', 'toolName': 'Read', 'input': <String, Object?>{}}),
        _event(3, {'kind': 'permission', 'requestId': 'r3', 'toolName': 'Read', 'input': <String, Object?>{}}),
        _event(4, {'kind': 'permission_resolved', 'requestId': 'r1', 'decision': 'allow'}),
        _event(5, {'kind': 'permission_resolved', 'requestId': 'r3', 'decision': 'aborted'}),
      ]);
      final reqs = d.events.cast<PermissionRequest>();
      expect(reqs.map((r) => r.decision), [PermissionDecision.allow, null, PermissionDecision.aborted]);
      expect(d.summary.pendingPermissions, 1);
    });

    test('deltas accumulate and are replaced by the final event without duplicating', () {
      var d = _reduce([_delta('Ol'), _delta('á, '), _delta('mundo')]);
      expect(d.partialText, 'Olá, mundo');
      expect(d.events, isEmpty);
      d = applyFrame(d, _event(1, {'kind': 'assistant_text', 'text': 'Olá, mundo'}));
      expect(d.partialText, '');
      expect(d.events.whereType<AssistantText>().map((e) => e.text), ['Olá, mundo']);

      d = applyFrame(d, _delta('hmm', kind: 'thinking'));
      expect(d.partialThinking, 'hmm');
      d = applyFrame(d, _event(2, {'kind': 'thinking', 'text': 'hmm'}));
      expect(d.partialThinking, '');
      expect((d.events.last as Thinking).seconds, isNull);
    });

    test('withoutPartial drops the buffer on reconnect', () {
      final d = withoutPartial(_reduce([_delta('meio'), _delta('x', kind: 'thinking')]));
      expect(d.partialText, '');
      expect(d.partialThinking, '');
    });

    test('events at or below lastSeq are ignored', () {
      final d = _reduce([
        _event(1, {'kind': 'user_text', 'text': 'a'}),
        _event(2, {'kind': 'user_text', 'text': 'b'}),
        _event(2, {'kind': 'user_text', 'text': 'b'}),
        _event(1, {'kind': 'user_text', 'text': 'a'}),
      ]);
      expect(d.events.length, 2);
      expect(d.lastSeq, 2);
    });

    test('pending permission expires when the session is detached and stops counting', () {
      final d = _reduce([
        _event(1, {'kind': 'permission', 'requestId': 'r1', 'toolName': 'Edit', 'input': <String, Object?>{}}),
        _status('detached'),
      ]);
      final r = d.events.single as PermissionRequest;
      expect(r.expired, isTrue);
      expect(r.pending, isFalse);
      expect(d.summary.pendingPermissions, 0);
    });

    test('permission before the last reattached expires; one after it stays pending', () {
      final d = _reduce([
        _event(1, {'kind': 'permission', 'requestId': 'r1', 'toolName': 'Edit', 'input': <String, Object?>{}}),
        _event(2, {'kind': 'reattached'}),
        _event(3, {'kind': 'permission', 'requestId': 'r2', 'toolName': 'Edit', 'input': <String, Object?>{}}),
        _status('waiting_permission'),
      ]);
      final reqs = d.events.cast<PermissionRequest>();
      expect(reqs.map((r) => r.expired), [true, false]);
      expect(d.summary.pendingPermissions, 1);
    });

    test('replay of a resumed session that started detached keeps the permission after reattached', () {
      final d = _reduce([
        _event(1, {'kind': 'permission', 'requestId': 'r1', 'toolName': 'Edit', 'input': <String, Object?>{}}),
        _event(2, {'kind': 'reattached'}),
        _event(3, {'kind': 'permission', 'requestId': 'r2', 'toolName': 'Edit', 'input': <String, Object?>{}}),
        _status('waiting_permission'),
      ], summary: _summary.copyWith(status: SessionStatus.detached));
      expect(d.events.cast<PermissionRequest>().map((r) => r.expired), [true, false]);
      expect(d.summary.pendingPermissions, 1);
    });

    test('running ToolCall is interrupted when the status leaves running/waiting_permission', () {
      var d = _reduce([
        _event(1, {'kind': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': <String, Object?>{}}),
        _status('waiting_permission'),
      ]);
      expect((d.events.single as ToolCall).running, isTrue);
      d = applyFrame(d, _status('idle'));
      final call = d.events.single as ToolCall;
      expect(call.interrupted, isTrue);
      expect(call.running, isFalse);
      expect(d.summary.status, SessionStatus.idle);
    });

    test('init sets the model, result adds SessionResult and cost, error and closed', () {
      final d = _reduce([
        _event(1, {'kind': 'init', 'model': 'claude-opus'}),
        _event(2, {'kind': 'result', 'isError': false, 'cost': 0.5, 'durationMs': 61500, 'numTurns': 3}),
        _event(3, {'kind': 'error', 'message': 'boom'}),
        const SseFrame('closed', '{}'),
      ]);
      expect(d.summary.model, 'claude-opus');
      expect(d.summary.cost, 0.5);
      final result = d.events.whereType<SessionResult>().single;
      expect(result.seconds, 61);
      expect(result.turns, 3);
      expect((d.events.last as SessionError).message, 'boom');
      expect(d.closed, isTrue);
    });

    test('permission_mode sets the summary mode; an unknown mode is ignored', () {
      final d = _reduce([
        _event(1, {'kind': 'permission_mode', 'mode': 'bypassPermissions'}),
        _status('idle'),
      ]);
      expect(_summary.permissionMode, PermissionMode.defaultMode);
      expect(d.summary.permissionMode, PermissionMode.bypassPermissions);
      expect(d.summary.status, SessionStatus.idle);
      expect(d.lastSeq, 1);

      final ignored = applyFrame(d, _event(2, {'kind': 'permission_mode', 'mode': 'plan'}));
      expect(ignored.summary.permissionMode, PermissionMode.bypassPermissions);
      expect(ignored.lastSeq, 2);
    });

    test('status, pending and model changes keep the mode', () {
      final d = _reduce([
        _event(1, {'kind': 'init', 'model': 'claude-opus'}),
        _event(2, {
          'kind': 'permission',
          'requestId': 'r1',
          'toolName': 'Bash',
          'input': {'command': 'ls'},
        }),
        _status('waiting_permission'),
      ], summary: _summary.copyWith(permissionMode: PermissionMode.acceptEdits));
      expect((d.summary.permissionMode, d.summary.pendingPermissions), (PermissionMode.acceptEdits, 1));
    });

    test('every engine status maps 1:1', () {
      const expected = {
        'starting': SessionStatus.starting,
        'running': SessionStatus.running,
        'idle': SessionStatus.idle,
        'waiting_permission': SessionStatus.waitingPermission,
        'done': SessionStatus.done,
        'stopped': SessionStatus.stopped,
        'error': SessionStatus.error,
        'detached': SessionStatus.detached,
      };
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(applyFrame(const SessionDetail(summary: _summary), _status(key)).summary.status, value, reason: key);
      }
    });
  });

  group('answersFor', () {
    const questions = [
      Question(question: 'Qual?', header: 'H1', options: [QuestionOption('A', ''), QuestionOption('B', '')]),
      Question(
        question: 'Quais?',
        header: 'H2',
        multiSelect: true,
        options: [QuestionOption('X', ''), QuestionOption('Y', ''), QuestionOption('Z', '')],
      ),
    ];

    test('maps question → label, joining multiSelect labels with ", " in option order', () {
      expect(
        answersFor(questions, {
          'Qual?': {'B'},
          'Quais?': {'Z', 'X'},
        }),
        {'Qual?': 'B', 'Quais?': 'X, Z'},
      );
    });

    test('free text replaces the selection', () {
      expect(
        answersFor(
          questions,
          {
            'Qual?': {'A'},
          },
          free: {'Qual?': ' outra coisa '},
        ),
        {'Qual?': 'outra coisa'},
      );
    });
  });

  group('sessions list', () {
    SessionSummary s(String id, String project, SessionStatus status, int pending) => SessionSummary(
      id: id,
      project: project,
      command: '/x',
      title: id,
      status: status,
      createdAt: '',
      pendingPermissions: pending,
    );

    test('pendingByProject counts only running, waiting_permission and idle sessions', () {
      final list = [
        s('a', 'p1', SessionStatus.waitingPermission, 1),
        s('b', 'p1', SessionStatus.idle, 2),
        s('c', 'p1', SessionStatus.detached, 5),
        s('d', 'p2', SessionStatus.running, 1),
        s('e', 'p2', SessionStatus.done, 3),
        s('f', 'p3', SessionStatus.stopped, 1),
      ];
      expect(pendingByProject(list), {'p1': 3, 'p2': 1});
    });

    test('pendingByProject leaves org sessions out', () {
      const activity = SessionSummary(
        id: 'o',
        project: '',
        command: '/x',
        title: 'o',
        status: SessionStatus.waitingPermission,
        createdAt: '',
        pendingPermissions: 2,
        org: 'OTG',
        cwd: '/dev/otg',
      );
      expect(pendingByProject([activity, s('a', 'p1', SessionStatus.idle, 1)]), {'p1': 1});
    });

    test('snapshot replaces, summary upserts, removed drops', () {
      Map<String, Object?> json(String id, String status) => {
        'id': id,
        'project': 'p',
        'command': '/x',
        'title': id,
        'status': status,
        'createdAt': '',
        'cost': 0,
        'pendingPermissions': 0,
        'resumable': false,
        'model': null,
      };
      var list = applySessionsFrame(const [], SseFrame('snapshot', jsonEncode([json('a', 'idle')])));
      list = applySessionsFrame(list, SseFrame('summary', jsonEncode(json('b', 'running'))));
      list = applySessionsFrame(list, SseFrame('summary', jsonEncode(json('a', 'done'))));
      expect(list.map((e) => (e.id, e.status)), [('b', SessionStatus.running), ('a', SessionStatus.done)]);
      list = applySessionsFrame(list, SseFrame('removed', jsonEncode({'id': 'b'})));
      expect(list.map((e) => e.id), ['a']);
    });

    test('parseSummary reads permissionMode; absent or invalid is default', () {
      Map<String, Object?> json(Object? mode) => {'id': 'a', 'status': 'idle', 'permissionMode': ?mode};
      expect(parseSummary(json('bypassPermissions')).permissionMode, PermissionMode.bypassPermissions);
      expect(parseSummary(json('auto')).permissionMode, PermissionMode.auto);
      expect(parseSummary(json(null)).permissionMode, PermissionMode.defaultMode);
      expect(parseSummary(json('plan')).permissionMode, PermissionMode.defaultMode);
      final list = applySessionsFrame(const [], SseFrame('summary', jsonEncode(json('acceptEdits'))));
      expect(list.single.permissionMode, PermissionMode.acceptEdits);
    });
  });
}
