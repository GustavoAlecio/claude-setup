import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/github_repository.dart';
import 'package:claude_flow/data/http_github_repository.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Reply = ({int status, String body, String contentType});

class _FakeEngine {
  _FakeEngine._(this._server) {
    _server.listen((request) {
      paths.add(request.uri.toString());
      if (hang.contains(request.uri.path)) return;
      if (raw[request.uri.path] case final bytes?) {
        request.response
          ..headers.contentType = ContentType.json
          ..add(bytes)
          ..close();
        return;
      }
      final reply =
          replies[request.uri.path] ?? (status: 404, body: '<html>Cannot GET</html>', contentType: 'text/html');
      request.response
        ..statusCode = reply.status
        ..headers.contentType = ContentType.parse(reply.contentType)
        ..write(reply.body)
        ..close();
    });
  }

  static Future<_FakeEngine> start() async => _FakeEngine._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final paths = <String>[];
  final replies = <String, _Reply>{};
  final raw = <String, List<int>>{};

  /// Paths that never get an answer.
  final hang = <String>{};

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  void json(String path, Object body, {int status = 200}) =>
      replies[path] = (status: status, body: jsonEncode(body), contentType: 'application/json; charset=utf-8');

  Future<void> close() => _server.close(force: true);
}

void main() {
  late _FakeEngine engine;
  late StreamController<Uri?> endpoint;
  late HttpGitHubRepository repo;

  setUp(() async {
    engine = await _FakeEngine.start();
    endpoint = StreamController<Uri?>();
    repo = HttpGitHubRepository(endpoint.stream, timeout: const Duration(milliseconds: 200));
  });

  tearDown(() async {
    await repo.dispose();
    await endpoint.close();
    await engine.close();
  });

  Future<void> up() async {
    endpoint.add(engine.uri);
    await Future<void>.delayed(Duration.zero);
  }

  test('prs parses the 200 body and encodes the project', () async {
    engine.json('/api/projects/my%20proj/prs', {
      'prs': [
        {'pr_number': 3, 'title': 'T', 'stage': 'approved', 'live': true},
      ],
    });
    await up();
    final prs = await repo.prs('my proj');
    expect(prs.single.number, 3);
    expect(prs.single.live, isTrue);
    expect(engine.paths.single, '/api/projects/my%20proj/prs');
  });

  test('inbox parses items and login', () async {
    engine.json('/api/review-inbox', {
      'login': 'me',
      'items': [
        {'number': 7, 'repo': 'r', 'nameWithOwner': 'o/r', 'url': 'https://github.com/o/r/pull/7'},
      ],
    });
    await up();
    final inbox = await repo.inbox();
    expect(inbox.login, 'me');
    expect(inbox.items.single.number, 7);
  });

  test('prs and inbox send account and repeated owners only when given', () async {
    engine.json('/api/projects/p/prs', {'prs': []});
    engine.json('/api/review-inbox', {'items': []});
    await up();
    await repo.prs('p', account: 'acct-a');
    await repo.prs('p');
    await repo.inbox(account: 'acct-b', owners: ['org-x', 'org-y']);
    await repo.inbox(owners: const []);
    expect(engine.paths, [
      '/api/projects/p/prs?account=acct-a',
      '/api/projects/p/prs',
      '/api/review-inbox?account=acct-b&owner=org-x&owner=org-y',
      '/api/review-inbox',
    ]);
  });

  test('accounts, orgs and protocol parse the new routes', () async {
    engine.json('/api/github/accounts', {
      'accounts': [
        {'login': 'acct-a', 'active': true, 'valid': true},
        {'login': 'acct-b', 'active': false, 'valid': false},
      ],
    });
    engine.json('/api/github/orgs', {
      'login': 'acct-a',
      'orgs': ['acct-a', 'org-x'],
    });
    engine.json('/api/github/protocol', {'protocol': 'ssh'});
    await up();
    final accounts = await repo.accounts();
    expect(
      [for (final a in accounts) (a.login, a.active, a.valid)],
      [('acct-a', true, true), ('acct-b', false, false)],
    );
    expect(await repo.orgs('acct-a'), ['acct-a', 'org-x']);
    expect(await repo.orgs(null), ['acct-a', 'org-x']);
    expect(await repo.protocol(), 'ssh');
    expect(engine.paths, [
      '/api/github/accounts',
      '/api/github/orgs?account=acct-a',
      '/api/github/orgs',
      '/api/github/protocol',
    ]);
  });

  test('sshIdentity sends owner or cwd and fresh=1 only when asked', () async {
    engine.json('/api/github/ssh-identity', {'owner': 'org-x', 'host': 'github.com-alias', 'login': 'acct-b'});
    await up();
    final identity = await repo.sshIdentity(owner: 'org-x', fresh: true);
    expect(
      (identity.owner, identity.host, identity.login, identity.error),
      ('org-x', 'github.com-alias', 'acct-b', null),
    );
    await repo.sshIdentity(cwd: '/dev/org x/repo');
    expect(engine.paths, [
      '/api/github/ssh-identity?owner=org-x&fresh=1',
      '/api/github/ssh-identity?cwd=%2Fdev%2Forg+x%2Frepo',
    ]);
  });

  test('a 400 from the account routes carries the fixed engine message', () async {
    const message = 'conta acct-z não está logada no gh (gh auth login)';
    engine.json('/api/github/orgs', {'error': message}, status: 400);
    await up();
    await expectLater(
      repo.orgs('acct-z'),
      throwsA(isA<GitHubException>().having((e) => e.message, 'message', message)),
    );
  });

  test('502 with a JSON error carries the engine message', () async {
    engine.json('/api/review-inbox', {'error': 'gh sem login (gh auth login)'}, status: 502);
    await up();
    await expectLater(
      repo.inbox(),
      throwsA(isA<GitHubException>().having((e) => e.message, 'message', 'gh sem login (gh auth login)')),
    );
  });

  test('>= 400 without JSON is the bare status', () async {
    engine.replies['/api/review-inbox'] = (status: 500, body: 'boom', contentType: 'text/plain');
    await up();
    await expectLater(repo.inbox(), throwsA(isA<GitHubException>().having((e) => e.message, 'message', 'HTTP 500')));
  });

  test('404 HTML means an outdated engine', () async {
    await up();
    await expectLater(
      repo.prs('x'),
      throwsA(isA<GitHubException>().having((e) => e.message, 'message', 'engine desatualizado; reinicie')),
    );
  });

  test('null endpoint throws without any request', () async {
    endpoint.add(null);
    await Future<void>.delayed(Duration.zero);
    await expectLater(repo.prs('x'), throwsA(isA<GitHubException>()));
    await expectLater(repo.inbox(), throwsA(isA<GitHubException>()));
    expect(engine.paths, isEmpty);
  });

  test('endpoint going back to null stops requests', () async {
    engine.json('/api/review-inbox', {'items': []});
    await up();
    await repo.inbox();
    endpoint.add(null);
    await Future<void>.delayed(Duration.zero);
    await expectLater(repo.inbox(), throwsA(isA<GitHubException>()));
    expect(engine.paths, hasLength(1));
  });

  test('200 with an empty or non-JSON body is an invalid response', () async {
    engine.replies['/api/review-inbox'] = (status: 200, body: 'not json', contentType: 'text/plain');
    await up();
    await expectLater(repo.inbox(), throwsA(isA<GitHubException>()));
  });

  test('unreachable engine becomes a GitHubException', () async {
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close(force: true);
    endpoint.add(Uri.parse('http://127.0.0.1:$port'));
    await Future<void>.delayed(Duration.zero);
    await expectLater(repo.inbox(), throwsA(isA<GitHubException>()));
  });

  test('malformed UTF-8 is an invalid response, not a FormatException', () async {
    engine.raw['/api/review-inbox'] = [0x7b, 0xff, 0xfe, 0x7d];
    await up();
    await expectLater(
      repo.inbox(),
      throwsA(isA<GitHubException>().having((e) => e.message, 'message', 'resposta inválida do engine')),
    );
  });

  test('an engine that never answers times out as a GitHubException', () async {
    engine.hang.add('/api/review-inbox');
    await up();
    await expectLater(
      repo.inbox(),
      throwsA(isA<GitHubException>().having((e) => e.message, 'message', 'engine não respondeu')),
    );
  });
}
