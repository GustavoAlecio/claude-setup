import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:claude_flow/data/http_sessions_repository.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/session_reducer.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _timeout = Duration(seconds: 5);

typedef _Req = ({String method, String path, Map<String, String> query, Object? body});

Map<String, Object?> _summary(String id, {String status = 'running', int pending = 0, String project = 'demo'}) => {
  'id': id,
  'project': project,
  'cwd': '/tmp',
  'command': '/fix',
  'title': '/fix',
  'status': status,
  'createdAt': '2026-03-10T14:41:00Z',
  'cost': 0,
  'model': null,
  'events': 0,
  'pendingPermissions': pending,
  'resumable': true,
};

Map<String, Object?> _ev(int seq, Map<String, Object?> e) => {'seq': seq, 'at': '2026-03-10T14:41:00Z', ...e};

/// Loopback stand-in for the engine: records requests and lets each test script the SSE streams.
class _FakeEngine {
  _FakeEngine._(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeEngine> start() async => _FakeEngine._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <_Req>[];
  final _open = <HttpResponse>[];

  List<Map<String, Object?>> snapshot = [];
  final known = <String, Map<String, Object?>>{};

  /// Response of `POST /api/sessions`; `null` answers with the engine's missing-cwd 400.
  Map<String, Object?>? created;

  /// Error reply of `POST /api/sessions/:id/permission-mode` as `(status, body)`; `null` answers with the summary
  /// carrying the new mode. A [String] body is sent as is, like the HTML 404 of an engine without the route.
  (int, Object)? permissionModeError;

  /// Called per `/api/sessions/:id/stream` connection; returning leaves the response open.
  Future<void> Function(HttpResponse res, _Req req, int connection) sessionStream = (_, _, _) async {};
  int _connections = 0;

  final _globalClients = <HttpResponse>[];

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  int streamConnections(String id) => requests.where((r) => r.path == '/api/sessions/$id/stream').length;

  List<_Req> posts(String path) => requests.where((r) => r.method == 'POST' && r.path == path).toList();

  Future<void> close() async {
    for (final r in _open) {
      await r.close().catchError((_) {});
    }
    await _server.close(force: true);
  }

  Future<void> pushGlobal(String event, Object data) async {
    for (final r in _globalClients) {
      await send(r, event, data);
    }
  }

  static Future<void> send(HttpResponse res, String event, Object data) async {
    res.write('event: $event\ndata: ${jsonEncode(data)}\n\n');
    await res.flush();
  }

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    final req = (
      method: request.method,
      path: request.uri.path,
      query: request.uri.queryParameters,
      body: raw.isEmpty ? null : jsonDecode(raw),
    );
    requests.add(req);
    final res = request.response;
    final segments = request.uri.pathSegments;

    if (request.method == 'GET' && req.path == '/api/agy/models') {
      return _json(res, 200, {
        'models': [
          {
            'id': 'gemini-x',
            'label': 'Gemini X',
            'quota': {'remaining': 0, 'resetsAt': '2026-10-13T12:03:43.000Z'},
          },
          {'label': 'sem id'},
        ],
      });
    }
    if (request.method == 'GET' && req.path == '/api/terminal-sessions') {
      return _json(res, 200, [
        {
          'sdkSessionId': 'aaa',
          'title': 'Greet com idioma',
          'firstPrompt': 'como funciona o greet?',
          'updatedAt': '2026-10-16T10:00:00.000Z',
          'live': 'busy',
          'cwd': request.uri.queryParameters['cwd'],
        },
        {'sdkSessionId': 'bbb', 'cwd': '/dev/sand box/pkg', 'updatedAt': '2026-10-15T10:00:00.000Z', 'firstPrompt': 'antiga'},
        {'sdkSessionId': 'ccc', 'updatedAt': '2026-10-15T10:00:00.000Z', 'firstPrompt': 'sem cwd'},
        {'title': 'sem id', 'updatedAt': '2026-10-15T10:00:00.000Z'},
      ]);
    }
    if (request.method == 'POST' && segments.length == 4 && segments[3] == 'aside') {
      return _json(res, 200, {
        'id': 'aside-1',
        'project': 'demo',
        'command': (req.body as Map)['text'],
        'title': (req.body as Map)['text'],
        'status': 'running',
        'createdAt': '2026-10-16T10:00:00.000Z',
        'permissionMode': 'plan',
        'asideOf': segments[2],
      });
    }
    if (request.method == 'POST' && req.path == '/api/sessions/import') {
      final body = req.body as Map;
      return _json(res, 200, {
        'id': 'imp-1',
        'project': body['project'],
        'command': 'como funciona o greet?',
        'title': 'como funciona o greet?',
        'status': 'detached',
        'createdAt': '2026-10-16T10:00:00.000Z',
        'resumable': true,
        'skill': '/kickoff',
      });
    }
    if (request.method == 'POST' && req.path == '/api/agy/accounts/likin.do/login') {
      return _json(res, 200, {'opened': true});
    }

    if (req.path == '/api/sessions/stream') {
      _openSse(res);
      _globalClients.add(res);
      await send(res, 'snapshot', snapshot);
      return;
    }
    if (segments.length == 4 && segments[3] == 'stream') {
      final id = segments[2];
      if (!known.containsKey(id)) return _json(res, 404, {'error': 'sessao nao encontrada'});
      _openSse(res);
      await sessionStream(res, req, ++_connections);
      return;
    }
    if (request.method == 'GET' && segments.length == 3) {
      final summary = known[segments[2]];
      return summary == null ? _json(res, 404, {'error': 'sessao nao encontrada'}) : _json(res, 200, summary);
    }
    if (request.method == 'POST' && segments.length == 4 && segments[3] == 'permission-mode') {
      if (permissionModeError case (final status, final String body)) {
        res.statusCode = status;
        res.headers.contentType = ContentType.html;
        res.write(body);
        return res.close();
      }
      if (permissionModeError case (final status, final body)) return _json(res, status, body);
      final summary = known[segments[2]];
      if (summary == null) return _json(res, 404, {'error': 'sessao nao encontrada'});
      return _json(res, 200, {...summary, 'permissionMode': (req.body as Map)['mode']});
    }
    if (request.method == 'POST' && segments.length == 4) {
      final summary = known[segments[2]];
      return summary == null ? _json(res, 404, {'error': 'sessao nao encontrada'}) : _json(res, 200, summary);
    }
    if (request.method == 'POST' && req.path == '/api/sessions') {
      if (created case final summary?) return _json(res, 200, summary);
      return _json(res, 400, {
        'error': 'sem diretório para demo: defina cwds.demo em ~/.claude/workflow/.dashboard.json',
      });
    }
    _json(res, 404, {'error': 'rota'});
  }

  void _openSse(HttpResponse res) {
    res.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    res.bufferOutput = false;
    _open.add(res);
  }

  Future<void> _json(HttpResponse res, int status, Object body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}

void main() {
  late _FakeEngine engine;
  late StreamController<Uri?> endpoint;
  late HttpSessionsRepository repo;

  setUp(() async {
    engine = await _FakeEngine.start();
    endpoint = StreamController<Uri?>();
    repo = HttpSessionsRepository(endpoint.stream, backoff: (_) => Duration.zero);
    endpoint.add(engine.uri);
  });

  tearDown(() async {
    await repo.dispose();
    await endpoint.close();
    await engine.close();
  });

  Future<SessionDetail> detailWhere(String id, bool Function(SessionDetail) test) =>
      repo.watchSession(id).firstWhere(test).timeout(_timeout);

  group('HttpSessionsRepository', () {
    test('fuses tool_use and tool_result into one ToolCall', () async {
      engine.known['s1'] = _summary('s1');
      engine.sessionStream = (res, _, _) async {
        await _FakeEngine.send(
          res,
          'event',
          _ev(1, {
            'kind': 'tool_use',
            'id': 't1',
            'name': 'Read',
            'input': {'file_path': 'lib/a.dart'},
          }),
        );
        await _FakeEngine.send(res, 'event', _ev(2, {'kind': 'tool_result', 'id': 't1', 'text': '3 linhas'}));
      };

      final d = await detailWhere('s1', (d) => d.lastSeq == 2);
      final call = d.events.single as ToolCall;
      expect(call.summary, 'lib/a.dart');
      expect(call.result, '3 linhas');
    });

    test('AskUserQuestion with 2 questions becomes one QuestionRequest and the answer posts answers', () async {
      engine.known['s1'] = _summary('s1', status: 'waiting_permission', pending: 1);
      engine.sessionStream = (res, _, _) async {
        await _FakeEngine.send(
          res,
          'event',
          _ev(1, {
            'kind': 'permission',
            'requestId': 'rq-9',
            'toolName': 'AskUserQuestion',
            'input': {
              'questions': [
                {
                  'question': 'Qual banco?',
                  'header': 'Banco',
                  'multiSelect': false,
                  'options': [
                    {'label': 'Postgres', 'description': ''},
                    {'label': 'SQLite', 'description': ''},
                  ],
                },
                {
                  'question': 'Quais extras?',
                  'header': 'Extras',
                  'multiSelect': true,
                  'options': [
                    {'label': 'Cache', 'description': ''},
                    {'label': 'Fila', 'description': ''},
                    {'label': 'Busca', 'description': ''},
                  ],
                },
              ],
            },
          }),
        );
      };

      final d = await detailWhere('s1', (d) => d.events.isNotEmpty);
      final q = d.events.single as QuestionRequest;
      expect(q.questions.length, 2);

      final answers = answersFor(q.questions, {
        'Qual banco?': {'SQLite'},
        'Quais extras?': {'Busca', 'Cache'},
      });
      await repo.answer('s1', q.requestId, PermissionDecision.answer, answers: answers);

      expect(engine.posts('/api/sessions/s1/permission').single.body, {
        'requestId': 'rq-9',
        'decision': 'answer',
        'answers': {'Qual banco?': 'SQLite', 'Quais extras?': 'Cache, Busca'},
      });
    });

    test('Edit permission shows the diff and Permitir posts {requestId, decision: allow}', () async {
      engine.known['s1'] = _summary('s1', status: 'waiting_permission', pending: 1);
      engine.sessionStream = (res, _, _) async {
        await _FakeEngine.send(
          res,
          'event',
          _ev(1, {
            'kind': 'permission',
            'requestId': 'rq-1',
            'toolName': 'Edit',
            'input': {'file_path': 'a.txt', 'old_string': 'a\nb', 'new_string': 'a\nc'},
          }),
        );
      };

      final d = await detailWhere('s1', (d) => d.events.isNotEmpty);
      final p = d.events.single as PermissionRequest;
      expect([for (final l in p.diff) '${l.kind}${l.text}'], [' a', '-b', '+c']);

      await repo.answer('s1', p.requestId, PermissionDecision.allow);
      expect(engine.posts('/api/sessions/s1/permission').single.body, {'requestId': 'rq-1', 'decision': 'allow'});
    });

    test('3 deltas grow the partial and the final assistant_text replaces it without duplicating', () async {
      engine.known['s1'] = _summary('s1');
      engine.sessionStream = (res, _, _) async {
        for (final t in ['Ol', 'á ', 'mundo']) {
          await _FakeEngine.send(res, 'delta', {'kind': 'text', 'text': t});
        }
        await _FakeEngine.send(res, 'event', _ev(1, {'kind': 'assistant_text', 'text': 'Olá mundo'}));
      };

      final partials = <String>[];
      final d = await repo
          .watchSession('s1')
          .map((d) {
            partials.add(d.partialText);
            return d;
          })
          .firstWhere((d) => d.lastSeq == 1)
          .timeout(_timeout);

      expect(partials.where((p) => p.isNotEmpty), ['Ol', 'Olá ', 'Olá mundo']);
      expect(d.partialText, '');
      expect(d.events.whereType<AssistantText>().map((e) => e.text), ['Olá mundo']);
    });

    test('drop after seq 5 reconnects with ?from=5 and ends with seq 1..N without repeats', () async {
      engine.known['s1'] = _summary('s1');
      engine.sessionStream = (res, req, connection) async {
        if (connection == 1) {
          for (var i = 1; i <= 5; i++) {
            await _FakeEngine.send(res, 'event', _ev(i, {'kind': 'user_text', 'text': '$i'}));
          }
          await _FakeEngine.send(res, 'delta', {'kind': 'text', 'text': 'meio'});
          await res.close();
          return;
        }
        // Overlap on purpose: the client must drop what it already has.
        for (var i = 4; i <= 8; i++) {
          await _FakeEngine.send(res, 'event', _ev(i, {'kind': 'user_text', 'text': '$i'}));
        }
      };

      final d = await detailWhere('s1', (d) => d.lastSeq == 8);
      final streams = engine.requests.where((r) => r.path == '/api/sessions/s1/stream').toList();
      expect(streams.map((r) => r.query['from']), ['0', '5']);
      expect(d.events.cast<UserText>().map((e) => e.text), [for (var i = 1; i <= 8; i++) '$i']);
      expect(d.partialText, '');
    });

    test('orphan permission in a detached session is expired and does not count', () async {
      engine.snapshot = [_summary('s1', status: 'detached', pending: 1)];
      engine.known['s1'] = _summary('s1', status: 'detached');
      engine.sessionStream = (res, _, _) async {
        await _FakeEngine.send(
          res,
          'event',
          _ev(1, {
            'kind': 'permission',
            'requestId': 'rq-1',
            'toolName': 'Bash',
            'input': {'command': 'ls'},
          }),
        );
        await _FakeEngine.send(res, 'status', {'status': 'detached'});
      };

      final list = await repo.watchSessions().first.timeout(_timeout);
      expect(pendingByProject(list), isEmpty);

      final d = await detailWhere('s1', (d) => d.events.isNotEmpty && d.summary.status == SessionStatus.detached);
      expect((d.events.single as PermissionRequest).expired, isTrue);
      expect(d.summary.pendingPermissions, 0);
    });

    test('maps every engine status from the global stream', () async {
      const statuses = {
        'starting': SessionStatus.starting,
        'running': SessionStatus.running,
        'idle': SessionStatus.idle,
        'waiting_permission': SessionStatus.waitingPermission,
        'done': SessionStatus.done,
        'stopped': SessionStatus.stopped,
        'error': SessionStatus.error,
        'detached': SessionStatus.detached,
      };
      engine.snapshot = [for (final s in statuses.keys) _summary(s, status: s)];

      final list = await repo.watchSessions().first.timeout(_timeout);
      expect({for (final s in list) s.id: s.status}, statuses);
    });

    test('summary and removed frames update the list', () async {
      engine.snapshot = [_summary('a', status: 'idle')];
      final updates = repo.watchSessions();
      final done = updates.firstWhere((l) => l.length == 1 && l.single.id == 'b').timeout(_timeout);
      await repo.watchSessions().first.timeout(_timeout);
      await engine.pushGlobal('summary', _summary('b', status: 'running', pending: 2));
      await engine.pushGlobal('removed', {'id': 'a'});
      final list = await done;
      expect(list.single.pendingPermissions, 2);
    });

    test('closed ends the stream without reconnecting; resume listens again', () async {
      engine.known['s1'] = _summary('s1');
      engine.sessionStream = (res, req, connection) async {
        if (connection == 1) {
          await _FakeEngine.send(res, 'event', _ev(1, {'kind': 'user_text', 'text': 'oi'}));
          await _FakeEngine.send(res, 'closed', <String, Object?>{});
        } else {
          await _FakeEngine.send(res, 'event', _ev(2, {'kind': 'reattached'}));
        }
      };

      final sub = repo.watchSession('s1').listen((_) {});
      await detailWhere('s1', (d) => d.closed);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(engine.streamConnections('s1'), 1);

      await repo.resume('s1');
      final d = await detailWhere('s1', (d) => d.lastSeq == 2);
      expect(d.closed, isFalse);
      expect(engine.streamConnections('s1'), 2);
      expect(engine.requests.where((r) => r.path == '/api/sessions/s1/stream').last.query['from'], '1');
      await sub.cancel();
    });

    test('engine stopped (null endpoint) does not reconnect', () async {
      engine.known['s1'] = _summary('s1');
      final drop = Completer<HttpResponse>();
      engine.sessionStream = (res, _, connection) async {
        await _FakeEngine.send(res, 'event', _ev(connection, {'kind': 'user_text', 'text': '$connection'}));
        if (!drop.isCompleted) drop.complete(res);
      };

      final sub = repo.watchSession('s1').listen((_) {});
      final res = await drop.future.timeout(_timeout);
      endpoint.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await res.close().catchError((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(engine.streamConnections('s1'), 1);
      await sub.cancel();
    });

    test('404 on the session stream removes it from the list', () async {
      engine.snapshot = [_summary('gone', status: 'idle'), _summary('kept', status: 'idle')];
      engine.known['gone'] = _summary('gone', status: 'idle');
      final listed = await repo.watchSessions().first.timeout(_timeout);
      expect(listed.map((s) => s.id), ['gone', 'kept']);

      final removed = repo.watchSessions().firstWhere((l) => l.length == 1).timeout(_timeout);
      engine.known.remove('gone');
      final sub = repo.watchSession('gone').listen((_) {});
      expect((await removed).single.id, 'kept');
      await sub.cancel();
    });

    test('create surfaces the engine error text', () async {
      await repo.watchSessions().first.timeout(_timeout);
      await expectLater(
        repo.create('demo', 'responda ok', permissionMode: PermissionMode.bypassPermissions),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            'sem diretório para demo: defina cwds.demo em ~/.claude/workflow/.dashboard.json',
          ),
        ),
      );
    });
  });

  test('terminalSessions sends the cwd and drops entries without an id; import posts and lists the session', () async {
    await repo.watchSessions().first.timeout(_timeout);
    final list = await repo.terminalSessions('/dev/sand box');
    expect(engine.requests.where((r) => r.path == '/api/terminal-sessions').single.query['cwd'], '/dev/sand box');
    expect([for (final t in list) (t.sdkSessionId, t.title, t.live)], [
      ('aaa', 'Greet com idioma', 'busy'),
      ('bbb', 'antiga', null),
    ]);

    final imported = await repo.importTerminalSession(
      sdkSessionId: 'aaa',
      cwd: '/dev/sandbox',
      project: 'sandbox',
      permissionMode: PermissionMode.acceptEdits,
    );
    expect(imported.status, SessionStatus.detached);
    expect(imported.skill, '/kickoff');
    expect(engine.posts('/api/sessions/import').single.body, {
      'sdkSessionId': 'aaa',
      'cwd': '/dev/sandbox',
      'project': 'sandbox',
      'permissionMode': 'acceptEdits',
    });
    expect((await repo.watchSessions().first.timeout(_timeout)).map((s) => s.id), contains('imp-1'));
  });

  test('an open-terminal frame on the global stream becomes a handoff and leaves the list alone', () async {
    // Like the SessionsCubit: the global stream is only open while someone watches the list.
    final lists = <List<SessionSummary>>[];
    final sub = repo.watchSessions().listen(lists.add);
    addTearDown(sub.cancel);
    while (lists.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final handoff = repo.terminalHandoffs().first.timeout(_timeout);
    await engine.pushGlobal('open-terminal', {'sdkSessionId': 'aaa', 'cwd': '/dev/sandbox/pkg'});
    expect(await handoff, (sdkSessionId: 'aaa', cwd: '/dev/sandbox/pkg'));
    expect(lists, hasLength(1), reason: 'the frame is not a list update');
  });

  test('askAside posts the question and lists the new session', () async {
    final lists = <List<SessionSummary>>[];
    final sub = repo.watchSessions().listen(lists.add);
    addTearDown(sub.cancel);
    while (lists.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final aside = await repo.askAside('s 1', 'por quê?');
    expect(engine.posts('/api/sessions/s%201/aside').single.body, {'text': 'por quê?'});
    expect((aside.asideOf, aside.permissionMode), ('s 1', PermissionMode.plan));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(lists.last.map((s) => s.id), contains('aside-1'));
  });

  test('create sends cwd only when given', () async {
    await repo.watchSessions().first.timeout(_timeout);
    await expectLater(
      repo.create('demo', 'a', cwd: '/repos/demo', permissionMode: PermissionMode.bypassPermissions),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      repo.create('demo', 'b', permissionMode: PermissionMode.bypassPermissions),
      throwsA(isA<Exception>()),
    );
    expect(engine.posts('/api/sessions').map((r) => r.body), [
      {'project': 'demo', 'command': 'a', 'cwd': '/repos/demo', 'permissionMode': 'bypassPermissions'},
      {'project': 'demo', 'command': 'b', 'permissionMode': 'bypassPermissions'},
    ]);
  });

  test('create and createInOrg send githubAccount only when given', () async {
    await repo.watchSessions().first.timeout(_timeout);
    await expectLater(
      repo.create('demo', 'a', githubAccount: 'acct-a', permissionMode: PermissionMode.bypassPermissions),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      repo.createInOrg(
        'org-x',
        'b',
        cwd: '/dev/x',
        githubAccount: 'acct-b',
        permissionMode: PermissionMode.bypassPermissions,
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      repo.createInOrg('org-x', 'c', cwd: '/dev/x', permissionMode: PermissionMode.bypassPermissions),
      throwsA(isA<Exception>()),
    );
    expect(engine.posts('/api/sessions').map((r) => r.body), [
      {'project': 'demo', 'command': 'a', 'githubAccount': 'acct-a', 'permissionMode': 'bypassPermissions'},
      {
        'org': 'org-x',
        'command': 'b',
        'cwd': '/dev/x',
        'additionalDirectories': <String>[],
        'githubAccount': 'acct-b',
        'permissionMode': 'bypassPermissions',
      },
      {
        'org': 'org-x',
        'command': 'c',
        'cwd': '/dev/x',
        'additionalDirectories': <String>[],
        'permissionMode': 'bypassPermissions',
      },
    ]);
  });

  test('send carries images as base64 with their media type', () async {
    await repo.watchSessions().first.timeout(_timeout);
    engine.known['s1'] = _summary('s1');
    await repo.send(
      's1',
      'veja',
      images: [
        ImageAttachment('image/png', Uint8List.fromList([1, 2, 3])),
      ],
    );
    expect(engine.posts('/api/sessions/s1/input').single.body, {
      'text': 'veja',
      'images': [
        {'mediaType': 'image/png', 'data': 'AQID'},
      ],
    });
  });

  test('create carries the first message images; without them the body has no images key', () async {
    await repo.watchSessions().first.timeout(_timeout);
    final png = ImageAttachment('image/png', Uint8List.fromList([1, 2, 3]));
    await expectLater(
      repo.create('demo', 'veja', permissionMode: PermissionMode.acceptEdits, images: [png]),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      repo.createInOrg('o', 'veja', cwd: '/r', permissionMode: PermissionMode.acceptEdits, images: [png]),
      throwsA(isA<Exception>()),
    );
    final bodies = engine.posts('/api/sessions').map((r) => r.body as Map).toList();
    for (final body in bodies) {
      expect(body['images'], [
        {'mediaType': 'image/png', 'data': 'AQID'},
      ]);
    }
    expect(bodies, hasLength(2));
  });

  test('cycleAction posts the action to the project cycle route', () async {
    await repo.watchSessions().first.timeout(_timeout);
    await expectLater(repo.cycleAction('demo app', CycleAction.archive), throwsA(isA<Exception>()));
    expect(engine.posts('/api/projects/demo%20app/cycle').single.body, {'action': 'archive'});
  });

  test('agentModels sends the account as a query parameter; agentLogin posts to the account route', () async {
    await repo.watchSessions().first.timeout(_timeout);
    final models = await repo.agentModels('likin.do');
    expect(models.map((m) => (m.id, m.label)), [('gemini-x', 'Gemini X')]);
    expect(
      (models.single.quota!.exhausted, models.single.quota!.resetsAt),
      (true, DateTime.utc(2026, 10, 13, 12, 3, 43)),
    );
    expect(engine.requests.last.query, {'account': 'likin.do'});

    await repo.agentLogin('likin.do');
    expect(engine.posts('/api/agy/accounts/likin.do/login'), hasLength(1));
  });

  test(
    'an Antigravity agent sends provider, account (default when unset) and model; Anthropic sends only a model',
    () async {
      await repo.watchSessions().first.timeout(_timeout);
      for (final agent in const [
        OrgAgent(provider: AgentProvider.antigravity, account: 'likin.do', model: 'gemini-x'),
        OrgAgent(provider: AgentProvider.antigravity),
        OrgAgent(model: 'opus'),
      ]) {
        await expectLater(
          repo.create('demo', 'a', permissionMode: PermissionMode.bypassPermissions, agent: agent),
          throwsA(isA<Exception>()),
        );
      }
      expect(engine.posts('/api/sessions').map((r) => r.body), [
        {
          'project': 'demo',
          'command': 'a',
          'permissionMode': 'bypassPermissions',
          'provider': 'antigravity',
          'account': 'likin.do',
          'model': 'gemini-x',
        },
        {
          'project': 'demo',
          'command': 'a',
          'permissionMode': 'bypassPermissions',
          'provider': 'antigravity',
          'account': 'default',
        },
        {'project': 'demo', 'command': 'a', 'permissionMode': 'bypassPermissions', 'model': 'opus'},
      ]);
    },
  );

  group('permission mode', () {
    test('create and createInOrg send permissionMode always', () async {
      await repo.watchSessions().first.timeout(_timeout);
      await expectLater(
        repo.create('demo', 'a', permissionMode: PermissionMode.bypassPermissions),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        repo.create('demo', 'b', permissionMode: PermissionMode.defaultMode),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        repo.createInOrg('org-x', 'c', cwd: '/dev/x', permissionMode: PermissionMode.defaultMode),
        throwsA(isA<Exception>()),
      );
      expect(engine.posts('/api/sessions').map((r) => r.body), [
        {'project': 'demo', 'command': 'a', 'permissionMode': 'bypassPermissions'},
        {'project': 'demo', 'command': 'b', 'permissionMode': 'default'},
        {
          'org': 'org-x',
          'command': 'c',
          'cwd': '/dev/x',
          'additionalDirectories': <String>[],
          'permissionMode': 'default',
        },
      ]);
    });

    test('setPermissionMode posts {mode} to the session route and lists the returned summary', () async {
      engine.snapshot = [_summary('s1', status: 'idle')];
      engine.known['s1'] = _summary('s1', status: 'idle');
      final listed = await repo.watchSessions().first.timeout(_timeout);
      expect(listed.single.permissionMode, PermissionMode.defaultMode);

      final updated = repo
          .watchSessions()
          .firstWhere((l) => l.single.permissionMode == PermissionMode.acceptEdits)
          .timeout(_timeout);
      await repo.setPermissionMode('s1', PermissionMode.acceptEdits);

      expect(engine.posts('/api/sessions/s1/permission-mode').map((r) => r.body), [
        {'mode': 'acceptEdits'},
      ]);
      expect((await updated).single.id, 's1');
    });

    test('a refusal (409) is a SessionsException with the engine text and keeps the session', () async {
      engine.snapshot = [_summary('s1', status: 'idle')];
      engine.known['s1'] = _summary('s1', status: 'idle');
      await repo.watchSessions().first.timeout(_timeout);
      engine.permissionModeError = (409, {'error': 'bypass_disabled'});

      await expectLater(
        repo.setPermissionMode('s1', PermissionMode.bypassPermissions),
        throwsA(
          isA<SessionsException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.message, 'message', 'bypass_disabled'),
        ),
      );
      expect((await repo.watchSessions().first.timeout(_timeout)).single.permissionMode, PermissionMode.defaultMode);
    });

    test('404 is a SessionsException with the engine text and does not drop the session', () async {
      engine.snapshot = [_summary('s1', status: 'idle')];
      await repo.watchSessions().first.timeout(_timeout);

      await expectLater(
        repo.setPermissionMode('s1', PermissionMode.auto),
        throwsA(
          isA<SessionsException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', 'sessao nao encontrada'),
        ),
      );

      engine.permissionModeError = (404, '<!DOCTYPE html><pre>Cannot POST /api/sessions/s1/permission-mode</pre>');
      await expectLater(
        repo.setPermissionMode('s1', PermissionMode.auto),
        throwsA(
          isA<SessionsException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', 'HTTP 404'),
        ),
      );
      expect((await repo.watchSessions().first.timeout(_timeout)).map((s) => s.id), ['s1']);
    });
  });

  group('org sessions', () {
    final orgSummary = {
      ..._summary('o1', project: ''),
      'cwd': '/dev/otg',
      'org': 'OTG',
      'additionalDirectories': ['/vol/otg', '/vol/otg2'],
    };

    test('parseSummary reads org, cwd and additionalDirectories; project sessions default to none', () {
      final org = parseSummary(orgSummary);
      expect((org.project, org.org, org.cwd, org.isOrgSession), ('', 'OTG', '/dev/otg', true));
      expect(org.additionalDirectories, ['/vol/otg', '/vol/otg2']);
      final project = parseSummary(_summary('p1'));
      expect((project.org, project.cwd, project.isOrgSession), (null, '/tmp', false));
      expect(project.additionalDirectories, isEmpty);
      final engineProject = parseSummary({..._summary('p2'), 'org': null, 'additionalDirectories': []});
      expect(engineProject.org, isNull);
      expect(engineProject.additionalDirectories, isEmpty);
    });

    test('copyWith keeps org, cwd and additionalDirectories', () {
      final next = parseSummary(
        orgSummary,
      ).copyWith(status: SessionStatus.done, cost: 1, pendingPermissions: 2, model: 'opus');
      expect((next.org, next.cwd, next.status), ('OTG', '/dev/otg', SessionStatus.done));
      expect(next.additionalDirectories, ['/vol/otg', '/vol/otg2']);
    });

    test('createInOrg posts {org, command, cwd, additionalDirectories} and lists the new session', () async {
      engine.created = orgSummary;
      await repo.watchSessions().first.timeout(_timeout);
      final listed = repo.watchSessions().firstWhere((l) => l.isNotEmpty).timeout(_timeout);
      final summary = await repo.createInOrg(
        'OTG',
        'analise',
        cwd: '/dev/otg',
        additionalDirectories: ['/vol/otg'],
        permissionMode: PermissionMode.bypassPermissions,
      );
      await repo.createInOrg('OTG', 'só uma raiz', cwd: '/dev/otg', permissionMode: PermissionMode.bypassPermissions);
      expect(engine.posts('/api/sessions').map((r) => r.body), [
        {
          'org': 'OTG',
          'command': 'analise',
          'cwd': '/dev/otg',
          'additionalDirectories': ['/vol/otg'],
          'permissionMode': 'bypassPermissions',
        },
        {
          'org': 'OTG',
          'command': 'só uma raiz',
          'cwd': '/dev/otg',
          'additionalDirectories': <String>[],
          'permissionMode': 'bypassPermissions',
        },
      ]);
      expect(summary.org, 'OTG');
      expect((await listed).single.id, 'o1');
    });

    test('createInOrg surfaces the engine 400 text', () async {
      await repo.watchSessions().first.timeout(_timeout);
      await expectLater(
        repo.createInOrg('OTG', 'a', cwd: '/dev/otg', permissionMode: PermissionMode.bypassPermissions),
        throwsA(isA<Exception>().having((e) => '$e', 'message', startsWith('sem diretório'))),
      );
    });
  });

  test('default backoff is 0.5/1/2/4 s capped at 10 s', () {
    expect(
      [for (var i = 0; i < 7; i++) HttpSessionsRepository.defaultBackoff(i).inMilliseconds],
      [500, 1000, 2000, 4000, 8000, 10000, 10000],
    );
  });
}
