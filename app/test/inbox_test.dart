import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/inbox_cubit.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/orgs.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:claude_flow/engine/engine_supervisor.dart';
import 'package:claude_flow/features/inbox/inbox_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _SlowSessions extends MockSessionsRepository {
  final gate = Completer<void>();

  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
  }) async {
    await gate.future;
    return super.create(project, command, cwd: cwd, githubAccount: githubAccount, permissionMode: permissionMode);
  }
}

class _FailingSessions extends MockSessionsRepository {
  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
  }) async {
    createCalls.add((project, command, cwd, githubAccount, permissionMode));
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
  MockFlowRepository? repository,
  String location = '/p/x/inbox',
}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: repository ?? MockFlowRepository(data: projects ?? _projects),
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

/// Inbox calls as `account:owners`, since records holding lists do not compare by content.
List<String> _calls(MockGitHubRepository github) => [for (final (a, o) in github.inboxCalls) '$a:${o.join(',')}'];

class _GatedInbox extends MockGitHubRepository {
  final gates = <Completer<Inbox>>[];

  @override
  Future<Inbox> inbox({String? account, List<String> owners = const []}) {
    inboxCalls.add((account, List.unmodifiable(owners)));
    final gate = Completer<Inbox>();
    gates.add(gate);
    return gate.future;
  }
}

const _orgProjects = [Project(name: 'x', path: '/dev/a/x'), Project(name: 'y', path: '/dev/b/y')];

/// Org `A` (project `x`) on `acct-a` + `org-x`, org `B` (project `y`) on `acct-b` + `org-y`; opens in `A`.
Map<String, dynamic> _twoOrgs() => {
  'orgs': [
    {
      'name': 'A',
      'roots': ['/dev/a'],
      'github': {
        'account': 'acct-a',
        'owners': ['org-x'],
      },
    },
    {
      'name': 'B',
      'roots': ['/dev/b'],
      'github': {
        'account': 'acct-b',
        'owners': ['org-y'],
      },
    },
  ],
  'lastOrg': 'A',
};

Future<void> _meta(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
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

    expect(sessions.createCalls.single, (
      'my-repo',
      '/review 7',
      '/tmp/my_repo',
      null,
      PermissionMode.bypassPermissions,
    ));
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

    expect(sessions.createCalls.single, ('x', '/review 7', '/dev/org/x', null, PermissionMode.bypassPermissions));
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
    expect(github.inboxCalls, hasLength(1));

    github.inboxError = const GitHubException('gh sem login (gh auth login)');
    await tester.tap(find.text('Recarregar'));
    await tester.pumpAndSettle();
    expect(github.inboxCalls, hasLength(2));
    expect(find.text('gh sem login (gh auth login)'), findsOneWidget);
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.byKey(_badge), findsNothing);

    github.inboxError = null;
    await tester.tap(find.text('Tentar de novo'));
    await tester.pumpAndSettle();
    expect(github.inboxCalls, hasLength(3));
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
    expect(github.inboxCalls, hasLength(2));

    github.inboxData = const Inbox(items: []);
    await tester.pump(const Duration(seconds: 120));
    await tester.pump();
    expect(find.byKey(_badge), findsNothing);
  });

  testWidgets('endpoint null: 0 calls and "engine iniciando"; emitted endpoint fetches once', (tester) async {
    final engine = _LateEngine();
    final github = MockGitHubRepository(inboxData: Inbox(items: [_item(number: 1)]));
    await _open(tester, github, engine: engine);

    expect(github.inboxCalls, isEmpty);
    expect(find.descendant(of: find.byType(InboxPage), matching: find.text('engine iniciando')), findsOneWidget);
    expect(find.byKey(_badge), findsNothing);

    engine.states.add(EngineState.ok(Uri.parse('http://127.0.0.1:1')));
    await tester.pumpAndSettle();
    expect(github.inboxCalls, hasLength(1));
    expect(find.text('Item 1'), findsOneWidget);
    expect(find.byKey(_badge), findsOneWidget);
  });

  group('scope of the current org', () {
    test('org switch empties the state, fetches the new scope and drops the late answer', () async {
      final repo = MockFlowRepository(data: _orgProjects, config: _twoOrgs());
      final github = _GatedInbox();
      final cubit = InboxCubit(
        github,
        Stream.value(Uri.parse('http://127.0.0.1:1')),
        repo.watchConfig().map((c) => githubFor(c.lastOrg, c)),
      );
      addTearDown(cubit.close);
      await pumpEventQueue();
      expect(_calls(github), ['acct-a:org-x']);

      github.gates[0].complete(Inbox(items: [_item(number: 1)]));
      await pumpEventQueue();
      expect(cubit.state.badge, 1);

      unawaited(cubit.refresh());
      await repo.updateConfig(setLastOrg('B'));
      await pumpEventQueue();
      expect(cubit.state.inbox, isNull);
      expect(cubit.state.badge, 0);
      expect(cubit.state.scope, const GithubScope(account: 'acct-b', owners: ['org-y']));
      expect(_calls(github), ['acct-a:org-x', 'acct-a:org-x', 'acct-b:org-y']);

      github.gates[1].complete(Inbox(items: [_item(number: 1), _item(number: 2)]));
      await pumpEventQueue();
      expect(cubit.state.inbox, isNull, reason: 'answer for A arrived after the switch');

      github.gates[2].complete(Inbox(items: [_item(number: 3)]));
      await pumpEventQueue();
      expect(cubit.state.inbox!.items.single.number, 3);
    });

    test('a config change that keeps the scope does not refetch', () async {
      final repo = MockFlowRepository(data: _orgProjects, config: _twoOrgs());
      final github = MockGitHubRepository();
      final cubit = InboxCubit(
        github,
        Stream.value(Uri.parse('http://127.0.0.1:1')),
        repo.watchConfig().map((c) => githubFor(c.lastOrg, c)),
      );
      addTearDown(cubit.close);
      await pumpEventQueue();

      await repo.updateConfig(hideProject('x'));
      await pumpEventQueue();
      expect(_calls(github), ['acct-a:org-x']);
    });

    testWidgets('header shows account and owners; ⌘2 refetches with the other org', (tester) async {
      final github = MockGitHubRepository(inboxData: Inbox(items: [_item(number: 1)]));
      await _open(
        tester,
        github,
        repository: MockFlowRepository(data: _orgProjects, config: _twoOrgs()),
      );

      expect(_calls(github), ['acct-a:org-x']);
      expect(find.text('conta do gh: @acct-a · orgs: org-x'), findsOneWidget);

      await _meta(tester, LogicalKeyboardKey.digit2);
      expect(_calls(github).last, 'acct-b:org-y');

      _router(tester).go('/p/y/inbox');
      await tester.pumpAndSettle();
      expect(find.text('conta do gh: @acct-b · orgs: org-y'), findsOneWidget);
    });

    testWidgets('editing the owners of the current org refetches with them', (tester) async {
      final repo = MockFlowRepository(data: _orgProjects, config: _twoOrgs());
      final github = MockGitHubRepository();
      await _open(tester, github, repository: repo);
      expect(_calls(github), ['acct-a:org-x']);

      await repo.updateConfig(
        saveOrgs([
          for (final o in repo.config.orgs)
            o.name == 'A'
                ? OrgConfig(
                    name: o.name,
                    roots: o.roots,
                    github: const OrgGithub(account: 'acct-a', owners: ['org-x', 'org-z']),
                  )
                : o,
        ]),
      );
      await tester.pumpAndSettle();
      expect(_calls(github), ['acct-a:org-x', 'acct-a:org-x,org-z']);
    });

    testWidgets('Revisar uses the account that listed the item, even for a project of another org', (tester) async {
      final sessions = MockSessionsRepository();
      final github = MockGitHubRepository(
        inboxData: Inbox(
          items: [_item(number: 7, repo: 'y', cwd: '/dev/b/y')],
        ),
      );
      await _open(
        tester,
        github,
        sessions: sessions,
        repository: MockFlowRepository(data: _orgProjects, config: _twoOrgs()),
      );

      await tester.tap(_review(7));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single, ('y', '/review 7', '/dev/b/y', 'acct-a', PermissionMode.bypassPermissions));
    });

    testWidgets('Revisar uses the mode of the org of the cwd, not of the listing scope', (tester) async {
      final config = _twoOrgs();
      config['permissionMode'] = 'default';
      ((config['orgs'] as List)[1] as Map)['permissionMode'] = 'acceptEdits';
      final sessions = MockSessionsRepository();
      final github = MockGitHubRepository(
        inboxData: Inbox(
          items: [
            _item(number: 7, repo: 'y', cwd: '/dev/b/y'),
            _item(number: 8, repo: 'x', cwd: '/dev/a/x'),
          ],
        ),
      );
      await _open(
        tester,
        github,
        sessions: sessions,
        repository: MockFlowRepository(data: _orgProjects, config: config),
      );

      await tester.tap(_review(7));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$5, PermissionMode.acceptEdits);

      _router(tester).go('/p/x/inbox');
      await tester.pumpAndSettle();
      await tester.tap(_review(8));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.last.$3, '/dev/a/x');
      expect(sessions.createCalls.last.$5, PermissionMode.defaultMode);
    });

    testWidgets('owner whose SSH authenticates as another account shows the alert', (tester) async {
      final github = MockGitHubRepository(
        inboxData: Inbox(items: [_item(number: 1)]),
        sshIdentities: const {'org-x': SshIdentity(owner: 'org-x', host: 'github.com-alias', login: 'acct-b')},
      );
      await _open(
        tester,
        github,
        repository: MockFlowRepository(data: _orgProjects, config: _twoOrgs()),
      );

      expect(find.text('SSH de org-x autentica como @acct-b, diferente da conta @acct-a'), findsOneWidget);
      expect(github.sshCalls.single, (owner: 'org-x', cwd: null, fresh: false));
    });

    testWidgets('no SSH check without a configured account', (tester) async {
      final github = MockGitHubRepository(inboxData: Inbox(items: [_item(number: 1)]));
      await _open(tester, github);

      expect(github.sshCalls, isEmpty);
    });
  });
}
