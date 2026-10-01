import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/http_sessions_repository.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/session_reducer.dart';
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
    if (request.method == 'POST' && segments.length == 4) {
      final summary = known[segments[2]];
      return summary == null ? _json(res, 404, {'error': 'sessao nao encontrada'}) : _json(res, 200, summary);
    }
    if (request.method == 'POST' && req.path == '/api/sessions') {
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
        repo.create('demo', 'responda ok'),
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

  test('default backoff is 0.5/1/2/4 s capped at 10 s', () {
    expect(
      [for (var i = 0; i < 7; i++) HttpSessionsRepository.defaultBackoff(i).inMilliseconds],
      [500, 1000, 2000, 4000, 8000, 10000, 10000],
    );
  });
}
