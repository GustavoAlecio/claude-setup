import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/widgets/markdown_view.dart';
import 'package:claude_flow/core/widgets/primitives.dart';
import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/docs_repository.dart';
import 'package:claude_flow/data/docs_models.dart';
import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/data/tracker.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:claude_flow/engine/engine_supervisor.dart';
import 'package:flutter/material.dart';
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
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  }) async {
    await gate.future;
    return super.create(
      project,
      command,
      cwd: cwd,
      githubAccount: githubAccount,
      permissionMode: permissionMode,
      agent: agent,
    );
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
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
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
  CardRef? card,
  PrChecks? checks,
  String? url,
  bool noUrl = false,
  String? title,
}) => PullRequest(
  number: number,
  card: card,
  target: 'main',
  title: title ?? 'PR $number',
  url: noUrl ? null : url ?? 'https://github.com/$owner/$repo/pull/$number',
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

class _FailingDocs extends MockDocsRepository {
  @override
  Future<DocsListing> list(String project) => Future.error(StateError('docs offline'));
}

class _FlakyDocs extends MockDocsRepository {
  bool failing = false;

  @override
  Future<DocsListing> list(String project) => failing ? Future.error(StateError('docs offline')) : super.list(project);
}

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

String? _state(WidgetTester tester, int n) => tester.widget<Text>(find.byKey(ValueKey('pr-state-$n'))).data;

bool _enabled(WidgetTester tester, int n) => tester.widget<OutlinedButton>(_resolve(n)).onPressed != null;

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('PRs without url keep distinct row keys (same number, or no number)', (tester) async {
    final github = MockGitHubRepository(
      pullRequests: [
        _pr(number: 7, noUrl: true),
        _pr(number: 7, noUrl: true),
        _pr(number: 8, noUrl: true, unresolved: const []),
      ],
    );
    await _open(tester, github);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('prs-needs-you')), findsOneWidget);
    expect(find.byKey(const ValueKey('prs-mine')), findsOneWidget);
  });

  testWidgets('PRs without url and without number render without key collisions', (tester) async {
    final updatedAt = DateTime.utc(2020, 1, 2, 12);
    final github = MockGitHubRepository(
      pullRequests: [
        PullRequest(title: 'A', stage: 'changes_requested', unresolved: const [_thread], updatedAt: updatedAt),
        PullRequest(title: 'B', stage: 'changes_requested', unresolved: const [_thread], updatedAt: updatedAt),
      ],
    );
    await _open(tester, github);
    expect(tester.takeException(), isNull);
    expect(find.text('A'), findsWidgets);
    expect(find.text('B'), findsWidgets);
  });

  testWidgets('rows: #PR link, card, title and the state line; no table', (tester) async {
    final docs = MockDocsRepository();
    final github = MockGitHubRepository(
      pullRequests: [
        _pr(
          number: 12,
          card: const CardRef(kind: TrackerKind.ado, id: '4821'),
          checks: PrChecks.failing,
        ),
        _pr(number: 13, stage: 'approved', unresolved: const [], checks: PrChecks.passing, url: 'file:///etc/passwd'),
      ],
    );
    await _open(tester, github, docs: docs);

    expect(find.byKey(const ValueKey('prs-mine')), findsOneWidget);
    expect(find.text('Seus PRs'), findsOneWidget);
    expect(find.byKey(const ValueKey('pr-row-12')), findsOneWidget);
    expect(find.byKey(const ValueKey('pr-row-13')), findsOneWidget);
    expect(find.text('#12'), findsOneWidget);
    expect(find.text('AB#4821'), findsOneWidget);
    expect(find.text('PR 12'), findsOneWidget);
    expect(_state(tester, 12), '1 comentário esperando você');
    expect(_state(tester, 13), 'aprovado');
    expect(find.byType(TableHeaderRow), findsNothing);
    expect(find.byKey(const ValueKey('prs-waiting')), findsNothing);
    expect(find.text('main'), findsNothing);
    expect(find.text('falhando'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pr-link-12')));
    await tester.pump();
    expect(docs.opened, [Uri.parse('https://github.com/acme/a/pull/12')]);
    expect(find.byKey(const ValueKey('pr-link-13')), findsNothing, reason: 'file: does not pass opensExternally');

    await tester.tap(find.text('PR 12'));
    await tester.pump();
    expect(docs.opened, hasLength(2), reason: 'the whole row opens the PR');
    await tester.tap(find.text('PR 13'));
    await tester.pump();
    expect(docs.opened, hasLength(2));
  });

  testWidgets('state line has no repo prefix when every PR is in the same repo', (tester) async {
    await _open(
      tester,
      MockGitHubRepository(
        pullRequests: [
          _pr(number: 1),
          _pr(number: 2, unresolved: const []),
        ],
      ),
    );

    expect(_state(tester, 1), '1 comentário esperando você');
    expect(_state(tester, 2), 'mudanças pedidas');
  });

  testWidgets('state line shows owner/repo when the owner differs from the first PR', (tester) async {
    final github = MockGitHubRepository(
      pullRequests: [
        _pr(number: 1),
        _pr(number: 2, repo: 'b', owner: 'other'),
      ],
    );
    await _open(tester, github);

    expect(_state(tester, 1), 'a · 1 comentário esperando você');
    expect(_state(tester, 2), 'other/b · 1 comentário esperando você');
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

    expect(_state(tester, 1), 'acme/a · 1 comentário esperando você');
    expect(_state(tester, 2), 'fork/a · 1 comentário esperando você');
  });

  testWidgets('live: false ends the state in "do cache" with liveError as tooltip and the top banner', (tester) async {
    final github = MockGitHubRepository(
      pullRequests: [_pr(live: false, liveError: 'gh sem login (gh auth login)', unresolved: const [])],
    );
    await _open(tester, github);

    expect(_state(tester, 1), 'mudanças pedidas · do cache');
    expect(find.byTooltip('gh sem login (gh auth login)'), findsOneWidget);
    expect(find.text('não consegui consultar o GitHub'), findsOneWidget);
    expect(find.byKey(const ValueKey('prs-needs-you')), findsNothing);
  });

  group('needs you', () {
    Finder inBlock(String text) =>
        find.descendant(of: find.byKey(const ValueKey('prs-needs-you')), matching: find.text(text));

    testWidgets('one block per open PR with threads, in list order', (tester) async {
      final github = MockGitHubRepository(
        pullRequests: [
          _pr(number: 1),
          _pr(number: 2, stage: 'awaiting_review'),
          _pr(number: 3, stage: 'merged'),
        ],
      );
      await _open(tester, github);

      expect(inBlock('Precisa de você'), findsOneWidget);
      expect(inBlock('O PR #1 recebeu 1 comentário de revisão'), findsOneWidget);
      expect(inBlock('O PR #2 recebeu 1 comentário de revisão'), findsOneWidget);
      expect(inBlock('Em a.dart. O agente resolve; você confere antes do push.'), findsNWidgets(2));
      expect(inBlock('O PR #3 recebeu 1 comentário de revisão'), findsNothing);
      expect(_resolve(3), findsNothing);
      expect(find.byKey(const ValueKey('prs-waiting')), findsNothing);
      expect(find.text('não consegui consultar o GitHub'), findsNothing);
    });

    testWidgets('2 threads with cwd, a merged PR and an approved one with failing CI', (tester) async {
      final sessions = MockSessionsRepository();
      final github = MockGitHubRepository(
        pullRequests: [
          _pr(
            number: 7,
            unresolved: const [
              _thread,
              ReviewThread(path: 'lib/b.dart', author: 'rev', body: 'Renomeie.'),
            ],
          ),
          _pr(number: 8, stage: 'merged', unresolved: const []),
          _pr(number: 9, stage: 'approved', unresolved: const [], checks: PrChecks.failing),
        ],
      );
      await _open(tester, github, sessions: sessions);

      expect(inBlock('O PR #7 recebeu 2 comentários de revisão'), findsOneWidget);
      expect(inBlock('Em a.dart e b.dart. O agente resolve; você confere antes do push.'), findsOneWidget);
      expect(_state(tester, 7), '2 comentários esperando você');
      expect(_state(tester, 8), startsWith('mergeado'));
      expect(_state(tester, 9), 'aprovado, mas o CI falhou');
      expect(find.byType(TableHeaderRow), findsNothing);

      await tester.tap(find.byKey(const ValueKey('pr-comments-7')));
      await tester.pumpAndSettle();
      expect(find.text('lib/a.dart:10 @rev'), findsOneWidget);
      expect(find.text('lib/b.dart @rev'), findsOneWidget);

      await tester.tap(_resolve(7));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single, ('x', '/pr-status', '/tmp/a', null, PermissionMode.acceptEdits));
    });

    testWidgets('no PR with comments, no block', (tester) async {
      await _open(
        tester,
        MockGitHubRepository(
          pullRequests: [_pr(stage: 'approved', unresolved: const [])],
        ),
      );

      expect(find.byKey(const ValueKey('prs-needs-you')), findsNothing);
      expect(find.byKey(const ValueKey('pr-comments-1')), findsNothing);
      expect(find.byKey(const ValueKey('pr-row-1')), findsOneWidget);
    });

    testWidgets('pr-comments shows path:line @author and the body in MarkdownView', (tester) async {
      await _open(tester, MockGitHubRepository(pullRequests: [_pr()]));

      expect(find.text('lib/a.dart:10 @rev'), findsNothing);
      expect(inBlock('ver 1 comentário'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pr-comments-1')));
      await tester.pumpAndSettle();
      expect(find.text('lib/a.dart:10 @rev'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is MarkdownView && w.source == 'Extraia **isto**.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pr-comments-1')));
      await tester.pumpAndSettle();
      expect(find.text('lib/a.dart:10 @rev'), findsNothing);
    });
  });

  group('layout', () {
    testWidgets('two #1 in different repos render without duplicate keys', (tester) async {
      await _open(
        tester,
        MockGitHubRepository(
          pullRequests: [
            _pr(number: 1),
            _pr(number: 1, repo: 'b'),
          ],
        ),
      );

      expect(tester.takeException(), isNull);
      final states = tester.widgetList<Text>(find.byKey(const ValueKey('pr-state-1')));
      expect(states.map((t) => t.data), ['a · 1 comentário esperando você', 'b · 1 comentário esperando você']);
      expect(find.byKey(const ValueKey('pr-row-1')), findsNWidgets(2));
      expect(_resolve(1), findsNWidgets(2));
    });

    testWidgets('1100x700 with long titles in 2 repos, comments and 3 reviews does not overflow', (tester) async {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1100, 700);
      view.devicePixelRatio = 1;
      final title = 'x' * 120;
      final docs = MockDocsRepository()
        ..write('reviews/PR-200.md', '---\ntitle: $title\nstatus: approved\n---\n# Review PR-200\n');
      final github = MockGitHubRepository(
        pullRequests: [
          _pr(
            number: 1,
            title: title,
            card: const CardRef(kind: TrackerKind.ado, id: '4821'),
          ),
          _pr(number: 2, title: title, repo: 'b', owner: 'other-organization', cwd: null),
          _pr(number: 3, title: title, stage: 'merged', unresolved: const []),
          _pr(number: 4, title: title, stage: 'approved', unresolved: const [], checks: PrChecks.failing),
          _pr(number: 5, title: title, repo: 'b', owner: 'other-organization', live: false, unresolved: const []),
        ],
      );
      await _open(tester, github, docs: docs);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('prs-needs-you')), findsOneWidget);
      expect(_resolve(1), findsOneWidget);
      expect(_resolve(2), findsOneWidget);
      for (var n = 1; n <= 5; n++) {
        expect(find.byKey(ValueKey('pr-row-$n')), findsOneWidget);
      }
      for (final n in [157, 9, 200]) {
        expect(find.byKey(ValueKey('review-row-$n')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('review-open-200')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pr-comments-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
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
    expect(_state(tester, 5), 'a · 1 comentário esperando você', reason: 'comments win over the raw stage');
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
    expect(sessions.createCalls.single, ('x', '/pr-status', '/tmp/a', null, PermissionMode.acceptEdits));
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
    expect(sessions.createCalls.single, ('x', '/pr-status', '/dev/org/a/', null, PermissionMode.acceptEdits));
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

  group('reviews load', () {
    testWidgets('without endpoint the reviews still show and open the review screen', (tester) async {
      final engine = _LateEngine();
      await _open(tester, MockGitHubRepository(pullRequests: [_pr(number: 12)]), engine: engine);

      expect(
        find.descendant(of: find.byKey(const ValueKey('prs-mine')), matching: find.text('engine iniciando')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('prs-reviews')),
          matching: find.byKey(const ValueKey('review-row-157')),
        ),
        findsOneWidget,
      );
      expect(find.text('feat: cache de partidas'), findsOneWidget);
      expect(find.text('rascunho pronto: 2 problemas sérios, 1 menor'), findsOneWidget);
      expect(find.byKey(const ValueKey('review-open-157')), findsOneWidget);
      expect(find.byKey(const ValueKey('review-open-9')), findsNothing);
      expect(find.text('publicada em 28 set'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('review-row-157')));
      await tester.pumpAndSettle();
      final uri = _router(tester).routerDelegate.currentConfiguration.uri;
      expect(uri.toString(), '/p/x/reviews?pr=157');
    });

    testWidgets('a PR load error keeps the reviews', (tester) async {
      final github = MockGitHubRepository(pullRequests: [_pr(number: 12)]);
      github.prsError = const GitHubException('engine desatualizado; reinicie');
      await _open(tester, github);

      expect(find.text('engine desatualizado; reinicie'), findsOneWidget);
      expect(find.byKey(const ValueKey('review-row-157')), findsOneWidget);
    });

    testWidgets('docs failing on list show prs-reviews-error and keep the PRs', (tester) async {
      await _open(tester, MockGitHubRepository(pullRequests: [_pr(number: 12)]), docs: _FailingDocs());

      expect(find.byKey(const ValueKey('prs-reviews-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('review-row-157')), findsNothing);
      expect(find.text('PR 12'), findsOneWidget);
    });

    testWidgets('a failing round after a good load keeps the rows and shows the error above them', (tester) async {
      final docs = _FlakyDocs();
      await _open(tester, MockGitHubRepository(pullRequests: [_pr(number: 12)]), docs: docs);
      expect(find.byKey(const ValueKey('review-row-157')), findsOneWidget);
      expect(find.byKey(const ValueKey('prs-reviews-error')), findsNothing);

      docs.failing = true;
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('prs-reviews-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('review-row-157')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('prs-reviews-error'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('review-row-157'))).dy),
      );

      docs.failing = false;
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('prs-reviews-error')), findsNothing);
      expect(find.byKey(const ValueKey('review-row-157')), findsOneWidget);
    });

    testWidgets('an empty front-matter title falls back to the meta, then to Review PR-n', (tester) async {
      final docs = MockDocsRepository.empty()
        ..write('reviews/PR-5.md', '---\ntitle:\nstatus: draft\n---\n# x\n')
        ..write('reviews/PR-5.meta.json', '{"number": 5, "title": "fix: do meta"}')
        ..write('reviews/PR-6.md', '---\ntitle: ""\nstatus: draft\n---\n# x\n')
        ..write('reviews/PR-6.meta.json', '{"number": 6, "title": ""}');
      await _open(tester, MockGitHubRepository(pullRequests: [_pr(number: 12)]), docs: docs);

      expect(find.text('fix: do meta'), findsOneWidget);
      expect(find.text('Review PR-6'), findsOneWidget);
    });

    testWidgets('no reviews, no section', (tester) async {
      await _open(tester, MockGitHubRepository(pullRequests: [_pr(number: 12)]), docs: MockDocsRepository.empty());

      expect(find.byKey(const ValueKey('prs-reviews')), findsNothing);
      expect(find.byKey(const ValueKey('prs-reviews-error')), findsNothing);
    });

    testWidgets('the 60 s timer reloads without rereading unchanged reports', (tester) async {
      final docs = MockDocsRepository();
      final github = MockGitHubRepository(pullRequests: [_pr(number: 12)]);
      await _open(tester, github, docs: docs);
      expect(docs.reads['reviews/PR-157.md'], 1);
      expect(github.prsCalls, hasLength(1));

      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(github.prsCalls, hasLength(2));
      expect(docs.reads['reviews/PR-157.md'], 1);
      expect(docs.reads['reviews/PR-9.meta.json'], 1);
    });

    testWidgets('a changed report is reread; a report above the limit reads as revisão', (tester) async {
      final docs = MockDocsRepository();
      await _open(tester, MockGitHubRepository(pullRequests: [_pr(number: 12)]), docs: docs);

      docs.write('reviews/PR-157.md', 'x' * (kDocSizeLimit + 1));
      await tester.tap(find.text('Recarregar'));
      await tester.pumpAndSettle();
      expect(docs.reads['reviews/PR-157.md'], 2);
      expect(find.text('revisão'), findsOneWidget);
      expect(find.text('feat: cache de partidas'), findsOneWidget);
    });
  });

  group('permission mode of the cwd org', () {
    Map<String, dynamic> config() => {
      ..._scopedConfig(),
      'permissionMode': 'default',
      'orgs': [
        {...(_scopedConfig()['orgs'] as List).first as Map<String, dynamic>, 'permissionMode': 'acceptEdits'},
      ],
    };

    testWidgets('Resolver in a checkout of the org passes the org mode', (tester) async {
      final sessions = MockSessionsRepository();
      await _open(
        tester,
        MockGitHubRepository(
          pullRequests: [_pr(repo: 'x', cwd: '/dev/org/x')],
        ),
        sessions: sessions,
        config: config(),
      );

      await tester.tap(_resolve(1));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$3, '/dev/org/x');
      expect(sessions.createCalls.single.$5, PermissionMode.acceptEdits);
    });

    testWidgets('Resolver in a cwd outside every org passes the global mode', (tester) async {
      final sessions = MockSessionsRepository();
      await _open(
        tester,
        MockGitHubRepository(pullRequests: [_pr()]),
        sessions: sessions,
        config: config(),
      );

      await tester.tap(_resolve(1));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$3, '/tmp/a');
      expect(sessions.createCalls.single.$5, PermissionMode.defaultMode);
    });
  });

  group('account of the project org', () {
    testWidgets('prs is called with the org account and Resolver passes it as githubAccount', (tester) async {
      final sessions = MockSessionsRepository();
      final github = MockGitHubRepository(pullRequests: [_pr()]);
      await _open(tester, github, sessions: sessions, config: _scopedConfig());

      expect(github.prsCalls, [('x', 'acct-a')]);

      await tester.tap(_resolve(1));
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single, ('x', '/pr-status', '/tmp/a', 'acct-a', PermissionMode.acceptEdits));
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
