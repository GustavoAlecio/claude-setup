import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Project names stay out of the [MockSessionsRepository] seed, so the seed sessions fall in "Sem org".
const _root = '/dev/acme';
const _fila = '/o/demo/fila';

/// The tab's former label, split so the repo-wide grep for it stays empty.
const _oldQueueLabel =
    'Minha '
    'fila';

TaskRun _blockedTask() =>
    const TaskRun(id: 'T2', title: 'Regra pura', complexity: Complexity.m, tier0: Tier.sonnet, status: Verdict.blocked);

/// `loja`: plan gate open on session `s-gate` and a cycle stopped on T2 of run `r1`.
Project _loja() => Project(
  name: 'loja',
  path: '$_root/loja',
  cycle: Cycle(
    stage: Stage.implement,
    feature: 'Carrinho',
    stageMinutes: const {},
    reportIsCurrent: true,
    report: const ReportDoc(
      feature: 'Carrinho',
      startedAt: null,
      stages: [
        StageReport(
          stage: Stage.plan,
          status: ReportStatus.running,
          sessionId: 's-gate',
          gate: ReportGate(name: 'plan', status: GateStatus.open, summary: 'Duas telas e um endpoint novo'),
        ),
      ],
    ),
    runs: [
      Run(
        id: 'r1',
        kind: 'implement',
        status: Verdict.blocked,
        startedAt: '2026-01-01T00:00:00Z',
        tasks: [_blockedTask()],
      ),
    ],
  ),
);

Project _cycleProject(String name, {String? feature, Stage stage = Stage.implement}) => Project(
  name: name,
  path: '$_root/$name',
  cycle: Cycle(stage: stage, feature: feature, stageMinutes: const {}, runs: const []),
);

SessionSummary _summary(String id, String project, {SessionStatus status = SessionStatus.waitingPermission}) =>
    SessionSummary(
      id: id,
      project: project,
      command: 'c',
      title: 'título $id',
      status: status,
      createdAt: '2026-10-07T10:00:00Z',
    );

List<Map<String, Object?>> _waiting(String id, int n) => [
  for (var i = 0; i < n; i++)
    {
      'kind': 'permission',
      'requestId': '$id-$i',
      'toolName': 'Bash',
      'input': {'command': 'ls'},
    },
];

const _commented = PullRequest(
  number: 9,
  title: 'Ajusta frete',
  stage: 'changes_requested',
  unresolved: [ReviewThread(path: 'a.dart', line: 1, author: 'rev', body: 'x')],
);

InboxItem _review(int number, {String repo = 'a', String owner = 'acme'}) => InboxItem(
  number: number,
  title: 'Revisão $number',
  repo: repo,
  nameWithOwner: '$owner/$repo',
  author: 'dev',
  updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
);

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

Future<void> _open(
  WidgetTester tester, {
  required List<Project> projects,
  MockSessionsRepository? sessions,
  GitHubRepository? github,
  Map<String, dynamic>? config,
  String location = _fila,
}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: projects, config: config),
      sessions: sessions ?? MockSessionsRepository(),
      engine: const MockEngineController(),
      github: github ?? MockGitHubRepository.empty(),
    ),
  );
  await tester.pumpAndSettle();
  _router(tester).go(location);
  await tester.pumpAndSettle();
}

/// Sessions with a pending request on `loja`'s open plan gate.
MockSessionsRepository _gateSessions() =>
    MockSessionsRepository()
      ..addSession(_summary('s-gate', 'loja'), _waiting('s-gate', 1), status: 'waiting_permission');

Finder _key(String key) => find.byKey(ValueKey(key));

Finder _in(String key, Finder f) => find.descendant(of: _key(key), matching: f);

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  group('Caixa de entrada', () {
    Future<void> openThree(WidgetTester tester) => _open(
      tester,
      projects: [_loja()],
      sessions: _gateSessions(),
      github: MockGitHubRepository(pullRequests: [_commented]),
    );

    testWidgets('gate, blocked cycle and PR with comments: three rows in order, one action each', (tester) async {
      await openThree(tester);

      const expected = [
        ['loja · Carrinho', 'Aprovar o plano?', 'Duas telas e um endpoint novo', 'Decidir'],
        ['loja · Carrinho', 'A task T2 travou', 'Regra pura: o diagnóstico espera a sua decisão', 'Decidir'],
        ['loja · PR #9', 'Comentários de revisão esperando resposta', 'Ajusta frete', 'Resolver'],
      ];
      for (final (i, texts) in expected.indexed) {
        for (final text in texts) {
          expect(_in('inbox-row-$i', find.text(text)), findsOneWidget, reason: 'row $i: $text');
        }
      }
      expect(_key('inbox-row-3'), findsNothing);
      expect(tester.widget(_key('inbox-row-0-action')), isA<FilledButton>());
      expect(tester.widget(_key('inbox-row-1-action')), isA<OutlinedButton>());
      expect(tester.widget(_key('inbox-row-2-action')), isA<OutlinedButton>());
      expect(_in('inbox-waiting', find.text('3')), findsOneWidget);
      expect(_key('inbox-empty'), findsNothing);
    });

    testWidgets('the gate button, the blocked row and the PR row lead where each is resolved', (tester) async {
      await openThree(tester);
      await tester.tap(_key('inbox-row-0-action'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/loja/gate/plan');

      _router(tester).go(_fila);
      await tester.pumpAndSettle();
      await tester.tap(_in('inbox-row-1', find.text('A task T2 travou')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/loja/runs/r1/T2');

      _router(tester).go(_fila);
      await tester.pumpAndSettle();
      await tester.tap(_in('inbox-row-2', find.text('Ajusta frete')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/loja/prs');
    });

    testWidgets('nothing pending shows the empty line and no row', (tester) async {
      await _open(tester, projects: [_cycleProject('feira', feature: 'Banca')]);

      expect(_in('inbox-empty', find.text('Nada precisa de você agora.')), findsOneWidget);
      expect(_key('inbox-row-0'), findsNothing);
      expect(_in('inbox-waiting', find.text('0')), findsOneWidget);
    });

    group('Para revisar', () {
      Future<void> openWith(WidgetTester tester, MockGitHubRepository github) =>
          _open(tester, projects: [_cycleProject('feira')], github: github);

      testWidgets('seven PRs show five rows and "ver os 7", which opens the review tab', (tester) async {
        await openWith(
          tester,
          MockGitHubRepository(inboxData: Inbox(items: [for (var i = 1; i <= 7; i++) _review(i)])),
        );

        expect(_key('inbox-home-review'), findsOneWidget);
        for (var i = 0; i < 5; i++) {
          expect(_key('inbox-home-review-$i'), findsOneWidget);
        }
        expect(_key('inbox-home-review-5'), findsNothing);
        expect(_in('inbox-home-review-0', find.text('#1')), findsOneWidget);
        expect(_in('inbox-home-review-0', find.text('Revisão 1')), findsOneWidget);
        expect(_in('inbox-home-review-0', find.text('a · há 2 h')), findsOneWidget);
        expect(_in('inbox-home-review-more', find.text('ver os 7')), findsOneWidget);

        await tester.tap(_key('inbox-home-review-more'));
        await tester.pumpAndSettle();
        expect(_location(tester), '/o/demo/revisar');
      });

      testWidgets('a row opens the review tab; two PRs show two rows and no "ver os"', (tester) async {
        await openWith(tester, MockGitHubRepository(inboxData: Inbox(items: [_review(1), _review(2)])));

        expect(_key('inbox-home-review-1'), findsOneWidget);
        expect(_key('inbox-home-review-more'), findsNothing);

        await tester.tap(_key('inbox-home-review-1'));
        await tester.pumpAndSettle();
        expect(_location(tester), '/o/demo/revisar');
      });

      testWidgets('no PR, or no list loaded, means no section', (tester) async {
        await openWith(tester, MockGitHubRepository());
        expect(_key('inbox-home-review'), findsNothing);

        await openWith(tester, MockGitHubRepository()..inboxError = const GitHubException('sem gh'));
        expect(_key('inbox-home-review'), findsNothing);
      });

      testWidgets('two PRs with the same number in different repos render', (tester) async {
        await openWith(
          tester,
          MockGitHubRepository(
            inboxData: Inbox(
              items: [
                _review(4, repo: 'a'),
                _review(4, repo: 'b'),
              ],
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(_key('inbox-home-review-0'), findsOneWidget);
        expect(_key('inbox-home-review-1'), findsOneWidget);
      });
    });

    group('rodapé', () {
      MockSessionsRepository running() => MockSessionsRepository()
        ..addSession(_summary('r1', 'feira', status: SessionStatus.running), const [], status: 'running')
        ..addSession(_summary('r2', 'feira', status: SessionStatus.running), const [], status: 'running');

      final projects = [
        _cycleProject('feira', feature: 'Banca'),
        _cycleProject('horta'),
        _cycleProject('pomar', feature: 'Colheita', stage: Stage.plan),
        _cycleProject('banca', feature: 'Vitrine', stage: Stage.complete),
      ];

      testWidgets('counts with their plurals; running opens the org sessions', (tester) async {
        await _open(tester, projects: projects, sessions: running());

        expect(_in('inbox-home-footer-running', find.text('2 agentes rodando')), findsOneWidget);
        expect(_in('inbox-home-footer-cycles', find.text('3 ciclos em andamento')), findsOneWidget);
        expect(_in('inbox-home-footer-done', find.text('1 pronto para PR')), findsOneWidget);

        await tester.tap(_key('inbox-home-footer-running'));
        await tester.pumpAndSettle();
        expect(_location(tester), '/o/demo/sessions');
      });

      testWidgets('cycles open a menu per project; without a feature only the name', (tester) async {
        await _open(tester, projects: projects, sessions: running());

        await tester.tap(_key('inbox-home-footer-cycles'));
        await tester.pumpAndSettle();
        expect(_in('inbox-home-footer-cycles-feira', find.text('feira · Banca')), findsOneWidget);
        expect(_in('inbox-home-footer-cycles-horta', find.text('horta')), findsOneWidget);
        expect(_in('inbox-home-footer-cycles-pomar', find.text('pomar · Colheita')), findsOneWidget);

        await tester.tap(_key('inbox-home-footer-cycles-horta'));
        await tester.pumpAndSettle();
        expect(_location(tester), '/p/horta/flow');
      });

      testWidgets('done opens the same menu, even with one project', (tester) async {
        await _open(tester, projects: projects, sessions: running());

        await tester.tap(_key('inbox-home-footer-done'));
        await tester.pumpAndSettle();
        expect(_in('inbox-home-footer-done-banca', find.text('banca · Vitrine')), findsOneWidget);

        await tester.tap(_key('inbox-home-footer-done-banca'));
        await tester.pumpAndSettle();
        expect(_location(tester), '/p/banca/flow');
      });

      testWidgets('one of each reads in the singular', (tester) async {
        await _open(
          tester,
          projects: [
            _cycleProject('feira'),
            _cycleProject('banca', stage: Stage.complete),
          ],
          sessions: MockSessionsRepository()
            ..addSession(_summary('r1', 'feira', status: SessionStatus.running), const [], status: 'running'),
        );

        expect(find.text('1 agente rodando'), findsOneWidget);
        expect(find.text('1 ciclo em andamento'), findsOneWidget);
        expect(find.text('1 pronto para PR'), findsOneWidget);
      });

      testWidgets('all at zero: no footer', (tester) async {
        await _open(
          tester,
          projects: const [Project(name: 'feira', path: '$_root/feira')],
        );
        expect(_key('inbox-home-footer'), findsNothing);
      });
    });

    testWidgets('1100x700 with three rows, five reviews and the whole footer renders', (tester) async {
      final view = tester.view;
      view.physicalSize = const Size(1100, 700);
      view.devicePixelRatio = 1;
      addTearDown(view.reset);
      final sessions = _gateSessions()
        ..addSession(_summary('s-req', 'loja'), _waiting('s-req', 2), status: 'waiting_permission')
        ..addSession(_summary('r1', 'feira', status: SessionStatus.running), const [], status: 'running');

      await _open(
        tester,
        projects: [
          _loja(),
          _cycleProject('feira', feature: 'Uma feature com um nome comprido o bastante para não caber numa linha'),
          _cycleProject('banca', stage: Stage.complete),
        ],
        sessions: sessions,
        github: MockGitHubRepository(inboxData: Inbox(items: [for (var i = 1; i <= 5; i++) _review(i)])),
      );

      expect(tester.takeException(), isNull);
      expect(_key('inbox-row-2'), findsOneWidget);
      expect(_key('inbox-home-review-4'), findsOneWidget);
      await tester.scrollUntilVisible(
        _key('inbox-home-footer'),
        200,
        scrollable: find.ancestor(of: _key('inbox-waiting'), matching: find.byType(Scrollable)).first,
      );
      expect(_key('inbox-home-footer-running'), findsOneWidget);
      expect(_key('inbox-home-footer-cycles'), findsOneWidget);
      expect(_key('inbox-home-footer-done'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    group('cabeçalho', () {
      ButtonStyleButton resolve(WidgetTester tester) => tester.widget<ButtonStyleButton>(_key('inbox-resolve'));

      const twoOrgs = {
        'orgs': [
          {
            'name': 'A',
            'roots': ['/dev/a'],
          },
          {
            'name': 'B',
            'roots': ['/dev/b'],
          },
        ],
        'lastOrg': 'A',
      };
      const abProjects = [
        Project(name: 'x', path: '/dev/a/x'),
        Project(name: 'x2', path: '/dev/a/x2'),
        Project(name: 'y', path: '/dev/b/y'),
      ];

      testWidgets('on fila the title and the first tab read Caixa de entrada; on sessions nothing changes', (
        tester,
      ) async {
        await _open(tester, projects: [_cycleProject('feira')]);

        expect(tester.widget<Text>(_key('org-title')).data, 'Caixa de entrada');
        expect(_in('org-tab-queue', find.text('Caixa de entrada')), findsOneWidget);
        expect(_in('inbox-resolve', find.text('Resolver uma por vez  ⌘J')), findsOneWidget);
        expect(find.text(_oldQueueLabel), findsNothing);

        for (final route in ['/o/demo/revisar', '/o/demo/sessions']) {
          _router(tester).go(route);
          await tester.pumpAndSettle();
          expect(find.text(_oldQueueLabel), findsNothing, reason: route);
          expect(_in('org-tab-queue', find.text('Caixa de entrada')), findsOneWidget, reason: route);
        }
        expect(tester.widget<Text>(_key('org-title')).data, 'Atividades em demo');
        expect(_key('inbox-resolve'), findsNothing);
      });

      testWidgets('nothing pending: inbox-resolve is disabled', (tester) async {
        await _open(tester, projects: [_cycleProject('feira')]);
        expect(resolve(tester).onPressed, isNull);
      });

      testWidgets('inbox-resolve walks only the org on screen, starting at the first row', (tester) async {
        await _open(
          tester,
          projects: abProjects,
          config: twoOrgs,
          location: '/o/A/fila',
          sessions: MockSessionsRepository()
            ..addSession(_summary('s-a1', 'x'), _waiting('s-a1', 1), status: 'waiting_permission')
            ..addSession(_summary('s-a2', 'x2'), _waiting('s-a2', 1), status: 'waiting_permission')
            ..addSession(_summary('s-b', 'y'), _waiting('s-b', 1), status: 'waiting_permission'),
        );
        expect(_key('inbox-row-1'), findsOneWidget);
        expect(_key('inbox-row-2'), findsNothing);

        await tester.tap(_key('inbox-row-0-action'));
        await tester.pumpAndSettle();
        final first = _location(tester);
        expect(first, isNot('/o/A/fila'));

        _router(tester).go('/o/A/fila');
        await tester.pumpAndSettle();
        expect(resolve(tester).onPressed, isNotNull);
        await tester.tap(_key('inbox-resolve'));
        await tester.pumpAndSettle();
        expect(_location(tester), first);
      });

      testWidgets('pending only in the other org: inbox-resolve is disabled', (tester) async {
        await _open(
          tester,
          projects: abProjects,
          config: twoOrgs,
          location: '/o/A/fila',
          sessions: MockSessionsRepository()
            ..addSession(_summary('s-b', 'y'), _waiting('s-b', 1), status: 'waiting_permission'),
        );
        expect(_key('inbox-row-0'), findsNothing);
        expect(resolve(tester).onPressed, isNull);
      });
    });

    testWidgets('switching org never shows the previous org PRs, not even before the new fetch returns', (
      tester,
    ) async {
      final github = _PrsByProject({
        'x': Future.value([_commented]),
      });
      await _open(
        tester,
        projects: const [
          Project(name: 'x', path: '/dev/a/x'),
          Project(name: 'y', path: '/dev/b/y'),
        ],
        github: github,
        config: {
          'orgs': [
            {
              'name': 'A',
              'roots': ['/dev/a'],
            },
            {
              'name': 'B',
              'roots': ['/dev/b'],
            },
          ],
          'lastOrg': 'A',
        },
        location: '/o/A/fila',
      );
      expect(_in('inbox-row-0', find.text('x · PR #9')), findsOneWidget);

      final pending = Completer<List<PullRequest>>();
      github.answers['y'] = pending.future;
      _router(tester).go('/o/B/fila');
      await tester.pump();
      await tester.pump();
      expect(find.text('x · PR #9'), findsNothing);
      expect(_key('inbox-empty'), findsOneWidget);

      pending.complete(const []);
      await tester.pumpAndSettle();
      expect(find.text('x · PR #9'), findsNothing);
      expect(_key('inbox-empty'), findsOneWidget);
      expect(github.prsCalls.map((c) => c.$1), containsAll(['x', 'y']));
    });
  });
}

/// PRs answered per project, so each org sees only its own.
class _PrsByProject extends MockGitHubRepository {
  _PrsByProject(this.answers);

  final Map<String, Future<List<PullRequest>>> answers;

  @override
  Future<List<PullRequest>> prs(String project, {String? account}) {
    prsCalls.add((project, account));
    return answers[project] ?? Future.value(const []);
  }
}
