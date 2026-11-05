import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/engine/engine_supervisor.dart';
import 'package:claude_flow/features/inbox/inbox_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _SlowSessions extends MockSessionsRepository {
  final gate = Completer<void>();

  @override
  Future<SessionSummary> create(String project, String command, {String? cwd}) async {
    await gate.future;
    return super.create(project, command, cwd: cwd);
  }
}

class _FailingSessions extends MockSessionsRepository {
  @override
  Future<SessionSummary> create(String project, String command, {String? cwd}) async {
    createCalls.add((project, command, cwd));
    throw const SessionsException('cwd fora das raízes', statusCode: 400);
  }
}

class _LateEngine implements EngineController {
  final states = StreamController<EngineState>.broadcast();

  @override
  Stream<EngineState> watch() async* {
    yield const EngineState.starting();
    yield* states.stream;
  }

  @override
  Future<void> restart() async {}

  @override
  Future<void> shutdown() async {}
}

InboxItem _item({
  int number = 1,
  String repo = 'a',
  String owner = 'acme',
  String? cwd = '/tmp/a',
  List<String> candidates = const [],
  bool draft = false,
}) => InboxItem(
  number: number,
  title: 'Item $number',
  url: 'https://github.com/$owner/$repo/pull/$number',
  repo: repo,
  nameWithOwner: '$owner/$repo',
  author: 'dev',
  updatedAt: DateTime.utc(2020, 1, 2, 12),
  isDraft: draft,
  cwd: cwd,
  cwdCandidates: candidates,
);

final _projects = [const Project(name: 'x', path: '/dev/org/x')];

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

Future<void> _open(
  WidgetTester tester,
  MockGitHubRepository github, {
  MockSessionsRepository? sessions,
  EngineController engine = const MockEngineController(),
  List<Project>? projects,
  String location = '/p/x/inbox',
}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: projects ?? _projects),
      sessions: sessions ?? MockSessionsRepository(),
      engine: engine,
      docs: MockDocsRepository(),
      github: github,
    ),
  );
  await tester.pumpAndSettle();
  _router(tester).go(location);
  await tester.pumpAndSettle();
}

Finder _review(int n) => find.byKey(ValueKey('inbox-review-$n'));

bool _enabled(WidgetTester tester, int n) => tester.widget<OutlinedButton>(_review(n)).onPressed != null;

const _badge = ValueKey('inbox-badge');

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('lists #PR, title, draft badge, repo, author, age and the gh account', (tester) async {
    final github = MockGitHubRepository(
      inboxData: Inbox(login: 'me', items: [_item(number: 7), _item(number: 8, draft: true)]),
    );
    await _open(tester, github);

    expect(find.text('conta do gh: @me'), findsOneWidget);
    expect(find.text('#7'), findsOneWidget);
    expect(find.text('Item 7'), findsOneWidget);
    expect(find.text('a'), findsNWidgets(2));
    expect(find.text('@dev'), findsNWidgets(2));
    expect(find.text('02/01/2020'), findsNWidgets(2));
    expect(find.text('rascunho'), findsOneWidget);
  });

  testWidgets('repo shows owner/repo when the owner differs from the first item', (tester) async {
    final github = MockGitHubRepository(
      inboxData: Inbox(
        items: [
          _item(number: 1),
          _item(number: 2, repo: 'b', owner: 'other'),
        ],
      ),
    );
    await _open(tester, github);

    expect(find.text('a'), findsOneWidget);
    expect(find.text('other/b'), findsOneWidget);
  });

  testWidgets('Revisar creates the session with the derived project name and navigates', (tester) async {
    final sessions = MockSessionsRepository();
    final github = MockGitHubRepository(
      inboxData: Inbox(
        items: [_item(number: 7, repo: 'my_repo', cwd: '/tmp/my_repo')],
      ),
    );
    await _open(tester, github, sessions: sessions);

    await tester.tap(_review(7));
    await tester.pumpAndSettle();

    expect(sessions.createCalls.single, ('my-repo', '/review 7', '/tmp/my_repo'));
    expect(_location(tester), startsWith('/p/my-repo/sessions/'));
  });

  testWidgets('Revisar uses the known project whose path matches the cwd', (tester) async {
    final sessions = MockSessionsRepository();
    final github = MockGitHubRepository(
      inboxData: Inbox(
        items: [_item(number: 7, repo: 'other', cwd: '/dev/org/x')],
      ),
    );
    await _open(tester, github, sessions: sessions);

    await tester.tap(_review(7));
    await tester.pumpAndSettle();

    expect(sessions.createCalls.single, ('x', '/review 7', '/dev/org/x'));
    expect(_location(tester), startsWith('/p/x/sessions/'));
  });

  testWidgets('known project path with a divergent remote does not enable Revisar', (tester) async {
    final github = MockGitHubRepository(
      inboxData: const Inbox(
        items: [
          InboxItem(
            number: 7,
            repo: 'api',
            nameWithOwner: 'otherorg/api',
            cwdCandidates: ['/x/api'],
            cwdReason: '/x/api aponta para clienta/api',
          ),
        ],
      ),
    );
    await _open(
      tester,
      github,
      projects: [
        ..._projects,
        const Project(name: 'api', path: '/x/api'),
      ],
    );

    expect(_enabled(tester, 7), isFalse);
    expect(find.text('sem checkout local: api'), findsOneWidget);
  });

  testWidgets('Revisar is disabled without cwd and during the create', (tester) async {
    final sessions = _SlowSessions();
    final github = MockGitHubRepository(
      inboxData: Inbox(
        items: [
          _item(number: 1),
          _item(number: 2, repo: 'b', cwd: null),
        ],
      ),
    );
    await _open(tester, github, sessions: sessions);

    expect(_enabled(tester, 2), isFalse);
    expect(_enabled(tester, 1), isTrue);

    await tester.tap(_review(1));
    await tester.pump();
    expect(_enabled(tester, 1), isFalse);

    sessions.gate.complete();
    await tester.pumpAndSettle();
    expect(sessions.createCalls.single.$2, '/review 1');
  });

  testWidgets('create error shows inline and does not navigate', (tester) async {
    final sessions = _FailingSessions();
    final github = MockGitHubRepository(inboxData: Inbox(items: [_item(number: 1)]));
    await _open(tester, github, sessions: sessions);

    await tester.tap(_review(1));
    await tester.pumpAndSettle();

    expect(find.text('cwd fora das raízes'), findsOneWidget);
    expect(_location(tester), '/p/x/inbox');
    expect(_enabled(tester, 1), isTrue);
  });

  testWidgets('footer separates missing checkouts from ambiguous ones', (tester) async {
    final github = MockGitHubRepository(
      inboxData: Inbox(
        items: [
          _item(number: 1),
          _item(number: 2, repo: 'b', cwd: null),
          _item(number: 3, repo: 'c', cwd: null, candidates: const ['/p/c1', '/p/c2']),
        ],
      ),
    );
    await _open(tester, github);

    expect(find.text('sem checkout local: b'), findsOneWidget);
    expect(find.text('checkout ambíguo: c (2 cópias); defina cwds.c'), findsOneWidget);
  });

  testWidgets('no footer when every item has a checkout', (tester) async {
    final github = MockGitHubRepository(inboxData: Inbox(items: [_item(number: 1)]));
    await _open(tester, github);

    expect(find.byKey(const ValueKey('inbox-footer')), findsNothing);
  });

  testWidgets('error shows inline, keeps the list and Tentar de novo refetches', (tester) async {
    final github = MockGitHubRepository(inboxData: Inbox(items: [_item(number: 1)]));
    await _open(tester, github);
    expect(github.inboxCalls, 1);

    github.inboxError = const GitHubException('gh sem login (gh auth login)');
    await tester.tap(find.text('Recarregar'));
    await tester.pumpAndSettle();
    expect(github.inboxCalls, 2);
    expect(find.text('gh sem login (gh auth login)'), findsOneWidget);
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.byKey(_badge), findsNothing);

    github.inboxError = null;
    await tester.tap(find.text('Tentar de novo'));
    await tester.pumpAndSettle();
    expect(github.inboxCalls, 3);
    expect(find.text('gh sem login (gh auth login)'), findsNothing);
    expect(find.byKey(_badge), findsOneWidget);
  });

  testWidgets('empty inbox shows the empty state and no badge', (tester) async {
    await _open(tester, MockGitHubRepository());

    expect(find.text('nenhum PR esperando sua revisão'), findsOneWidget);
    expect(find.byKey(_badge), findsNothing);
  });

  testWidgets('badge shows the count on every tab and follows the 120 s refresh', (tester) async {
    final github = MockGitHubRepository(
      inboxData: Inbox(items: [_item(number: 1), _item(number: 2), _item(number: 3)]),
    );
    await _open(tester, github, location: '/p/x/flow');

    expect(tester.widget<Text>(find.descendant(of: find.byKey(_badge), matching: find.byType(Text))).data, '3');

    github.inboxData = Inbox(items: [_item(number: 1)]);
    await tester.pump(const Duration(seconds: 120));
    await tester.pump();
    expect(tester.widget<Text>(find.descendant(of: find.byKey(_badge), matching: find.byType(Text))).data, '1');
    expect(github.inboxCalls, 2);

    github.inboxData = const Inbox(items: []);
    await tester.pump(const Duration(seconds: 120));
    await tester.pump();
    expect(find.byKey(_badge), findsNothing);
  });

  testWidgets('endpoint null: 0 calls and "engine iniciando"; emitted endpoint fetches once', (tester) async {
    final engine = _LateEngine();
    final github = MockGitHubRepository(inboxData: Inbox(items: [_item(number: 1)]));
    await _open(tester, github, engine: engine);

    expect(github.inboxCalls, 0);
    expect(find.descendant(of: find.byType(InboxPage), matching: find.text('engine iniciando')), findsOneWidget);
    expect(find.byKey(_badge), findsNothing);

    engine.states.add(EngineState.ok(Uri.parse('http://127.0.0.1:1')));
    await tester.pumpAndSettle();
    expect(github.inboxCalls, 1);
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.byKey(_badge), findsOneWidget);
  });
}
