import 'dart:convert';
import 'dart:typed_data';

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
          'toolUseID': 'tu1',
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
      expect(q.toolUseId, 'tu1');
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

    test('a last reattached marks the session interrupted until a new message', () {
      var d = _reduce([
        _event(1, {'kind': 'user_text', 'text': '/plan'}),
        _event(2, {'kind': 'assistant_text', 'text': 'feito'}),
        _event(3, {'kind': 'reattached'}),
        _status('idle'),
      ], summary: _summary.copyWith(status: SessionStatus.detached));
      expect(d.summary.interrupted, isTrue);
      expect(d.summary.status, SessionStatus.idle);

      d = applyFrame(d, _event(4, {'kind': 'permission_mode', 'mode': 'dontAsk'}));
      expect(d.summary.interrupted, isTrue);

      d = applyFrame(d, _event(5, {'kind': 'user_text', 'text': 'continue'}));
      expect(d.summary.interrupted, isFalse);
    });

    test('the model acting on its own after reattached clears interrupted', () {
      final d = _reduce([
        _event(1, {'kind': 'reattached'}),
        _event(2, {'kind': 'permission', 'requestId': 'r2', 'toolName': 'Edit', 'input': <String, Object?>{}}),
        _status('waiting_permission'),
      ]);
      expect(d.summary.interrupted, isFalse);
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

      final ignored = applyFrame(d, _event(2, {'kind': 'permission_mode', 'mode': 'dontAsk'}));
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

  group('isLive / showsInterrupted', () {
    test('isLive: só processo que ainda age (running, waitingPermission, idle)', () {
      expect(
        {for (final s in SessionStatus.values) s: isLive(s)},
        {
          SessionStatus.starting: false,
          SessionStatus.running: true,
          SessionStatus.waitingPermission: true,
          SessionStatus.idle: true,
          SessionStatus.done: false,
          SessionStatus.stopped: false,
          SessionStatus.error: false,
          SessionStatus.detached: false,
        },
      );
    });

    test('showsInterrupted: interrupted só vale com status idle', () {
      SessionSummary s(SessionStatus status, {required bool interrupted}) => SessionSummary(
        id: 'x',
        project: 'p',
        command: '/x',
        title: 'x',
        status: status,
        createdAt: '',
        interrupted: interrupted,
      );
      expect(s(SessionStatus.idle, interrupted: true).showsInterrupted, isTrue);
      expect(s(SessionStatus.idle, interrupted: false).showsInterrupted, isFalse);
      expect(s(SessionStatus.running, interrupted: true).showsInterrupted, isFalse);
      expect(s(SessionStatus.done, interrupted: true).showsInterrupted, isFalse);
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

    test('pendingRequests keeps unresolved, unexpired requests in arrival order', () {
      const question = QuestionRequest('t', requestId: 'q', seq: 2, questions: []);
      const permission = PermissionRequest('t', requestId: 'p', seq: 3, toolName: 'Bash', target: 'ls');
      const detail = SessionDetail(
        summary: _summary,
        events: [
          UserText('t', '/plan'),
          question,
          permission,
          QuestionRequest('t', requestId: 'done', seq: 4, questions: [], decision: PermissionDecision.answer),
          PermissionRequest('t', requestId: 'old', seq: 5, toolName: 'Bash', target: 'ls', expired: true),
        ],
      );
      expect([for (final r in pendingRequests(detail)) r.requestId], ['q', 'p']);
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
      expect(parseSummary(json('dontAsk')).permissionMode, PermissionMode.defaultMode);
      final list = applySessionsFrame(const [], SseFrame('summary', jsonEncode(json('acceptEdits'))));
      expect(list.single.permissionMode, PermissionMode.acceptEdits);
    });
  });

  test('parseSummary reads provider and account; their absence is Anthropic', () {
    final agy = parseSummary({'id': 'a', 'provider': 'antigravity', 'account': 'likin.do'});
    expect((agy.provider, agy.account), (AgentProvider.antigravity, 'likin.do'));
    final old = parseSummary({'id': 'b'});
    expect((old.provider, old.account), (AgentProvider.anthropic, null));
  });

  test('ImageAttachment.mediaTypeOf recognizes PNG, JPEG, GIF and WebP by their bytes', () {
    Uint8List b(List<int> bytes) => Uint8List.fromList([...bytes, ...List.filled(12, 0)]);
    expect(ImageAttachment.mediaTypeOf(b([0x89, 0x50, 0x4E, 0x47])), 'image/png');
    expect(ImageAttachment.mediaTypeOf(b([0xFF, 0xD8, 0xFF])), 'image/jpeg');
    expect(ImageAttachment.mediaTypeOf(b([0x47, 0x49, 0x46, 0x38])), 'image/gif');
    expect(ImageAttachment.mediaTypeOf(b([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])), 'image/webp');
    expect(ImageAttachment.mediaTypeOf(b([0x49, 0x49, 0x2A, 0x00])), isNull, reason: 'TIFF');
  });

  test('a user_text with a /skill updates the summary skill; plain text keeps it', () {
    var d = _reduce([
      _event(1, {'kind': 'user_text', 'text': 'me explica'}),
    ]);
    expect(d.summary.skill, isNull);
    d = applyFrame(d, _event(2, {'kind': 'user_text', 'text': '  /kickoff --manual idioma'}));
    expect(d.summary.skill, '/kickoff');
    d = applyFrame(d, _event(3, {'kind': 'user_text', 'text': 'e o default?'}));
    expect(d.summary.skill, '/kickoff');
    expect(parseSummary({'id': 'x', 'skill': '/plan'}).skill, '/plan');
    expect(parseSummary({'id': 'x', 'asideOf': 'p1', 'permissionMode': 'plan'}).asideOf, 'p1');
    expect(parseSummary({'id': 'x', 'permissionMode': 'plan'}).permissionMode, PermissionMode.plan);
  });

  test('parseHandoff reads only well-formed open-terminal frames', () {
    expect(parseHandoff(SseFrame('open-terminal', jsonEncode({'sdkSessionId': 'a', 'cwd': '/x'}))), (
      sdkSessionId: 'a',
      cwd: '/x',
    ));
    expect(parseHandoff(SseFrame('open-terminal', jsonEncode({'sdkSessionId': 'a'}))), isNull);
    expect(parseHandoff(SseFrame('summary', jsonEncode({'sdkSessionId': 'a', 'cwd': '/x'}))), isNull);
  });

  test('imported adds a note and its first reattached is no interruption; forked adds another note', () {
    final detached = _summary.copyWith(status: SessionStatus.detached);
    var d = _reduce([
      _event(1, {'kind': 'user_text', 'text': 'oi'}),
      _event(2, {'kind': 'imported', 'dropped': 12}),
    ], summary: detached);
    expect(d.events.last, isA<SessionNote>().having((n) => n.dropped, 'dropped', 12));
    d = applyFrame(d, _event(3, {'kind': 'reattached', 'forked': true}));
    expect(d.summary.interrupted, isFalse);
    expect(d.summary.status, SessionStatus.idle);
    expect(d.events.last, isA<SessionNote>().having((n) => n.kind, 'kind', SessionNoteKind.forked));
    d = applyFrame(d, _event(4, {'kind': 'reattached'}));
    expect(d.summary.interrupted, isTrue, reason: 'a later reattach is the engine restarting');
  });

  test('user_text keeps the attachment names', () {
    final detail = applyFrame(
      const SessionDetail(
        summary: SessionSummary(
          id: 's',
          project: 'p',
          command: 'c',
          title: 't',
          status: SessionStatus.idle,
          createdAt: '',
        ),
      ),
      SseFrame(
        'event',
        jsonEncode({
          'seq': 1,
          'at': 'x',
          'kind': 'user_text',
          'text': 'oi',
          'images': ['a.png'],
        }),
      ),
    );
    expect((detail.events.single as UserText).images, ['a.png']);
  });

  test('AgentQuota.label: percent or esgotado, then the time to reset', () {
    final now = DateTime.utc(2026, 10, 6, 17);
    expect(
      AgentQuota(remaining: 0.97, resetsAt: DateTime.utc(2026, 10, 13, 12, 12)).label(now),
      '97% · renova em 6d 19h',
    );
    expect(
      AgentQuota(remaining: 0, resetsAt: DateTime.utc(2026, 10, 6, 19, 5)).label(now),
      'esgotado · renova em 2h 5min',
    );
    expect(AgentQuota(remaining: 0, resetsAt: DateTime.utc(2026, 10, 6, 16)).label(now), 'esgotado · renovando');
    expect(const AgentQuota(remaining: 0.5).label(now), '50%');
  });

  group('sessionLine', () {
    final now = DateTime.utc(2026, 3, 10, 15);
    SessionSummary s({
      SessionStatus status = SessionStatus.idle,
      int pending = 0,
      String? aside,
      String createdAt = '2026-03-10T14:41:00Z',
    }) => SessionSummary(
      id: 's',
      project: 'demo',
      command: '/fix',
      title: 't',
      status: status,
      createdAt: createdAt,
      pendingPermissions: pending,
      asideOf: aside,
    );

    test('pending beats running', () {
      expect(sessionLine(s(status: SessionStatus.running, pending: 1), now), 'esperando você');
    });

    test('pending of an ended session does not count', () {
      expect(sessionLine(s(status: SessionStatus.done, pending: 2), now), 'encerrada há 19 min');
    });

    test('running and starting', () {
      expect(sessionLine(s(status: SessionStatus.running), now), 'trabalhando agora');
      expect(sessionLine(s(status: SessionStatus.starting), now), 'trabalhando agora');
    });

    test('aside shows the local HH:mm and beats ended', () {
      final local = DateTime.parse('2026-03-10T14:41:00Z').toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      expect(
        sessionLine(s(aside: 'p', status: SessionStatus.done), now),
        'pergunta à parte · ${two(local.hour)}:${two(local.minute)}',
      );
      expect(sessionLine(s(aside: 'p', createdAt: 'x'), now), 'pergunta à parte');
    });

    test('ended statuses', () {
      for (final st in [SessionStatus.done, SessionStatus.stopped, SessionStatus.error]) {
        expect(sessionLine(s(status: st), now), 'encerrada há 19 min');
        expect(sessionLine(s(status: st, createdAt: ''), now), 'encerrada');
      }
    });

    test('otherwise the age, empty when unreadable', () {
      expect(sessionLine(s(), now), 'há 19 min');
      expect(sessionLine(s(createdAt: 'x'), now), '');
    });
  });

  group('feedBlocks', () {
    String at(int min) => '2026-03-10T10:${min.toString().padLeft(2, '0')}:00Z';
    ToolCall tool(int m, {String name = 'Bash', bool error = false}) =>
        ToolCall(at(m), id: 't$m', name: name, summary: 'x', result: '', isError: error);
    AssistantText text(int m) => AssistantText(at(m), 'a$m');
    Thinking think(int m) => Thinking(at(m), 'h');
    UserText user(int m) => UserText(at(m), 'u');

    List<(bool, int)> shape(List<FeedBlock> b) => [for (final x in b) (x.work, x.steps)];

    test('text, tools and thinking, user, one tool', () {
      final b = feedBlocks([text(0), tool(1), tool(2), think(3), tool(4), user(5), tool(6)]);
      expect(shape(b), [(false, 0), (true, 3), (false, 0), (true, 1)]);
      expect(b[1].events.length, 4);
    });

    test('intermediate text stays inside the block, final text outside', () {
      final b = feedBlocks([
        text(0),
        tool(1),
        text(2),
        tool(3),
        tool(4),
        text(5),
        SessionResult(at(6), isError: false, cost: 0, seconds: 1, turns: 1),
      ]);
      expect(shape(b), [(false, 0), (true, 3), (false, 0), (false, 0)]);
      expect(b[1].events[1], isA<AssistantText>());
      expect(b[3].events.single, isA<SessionResult>());
    });

    test('a permission request splits two work blocks', () {
      final req = PermissionRequest(
        at(2),
        requestId: 'r',
        seq: 1,
        toolName: 'Bash',
        target: 'x',
        diff: const [],
        command: 'x',
      );
      final b = feedBlocks([tool(1), req, tool(3)]);
      expect(shape(b), [(true, 1), (false, 0), (true, 1)]);
    });

    test('seconds run to the first event after the block', () {
      expect(feedBlocks([tool(0), text(20)]).first.seconds, 1200);
    });

    test('seconds stop at the last block event when a user turn follows', () {
      final b = feedBlocks([
        const UserText('2026-03-10T10:00:00Z', 'u'),
        tool(1),
        tool(2),
        const UserText('2026-03-10T20:00:00Z', 'u'),
      ]);
      expect(b.firstWhere((x) => x.work).seconds, 60);
    });

    test('seconds stop at the last block event when an imported note follows', () {
      final b = feedBlocks([tool(1), tool(3), SessionNote(at(50), SessionNoteKind.imported)]);
      expect(b.first.seconds, 120);
    });

    test('seconds without an event after use the last event of the block', () {
      expect(feedBlocks([tool(0), tool(2)]).single.seconds, 120);
    });

    test('unreadable at gives 0 seconds', () {
      final b = feedBlocks([const ToolCall('', id: 'a', name: 'Bash', summary: 'x'), text(5)]);
      expect(b.first.seconds, 0);
    });

    test('AskUserQuestion with a QuestionRequest is in no block and does not count', () {
      final card = QuestionRequest(at(3), requestId: 'q', seq: 1, questions: const []);
      final b = feedBlocks([tool(1), tool(2, name: 'AskUserQuestion'), card, tool(4)]);
      expect(shape(b), [(true, 1), (false, 0), (true, 1)]);
      expect(b.expand((x) => x.events).whereType<ToolCall>().any((c) => c.name == 'AskUserQuestion'), isFalse);
    });

    test('a QuestionRequest hides the call with its toolUseId, not the neighbours', () {
      QuestionRequest card(int m, String id) =>
          QuestionRequest(at(m), requestId: 'q$m', seq: m, questions: const [], toolUseId: id);
      final b = feedBlocks([tool(1, name: 'AskUserQuestion'), tool(2, name: 'AskUserQuestion'), card(3, 't2')]);
      final calls = b.expand((x) => x.events).whereType<ToolCall>().toList();
      expect(calls.map((c) => c.id), ['t1']);
    });

    test('a QuestionRequest hides the call with its toolUseId whatever the call name', () {
      final card = QuestionRequest(at(2), requestId: 'q', seq: 1, questions: const [], toolUseId: 't1');
      final b = feedBlocks([tool(1), card, tool(3)]);
      expect(b.expand((x) => x.events).whereType<ToolCall>().map((c) => c.id), ['t3']);
    });

    test('two questions in one message hide both calls once both requests are in', () {
      QuestionRequest card(int m, String id) =>
          QuestionRequest(at(m), requestId: 'q$m', seq: m, questions: const [], toolUseId: id);
      final b = feedBlocks([
        tool(1, name: 'AskUserQuestion'),
        tool(2, name: 'AskUserQuestion'),
        card(3, 't1'),
        card(4, 't2'),
      ]);
      expect(b.expand((x) => x.events).whereType<ToolCall>(), isEmpty);
      expect(b.length, 2);
    });

    test('a call whose request has not arrived stays visible while another request has', () {
      final card = QuestionRequest(at(3), requestId: 'q', seq: 1, questions: const [], toolUseId: 't1');
      final b = feedBlocks([tool(1, name: 'AskUserQuestion'), tool(2, name: 'AskUserQuestion'), card]);
      expect(b.expand((x) => x.events).whereType<ToolCall>().map((c) => c.id), ['t2']);
    });

    test('AskUserQuestion without a QuestionRequest stays as a step', () {
      final b = feedBlocks([tool(1), tool(2, name: 'AskUserQuestion'), tool(3)]);
      expect(shape(b), [(true, 3)]);
      expect(b.single.events.whereType<ToolCall>().any((c) => c.name == 'AskUserQuestion'), isTrue);
    });

    test('errors are counted', () {
      expect(feedBlocks([tool(1, error: true), tool(2), tool(3, error: true)]).single.errors, 2);
    });

    test('feedBlocks keeps work-block positions across every prefix', () {
      final all = <SessionEvent>[
        user(0),
        text(1),
        tool(2),
        text(3),
        tool(4),
        think(5),
        text(6),
        user(7),
        tool(8),
        tool(9),
        text(10),
        SessionResult(at(11), isError: false, cost: 0, seconds: 1, turns: 1),
        text(12),
        tool(13),
      ];
      List<int> workPositions(List<FeedBlock> b) => [
        for (var i = 0; i < b.length; i++)
          if (b[i].work) i,
      ];
      for (var n = 1; n <= all.length; n++) {
        final prefix = workPositions(feedBlocks(all.sublist(0, n)));
        final next = workPositions(feedBlocks(all.sublist(0, n + 1 > all.length ? n : n + 1)));
        expect(next.take(prefix.length).toList(), prefix, reason: 'prefix $n');
      }
    });

    test('feedBlocks keeps work positions across prefixes with AskUserQuestion', () {
      QuestionRequest card(int m, {String? id}) =>
          QuestionRequest(at(m), requestId: 'q$m', seq: m, questions: const [], toolUseId: id);
      bool onlyAsk(FeedBlock b) => b.events.every((e) => e is ToolCall && e.name == 'AskUserQuestion');

      final scenarios = <String, List<SessionEvent>>{
        'without a request': [user(0), tool(1), tool(2, name: 'AskUserQuestion'), tool(3), text(4)],
        'with a request by toolUseId': [user(0), tool(1), tool(2, name: 'AskUserQuestion'), card(3, id: 't2'), tool(4)],
        'with a request without toolUseId': [user(0), tool(1), tool(2, name: 'AskUserQuestion'), card(3), tool(4)],
        'alone in its block': [user(0), text(1), tool(2, name: 'AskUserQuestion'), card(3, id: 't2'), tool(4)],
        'two questions in one message': [
          user(0),
          tool(1, name: 'AskUserQuestion'),
          tool(2, name: 'AskUserQuestion'),
          card(3, id: 't1'),
          card(4, id: 't2'),
          tool(5),
        ],
      };

      scenarios.forEach((name, all) {
        for (var n = 1; n < all.length; n++) {
          final prefix = feedBlocks(all.sublist(0, n));
          final next = feedBlocks(all.sublist(0, n + 1));
          for (var i = 0; i < prefix.length; i++) {
            if (!prefix[i].work) continue;
            final reason = '$name, prefix $n, block $i';
            if (i < next.length && next[i].work) continue;
            expect(onlyAsk(prefix[i]), isTrue, reason: reason);
            expect(prefix.skip(i + 1).any((b) => b.work), isFalse, reason: reason);
          }
        }
      });
    });

    test('a block made only of an AskUserQuestion call vanishes when its card arrives', () {
      final before = feedBlocks([user(0), tool(1, name: 'AskUserQuestion')]);
      final after = feedBlocks([
        user(0),
        tool(1, name: 'AskUserQuestion'),
        QuestionRequest(at(2), requestId: 'q', seq: 1, questions: const [], toolUseId: 't1'),
      ]);
      expect(shape(before), [(false, 0), (true, 1)]);
      expect(shape(after), [(false, 0), (false, 0)]);
    });
  });

  group('workOpenByDefault', () {
    FeedBlock work() => (events: <SessionEvent>[], work: true, steps: 1, errors: 0, seconds: 0);
    FeedBlock single(SessionEvent e) => (events: [e], work: false, steps: 0, errors: 0, seconds: 0);

    test('open only when text follows and the session is live', () {
      final blocks = [work(), single(const AssistantText('', 'a'))];
      expect(workOpenByDefault(blocks, 0, SessionStatus.running), isTrue);
      expect(workOpenByDefault(blocks, 0, SessionStatus.starting), isTrue);
      expect(workOpenByDefault(blocks, 0, SessionStatus.waitingPermission), isTrue);
      expect(workOpenByDefault(blocks, 0, SessionStatus.idle), isFalse);
      expect(workOpenByDefault(blocks, 0, SessionStatus.done), isFalse);
    });

    test('closed when a user message or another work block follows', () {
      expect(workOpenByDefault([work(), single(const UserText('', 'u'))], 0, SessionStatus.running), isFalse);
      expect(workOpenByDefault([work(), work()], 0, SessionStatus.running), isFalse);
      expect(workOpenByDefault([work(), work()], 1, SessionStatus.running), isTrue);
    });
  });

  test('workLine', () {
    expect(workLine(1, 0), 'Trabalhou em 1 passo');
    expect(workLine(3, 0), 'Trabalhou em 3 passos');
    expect(workLine(3, 59), 'Trabalhou em 3 passos');
    expect(workLine(3, 125), 'Trabalhou em 3 passos · 2min');
    expect(workLine(3, 3700), 'Trabalhou em 3 passos · 1h 01min');
    expect(workLine(0, 125), 'Pensou');
    expect(workLine(3, 0, errors: 1), 'Trabalhou em 3 passos · 1 com erro');
    expect(workLine(3, 125, errors: 2), 'Trabalhou em 3 passos · 2min · 2 com erro');
  });

  test('optionView', () {
    expect(optionView('Aprovar (Recomendado)'), (label: 'Aprovar', recommended: true));
    expect(optionView('Aprovar (Recommended)'), (label: 'Aprovar', recommended: true));
    expect(optionView('Aprovar'), (label: 'Aprovar', recommended: false));
  });

  test('answerDisplay tira o sufixo de cada parte', () {
    expect(answerDisplay('A (Recomendado), B'), 'A, B');
    expect(answerDisplay('A (Recomendado)'), 'A');
    expect(answerDisplay('Sim, claro'), 'Sim, claro');
  });

  test('shortModel', () {
    expect(shortModel('claude-opus-5-5'), 'opus');
    expect(shortModel('claude-sonnet-5-5'), 'sonnet');
    expect(shortModel('claude-haiku-4-5'), 'haiku');
    expect(shortModel('fable-1'), 'fable');
    expect(shortModel('gemini-3'), 'gemini-3');
    expect(shortModel(null), isNull);
  });
}
