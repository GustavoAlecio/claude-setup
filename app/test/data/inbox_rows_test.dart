import 'package:claude_flow/app/inbox_cubit.dart';
import 'package:claude_flow/data/attention.dart';
import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/orgs.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:flutter_test/flutter_test.dart';

ReportDoc _report({String summary = 'resumo do bloco', int questions = 0, String gate = 'plan'}) => ReportDoc(
  feature: 'x',
  startedAt: null,
  stages: [
    StageReport(
      stage: kGateOwner[gate]!,
      status: ReportStatus.running,
      gate: ReportGate(
        name: gate,
        status: GateStatus.open,
        summary: summary,
        questions: [for (var i = 0; i < questions; i++) GateQuestion(id: 'q$i', text: 'pergunta $i')],
      ),
    ),
  ],
);

Project _project(String name, {String? feature, ReportDoc? report, TaskRun? blocked}) => Project(
  name: name,
  cycle: Cycle(
    stage: Stage.plan,
    feature: feature,
    stageMinutes: const {},
    report: report,
    reportIsCurrent: report != null,
    runs: [
      if (blocked != null)
        Run(id: 'r1', kind: 'implement', status: Verdict.blocked, startedAt: '2026-01-01T00:00:00Z', tasks: [blocked]),
    ],
  ),
);

TaskRun _task({Verdict status = Verdict.blocked}) => TaskRun(
  id: 'T2',
  title: 'Regra pura',
  complexity: Complexity.m,
  tier0: Tier.sonnet,
  status: status,
  diagnosis: const [],
);

AttentionItem _gate(String project, {String gate = 'plan', String body = 'corpo'}) => AttentionItem(
  key: 'k-gate',
  title: 'título ignorado',
  body: body,
  route: '/p/$project/gate/$gate',
  kind: AttentionKind.gate,
  project: project,
  sessionId: 's1',
  pending: 1,
  gate: gate,
);

AttentionItem _request({String? project, int pending = 1}) => AttentionItem(
  key: 'k-req',
  title: 'título ignorado',
  body: 'corpo do pedido',
  route: project == null ? '/o/acme/sessions/s2' : '/p/$project/sessions/s2',
  kind: AttentionKind.request,
  project: project,
  sessionId: 's2',
  pending: pending,
);

AttentionItem _blocked(String project) => AttentionItem(
  key: 'k-blocked',
  title: 'título ignorado',
  body: 'corpo ignorado',
  route: '/p/$project/runs/r1/T2',
  kind: AttentionKind.blocked,
  project: project,
);

void main() {
  group('featureLabel', () {
    test('joins with a dot, or keeps only where for a null or empty feature', () {
      expect(featureLabel('alpha', 'login'), 'alpha · login');
      expect(featureLabel('alpha', null), 'alpha');
      expect(featureLabel('alpha', ''), 'alpha');
    });
  });

  group('blockedTaskText', () {
    test('names the task, its title and the decision', () {
      expect(blockedTaskText(_task()), (
        title: 'A task T2 travou',
        detail: 'Regra pura: o diagnóstico espera a sua decisão',
        action: 'Decidir',
      ));
    });
  });

  group('inboxRows', () {
    test('gate row: feature, gateTitle with the block questions and the trimmed summary', () {
      final projects = [
        _project(
          'alpha',
          feature: 'login',
          report: _report(summary: '  resumo  ', questions: 2),
        ),
      ];
      expect(inboxRows('acme', [_gate('alpha')], const [], projects), [
        (
          context: 'alpha · login',
          title: '2 decisões antes de gerar as tasks',
          detail: 'resumo',
          action: 'Decidir',
          route: '/p/alpha/gate/plan',
        ),
      ]);
    });

    test('gate row with an empty summary says nothing runs before the answer', () {
      final projects = [
        _project(
          'alpha',
          feature: 'login',
          report: _report(summary: '   '),
        ),
      ];
      expect(inboxRows('acme', [_gate('alpha', body: 'corpo')], const [], projects), [
        (
          context: 'alpha · login',
          title: 'Aprovar o plano?',
          detail: 'Nada roda antes da sua resposta.',
          action: 'Decidir',
          route: '/p/alpha/gate/plan',
        ),
      ]);
    });

    test('orphan gate (no session) keeps the item body even with an empty summary', () {
      final projects = [_project('alpha', report: _report(summary: ''))];
      const orphan = AttentionItem(
        key: 'k-orphan',
        title: 't',
        body: 'A conversa deste gate não está aberta no app.',
        route: '/p/alpha/gate/plan',
        kind: AttentionKind.gate,
        project: 'alpha',
        gate: 'plan',
      );
      expect(
        inboxRows('acme', [orphan], const [], projects).single.detail,
        'A conversa deste gate não está aberta no app.',
      );
    });

    test('gate row picks the block named by item.gate and drops the feature when there is none', () {
      final projects = [
        _project(
          'alpha',
          report: _report(gate: 'spec', questions: 1, summary: 'da spec'),
        ),
      ];
      expect(inboxRows('acme', [_gate('alpha', gate: 'spec')], const [], projects), [
        (
          context: 'alpha',
          title: '1 decisão antes de planejar',
          detail: 'da spec',
          action: 'Decidir',
          route: '/p/alpha/gate/spec',
        ),
      ]);
    });

    test('gate row of a project missing from projects keeps only the project name', () {
      expect(inboxRows('acme', [_gate('ghost')], const [], const []), [
        (context: 'ghost', title: 'Aprovar o plano?', detail: 'corpo', action: 'Decidir', route: '/p/ghost/gate/plan'),
      ]);
    });

    test('request in a project: singular and plural, feature or conversa', () {
      final projects = [_project('alpha', feature: 'login'), _project('beta')];
      expect(
        inboxRows(
          'acme',
          [_request(project: 'alpha'), _request(project: 'alpha', pending: 3), _request(project: 'beta')],
          const [],
          projects,
        ),
        [
          (
            context: 'alpha · login',
            title: '1 pedido esperando resposta',
            detail: 'corpo do pedido',
            action: 'Responder',
            route: '/p/alpha/sessions/s2',
          ),
          (
            context: 'alpha · login',
            title: '3 pedidos esperando resposta',
            detail: 'corpo do pedido',
            action: 'Responder',
            route: '/p/alpha/sessions/s2',
          ),
          (
            context: 'beta · conversa',
            title: '1 pedido esperando resposta',
            detail: 'corpo do pedido',
            action: 'Responder',
            route: '/p/beta/sessions/s2',
          ),
        ],
      );
    });

    test('request in an org session uses the org parameter', () {
      expect(inboxRows('acme', [_request(pending: 2)], const [], const []), [
        (
          context: 'acme · conversa',
          title: '2 pedidos esperando resposta',
          detail: 'corpo do pedido',
          action: 'Responder',
          route: '/o/acme/sessions/s2',
        ),
      ]);
    });

    test('blocked row names the task and its decision', () {
      final projects = [_project('alpha', feature: 'login', blocked: _task())];
      expect(inboxRows('acme', [_blocked('alpha')], const [], projects), [
        (
          context: 'alpha · login',
          title: 'A task T2 travou',
          detail: 'Regra pura: o diagnóstico espera a sua decisão',
          action: 'Decidir',
          route: '/p/alpha/runs/r1/T2',
        ),
      ]);
    });

    test('blocked without a decision and finished items produce no row', () {
      final projects = [
        _project(
          'alpha',
          feature: 'login',
          blocked: _task(status: Verdict.pass),
        ),
      ];
      const finished = AttentionItem(
        key: 'k',
        title: 't',
        body: 'b',
        route: '/p/alpha/sessions/s3',
        kind: AttentionKind.finished,
        project: 'alpha',
        sessionId: 's3',
      );
      expect(inboxRows('acme', [_blocked('alpha'), _blocked('ghost'), finished], const [], projects), isEmpty);
    });

    test('PR rows come after the items, in the order received, with number and title fallbacks', () {
      final projects = [_project('alpha', feature: 'login')];
      expect(
        inboxRows(
          'acme',
          [_request(project: 'alpha')],
          [('beta', const PullRequest(number: 7, title: 'Corrige X')), ('alpha', const PullRequest())],
          projects,
        ),
        [
          (
            context: 'alpha · login',
            title: '1 pedido esperando resposta',
            detail: 'corpo do pedido',
            action: 'Responder',
            route: '/p/alpha/sessions/s2',
          ),
          (
            context: 'beta · PR #7',
            title: 'Comentários de revisão esperando resposta',
            detail: 'Corrige X',
            action: 'Resolver',
            route: '/p/beta/prs',
          ),
          (
            context: 'alpha · PR #?',
            title: 'Comentários de revisão esperando resposta',
            detail: '—',
            action: 'Resolver',
            route: '/p/alpha/prs',
          ),
        ],
      );
    });
  });

  group('InboxState.itemsFor', () {
    const mine = GithubScope(account: 'me', owners: ['acme']);
    const other = GithubScope(account: 'you');
    const items = [InboxItem(number: 1), InboxItem(number: 2)];

    test('same scope returns the loaded items', () {
      expect(
        const InboxState(
          scope: mine,
          inbox: Inbox(items: items),
        ).itemsFor(const GithubScope(account: 'me', owners: ['acme'])),
        items,
      );
    });

    test('another scope returns an empty list', () {
      expect(
        const InboxState(
          scope: mine,
          inbox: Inbox(items: items),
        ).itemsFor(other),
        isEmpty,
      );
    });

    test('a null inbox returns an empty list', () {
      expect(const InboxState(scope: mine).itemsFor(mine), isEmpty);
    });

    test('an error keeps the last list', () {
      expect(
        const InboxState(
          scope: mine,
          inbox: Inbox(items: items),
          error: 'falhou',
        ).itemsFor(mine),
        items,
      );
    });
  });
}
