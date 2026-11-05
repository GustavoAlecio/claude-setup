import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/widgets/markdown_view.dart';
import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:claude_flow/engine/engine_supervisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _SlowSessions extends MockSessionsRepository {
  final gate = Completer<void>();

  @override
  Future<SessionSummary> create(String project, String command, {String? cwd, String? githubAccount}) async {
    await gate.future;
    return super.create(project, command, cwd: cwd, githubAccount: githubAccount);
  }
}

class _FailingSessions extends MockSessionsRepository {
  @override
  Future<SessionSummary> create(String project, String command, {String? cwd, String? githubAccount}) async {
    createCalls.add((project, command, cwd, githubAccount));
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

const _thread = ReviewThread(path: 'lib/a.dart', line: 10, author: 'rev', body: 'Extraia **isto**.');

PullRequest _pr({
  int number = 1,
  String stage = 'changes_requested',
  String repo = 'a',
  String owner = 'acme',
  String? cwd = '/tmp/a',
  bool live = true,
  String? liveError,
  List<ReviewThread> unresolved = const [_thread],
  String? adoId,
  PrChecks? checks,
  String? url,
}) => PullRequest(
  number: number,
  adoId: adoId,
  target: 'main',
  title: 'PR $number',
  url: url ?? 'https://github.com/$owner/$repo/pull/$number',
  stage: stage,
  repo: repo,
  nameWithOwner: '$owner/$repo',
  cwd: cwd,
  live: live,
  liveError: liveError,
  checks: checks,
  unresolved: unresolved,
  updatedAt: DateTime.utc(2020, 1, 2, 12),
);

final _projects = [const Project(name: 'x', path: '/dev/org/x')];

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

Future<void> _open(
  WidgetTester tester,
  MockGitHubRepository github, {
  MockSessionsRepository? sessions,
  MockDocsRepository? docs,
  EngineController engine = const MockEngineController(),
  List<Project>? projects,
  Map<String, dynamic>? config,
  String location = '/p/x/prs',
}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: projects ?? _projects, config: config),
      sessions: sessions ?? MockSessionsRepository(),
      engine: engine,
      docs: docs ?? MockDocsRepository(),
      github: github,
    ),
  );
  await tester.pumpAndSettle();
  _router(tester).go(location);
  await tester.pumpAndSettle();
}

/// Org `A` over `/dev/org` (project `x`) with `gh` account `acct-a`.
Map<String, dynamic> _scopedConfig() => {
  'orgs': [
    {
      'name': 'A',
      'roots': ['/dev/org'],
      'github': {
        'account': 'acct-a',
        'owners': ['org-x'],
      },
    },
  ],
  'lastOrg': 'A',
};

class _IdentityGitHub extends MockGitHubRepository {
  _IdentityGitHub({super.pullRequests, required this.byCwd});

  final Map<String, SshIdentity> byCwd;

  @override
  Future<SshIdentity> sshIdentity({String? owner, String? cwd, bool fresh = false}) async {
    sshCalls.add((owner: owner, cwd: cwd, fresh: fresh));
    return byCwd[cwd] ?? const SshIdentity(owner: 'acme', host: 'github.com');
  }
}

Finder _resolve(int n) => find.byKey(ValueKey('pr-resolve-$n'));

bool _enabled(WidgetTester tester, int n) => tester.widget<OutlinedButton>(_resolve(n)).onPressed != null;

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('columns: #PR link, AB#, title, repo, target, stage, CI and age', (tester) async {
    final docs = MockDocsRepository();
    final github = MockGitHubRepository(
      pullRequests: [
        _pr(number: 12, adoId: '4821', checks: PrChecks.failing),
        _pr(number: 13, stage: 'approved', unresolved: const [], checks: PrChecks.passing, url: 'file:///etc/passwd'),
      ],
    );
    await _open(tester, github, docs: docs);

    expect(find.text('#12'), findsOneWidget);
    expect(find.text('AB#4821'), findsOneWidget);
    expect(find.text('PR 12'), findsOneWidget);
    expect(find.text('a'), findsNWidgets(2));
    expect(find.text('main'), findsNWidgets(2));
    expect(find.text('mudanças pedidas'), findsOneWidget);
    expect(find.text('aprovado'), findsOneWidget);
    expect(find.text('falhando'), findsOneWidget);
    expect(find.text('ok'), findsOneWidget);
    expect(find.text('02/01/2020'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('pr-link-12')));
    await tester.pump();
    expect(docs.opened, [Uri.parse('https://github.com/acme/a/pull/12')]);
    expect(find.byKey(const ValueKey('pr-link-13')), findsNothing, reason: 'file: does not pass opensExternally');
  });

  testWidgets('repo shows owner/repo when the owner differs from the first PR', (tester) async {
    final github = MockGitHubRepository(
      pullRequests: [
        _pr(number: 1),
        _pr(number: 2, repo: 'b', owner: 'other'),
      ],
    );
    await _open(tester, github);

    expect(find.text('a'), findsOneWidget);
    expect(find.text('other/b'), findsOneWidget);
  });

  testWidgets('same repo under two owners shows both in full', (tester) async {
    await _open(
      tester,
      MockGitHubRepository(
        pullRequests: [
          _pr(number: 1),
          _pr(number: 2, owner: 'fork'),
        ],
      ),
    );

    expect(find.text('acme/a'), findsOneWidget);
    expect(find.text('fork/a'), findsOneWidget);
  });

  testWidgets('live: false shows the cache badge with liveError as tooltip and the top banner', (tester) async {
    final github = MockGitHubRepository(
      pullRequests: [_pr(live: false, liveError: 'gh sem login (gh auth login)', unresolved: const [])],
    );
    await _open(tester, github);

    expect(find.text('cache'), findsOneWidget);
    expect(find.byTooltip('gh sem login (gh auth login)'), findsOneWidget);
    expect(find.text('não consegui consultar o GitHub'), findsOneWidget);
  });

  testWidgets('waiting banner counts only open PRs with threads', (tester) async {
    final github = MockGitHubRepository(
      pullRequests: [
        _pr(number: 1),
        _pr(number: 2, stage: 'awaiting_review'),
        _pr(number: 3, stage: 'merged'),
      ],
    );
    await _open(tester, github);

    expect(find.text('2 PR(s) com comentários esperando você'), findsOneWidget);
    expect(find.text('não consegui consultar o GitHub'), findsNothing);
  });

  testWidgets('expanding comments shows path:line @author and the body in MarkdownView', (tester) async {
    await _open(tester, MockGitHubRepository(pullRequests: [_pr()]));

    expect(find.text('lib/a.dart:10 @rev'), findsNothing);
    await tester.tap(find.text('▸ 1 comentário(s)'));
    await tester.pumpAndSettle();
    expect(find.text('lib/a.dart:10 @rev'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is MarkdownView && w.source == 'Extraia **isto**.'), findsOneWidget);

    await tester.tap(find.text('▾ 1 comentário(s)'));
    await tester.pumpAndSettle();
    expect(find.text('lib/a.dart:10 @rev'), findsNothing);
  });

  testWidgets('Resolver follows canResolve and is disabled without cwd', (tester) async {
    final github = MockGitHubRepository(
      pullRequests: [
        _pr(number: 1),
        _pr(number: 2, stage: 'merged'),
        _pr(number: 3, stage: 'closed_unmerged'),
        _pr(number: 4, stage: 'approved', unresolved: const []),
        _pr(number: 5, stage: 'algo_novo'),
        _pr(number: 6, repo: 'c', cwd: null),
      ],
    );
    await _open(tester, github);

    expect(_resolve(1), findsOneWidget);
    expect(_enabled(tester, 1), isTrue);
    expect(_resolve(2), findsNothing);
    expect(_resolve(3), findsNothing);
    expect(_resolve(4), findsNothing);
    expect(_resolve(5), findsOneWidget, reason: 'unknown stage is not closed');
    expect(find.text('algo_novo'), findsOneWidget);
    expect(_resolve(6), findsOneWidget);
    expect(_enabled(tester, 6), isFalse);
    expect(find.byTooltip('sem checkout local de c'), findsOneWidget);
  });

  testWidgets('Resolver creates /pr-status in the tab project with the PR cwd and navigates', (tester) async {
    final sessions = _SlowSessions();
    await _open(tester, MockGitHubRepository(pullRequests: [_pr()]), sessions: sessions);

    await tester.tap(_resolve(1));
    await tester.pump();
    expect(_enabled(tester, 1), isFalse, reason: 'disabled while create runs');
    expect(_location(tester), '/p/x/prs');

    sessions.gate.complete();
    await tester.pumpAndSettle();
    expect(sessions.createCalls.single, ('x', '/pr-status', '/tmp/a', null));
    expect(_location(tester), '/p/x/sessions/mock-1');
  });

  testWidgets('Resolver uses the known project path when it is the cwd the engine validated', (tester) async {
    final sessions = MockSessionsRepository();
    await _open(
      tester,
      MockGitHubRepository(pullRequests: [_pr(cwd: '/dev/org/a')]),
      sessions: sessions,
      projects: [
        ..._projects,
        const Project(name: 'a', path: '/dev/org/a/'),
      ],
    );

    await tester.tap(_resolve(1));
    await tester.pumpAndSettle();
    expect(sessions.createCalls.single, ('x', '/pr-status', '/dev/org/a/', null));
  });

  testWidgets('known project path with a divergent remote keeps Resolver disabled', (tester) async {
    const pr = PullRequest(
      number: 1,
      stage: 'changes_requested',
      repo: 'api',
      nameWithOwner: 'otherorg/api',
      cwdCandidates: ['/x/api'],
      cwdReason: '/x/api aponta para clienta/api',
      live: true,
      unresolved: [_thread],
    );
    await _open(
      tester,
      MockGitHubRepository(pullRequests: [pr]),
      projects: [
        ..._projects,
        const Project(name: 'api', path: '/x/api'),
      ],
    );

    expect(_enabled(tester, 1), isFalse);
  });

  testWidgets('Resolver error shows inline on the row and does not navigate', (tester) async {
    final sessions = _FailingSessions();
    await _open(tester, MockGitHubRepository(pullRequests: [_pr()]), sessions: sessions);

    await tester.tap(_resolve(1));
    await tester.pumpAndSettle();
    expect(sessions.createCalls, hasLength(1));
    expect(find.text('cwd fora das raízes'), findsOneWidget);
    expect(_location(tester), '/p/x/prs');
    expect(_enabled(tester, 1), isTrue);
  });

  testWidgets('no PRs shows the empty state', (tester) async {
    await _open(tester, MockGitHubRepository.empty());

    expect(find.text('nenhum PR registrado; abra com /pr-open'), findsOneWidget);
  });

  testWidgets('refresh: 1 call on open, again every 60 s, none after leaving the tab', (tester) async {
    final github = MockGitHubRepository(pullRequests: [_pr()]);
    await _open(tester, github);
    expect(github.prsCalls, [('x', null)]);

    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(github.prsCalls, [('x', null), ('x', null)]);

    _router(tester).go('/p/x/flow');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 180));
    await tester.pump();
    expect(github.prsCalls, hasLength(2));
  });

  testWidgets('Recarregar fetches again', (tester) async {
    final github = MockGitHubRepository(pullRequests: [_pr()]);
    await _open(tester, github);

    await tester.tap(find.text('Recarregar'));
    await tester.pumpAndSettle();
    expect(github.prsCalls, hasLength(2));
  });

  testWidgets('error shows inline with Tentar de novo and keeps the previous list', (tester) async {
    final github = MockGitHubRepository(pullRequests: [_pr(number: 12)]);
    await _open(tester, github);
    expect(find.text('PR 12'), findsOneWidget);

    github.prsError = const GitHubException('engine desatualizado; reinicie');
    await tester.tap(find.text('Recarregar'));
    await tester.pumpAndSettle();
    expect(find.text('engine desatualizado; reinicie'), findsOneWidget);
    expect(find.text('PR 12'), findsOneWidget);

    github.prsError = null;
    await tester.tap(find.text('Tentar de novo'));
    await tester.pumpAndSettle();
    expect(github.prsCalls, hasLength(3));
    expect(find.text('engine desatualizado; reinicie'), findsNothing);
    expect(find.text('PR 12'), findsOneWidget);
  });

  testWidgets('engine without endpoint shows "engine iniciando" and loads when it arrives', (tester) async {
    final engine = _LateEngine();
    final github = MockGitHubRepository(pullRequests: [_pr(number: 12)]);
    await _open(tester, github, engine: engine);

    expect(find.text('engine iniciando'), findsWidgets);
    expect(github.prsCalls, isEmpty);

    engine.states.add(EngineState.ok(Uri.parse('http://127.0.0.1:1')));
    await tester.pumpAndSettle();
    expect(github.prsCalls, [('x', null)]);
    expect(find.text('PR 12'), findsOneWidget);
  });

  testWidgets('endpoint changing to another port reloads', (tester) async {
    final engine = _LateEngine();
    final github = MockGitHubRepository(pullRequests: [_pr(number: 12)]);
    await _open(tester, github, engine: engine);

    engine.states.add(EngineState.ok(Uri.parse('http://127.0.0.1:1')));
    await tester.pumpAndSettle();
    expect(github.prsCalls, [('x', null)]);

    engine.states.add(EngineState.ok(Uri.parse('http://127.0.0.1:1'), versionWarning: 'v'));
    await tester.pumpAndSettle();
    expect(github.prsCalls, [('x', null)], reason: 'same endpoint does not reload');

    engine.states.add(EngineState.ok(Uri.parse('http://127.0.0.1:2')));
    await tester.pumpAndSettle();
    expect(github.prsCalls, [('x', null), ('x', null)]);
  });

  testWidgets('switching project drops the answer for the previous one', (tester) async {
    final github = _GatedGitHub([_pr(number: 12)]);
    await _open(
      tester,
      github,
      projects: [
        ..._projects,
        const Project(name: 'y', path: '/dev/org/y'),
      ],
    );
    expect(github.prsCalls, [('x', null)]);

    _router(tester).go('/p/y/prs');
    await tester.pumpAndSettle();
    expect(github.prsCalls, [('x', null), ('y', null)]);

    github.gates['x']!.complete([_pr(number: 99)]);
    await tester.pumpAndSettle();
    expect(find.text('PR 99'), findsNothing);

    github.gates['y']!.complete([_pr(number: 12)]);
    await tester.pumpAndSettle();
    expect(find.text('PR 12'), findsOneWidget);
  });

  group('account of the project org', () {
    testWidgets('prs is called with the org account and Resolver passes it as githubAccount', (tester) async {
      final sessions = MockSessionsRepository();
      final github = MockGitHubRepository(pullRequests: [_pr()]);
      await _open(tester, github, sessions: sessions, config: _scopedConfig());

      expect(github.prsCalls, [('x', 'acct-a')]);

      await tester.tap(_resolve(1));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single, ('x', '/pr-status', '/tmp/a', 'acct-a'));
    });

    testWidgets('project outside any org uses the active account', (tester) async {
      final github = MockGitHubRepository(pullRequests: [_pr()]);
      await _open(
        tester,
        github,
        config: _scopedConfig(),
        projects: [
          ..._projects,
          const Project(name: 'loose', path: '/elsewhere/loose'),
        ],
        location: '/p/loose/prs',
      );

      expect(github.prsCalls, [('loose', null)]);
    });

    testWidgets('changing the org account reloads with the new one', (tester) async {
      final repo = MockFlowRepository(data: _projects, config: _scopedConfig());
      final github = MockGitHubRepository(pullRequests: [_pr()]);
      await tester.pumpWidget(
        ClaudeFlowApp(
          repository: repo,
          sessions: MockSessionsRepository(),
          engine: const MockEngineController(),
          docs: MockDocsRepository(),
          github: github,
        ),
      );
      await tester.pumpAndSettle();
      _router(tester).go('/p/x/prs');
      await tester.pumpAndSettle();
      expect(github.prsCalls, [('x', 'acct-a')]);

      final org = repo.config.orgs.single;
      await repo.updateConfig(
        saveOrgs([
          OrgConfig(
            name: org.name,
            roots: org.roots,
            github: const OrgGithub(account: 'acct-b', owners: ['org-x']),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(github.prsCalls, [('x', 'acct-a'), ('x', 'acct-b')]);
    });

    testWidgets('https push remote shows the credential helper warning and keeps Resolver enabled', (tester) async {
      final github = _IdentityGitHub(
        pullRequests: [
          _pr(),
          _pr(number: 2, repo: 'b', cwd: '/tmp/b'),
        ],
        byCwd: {
          '/tmp/a': const SshIdentity(
            owner: 'acme',
            error: 'remote https: identidade definida pelo credential helper, não verificável',
          ),
          '/tmp/b': const SshIdentity(owner: 'acme', host: 'github.com', login: 'acct-a'),
        },
      );
      await _open(tester, github, config: _scopedConfig());

      expect(
        find.text('a: remote HTTPS: push usa o credential helper do git (osxkeychain), não a conta @acct-a'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('prs-https-/tmp/b')), findsNothing);
      expect(github.sshCalls.map((c) => c.cwd), ['/tmp/a', '/tmp/b']);
      expect(_enabled(tester, 1), isTrue);
    });

    testWidgets('SSH push identity of another account shows the divergence', (tester) async {
      final github = _IdentityGitHub(
        pullRequests: [_pr()],
        byCwd: {'/tmp/a': const SshIdentity(owner: 'acme', host: 'github.com-alias', login: 'acct-b')},
      );
      await _open(tester, github, config: _scopedConfig());

      expect(find.text('SSH de acme autentica como @acct-b, diferente da conta @acct-a'), findsOneWidget);
    });

    testWidgets('identity of a cwd is asked once across refreshes', (tester) async {
      final github = _IdentityGitHub(pullRequests: [_pr()], byCwd: const {});
      await _open(tester, github, config: _scopedConfig());
      await tester.pump(const Duration(seconds: 60));
      await tester.pumpAndSettle();

      expect(github.prsCalls, hasLength(2));
      expect(github.sshCalls, hasLength(1));
    });
  });
}

class _GatedGitHub extends MockGitHubRepository {
  _GatedGitHub(List<PullRequest> prs) : super(pullRequests: prs);

  final gates = <String, Completer<List<PullRequest>>>{};

  @override
  Future<List<PullRequest>> prs(String project, {String? account}) {
    prsCalls.add((project, account));
    return (gates[project] = Completer()).future;
  }
}
