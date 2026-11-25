import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/attention.dart';
import 'package:claude_flow/data/file_flow_repository.dart';
import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/session_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _session(
  String id, {
  String project = 'gamma',
  String? org,
  int pending = 1,
  SessionStatus status = SessionStatus.waitingPermission,
}) => SessionSummary(
  id: id,
  project: project,
  org: org,
  command: 'c',
  title: 'título $id',
  status: status,
  createdAt: '',
  pendingPermissions: pending,
);

/// The gamma fixture with its open `plan` gate run by `s-plan`.
Project _gammaWithPlanGate() {
  final doc = jsonDecode(File('test/fixtures/workflow/gamma/report.json').readAsStringSync()) as Map<String, dynamic>;
  final plan = (doc['stages'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['stage'] == 'plan');
  plan['session_id'] = 's-plan';
  return Project(
    name: 'gamma',
    cycle: Cycle(
      stage: Stage.plan,
      runs: const [],
      stageMinutes: const {},
      report: parseReport(jsonEncode(doc)),
      reportIsCurrent: true,
    ),
  );
}

const _orphanBody = 'A conversa deste gate não está aberta no app.';

StageReport _gateStage(String gate, {String? session, int round = 1, GateStatus status = GateStatus.open}) =>
    StageReport(
      stage: kGateOwner[gate]!,
      status: ReportStatus.running,
      sessionId: session,
      gate: ReportGate(name: gate, status: status, round: round),
    );

Project _gated(
  String name,
  List<StageReport> stages, {
  bool hidden = false,
  bool paused = false,
  bool current = true,
  List<Run> runs = const [],
}) => Project(
  name: name,
  hidden: hidden,
  cycle: Cycle(
    stage: Stage.plan,
    runs: runs,
    stageMinutes: const {},
    pausedAt: paused ? DateTime.utc(2026) : null,
    report: ReportDoc(feature: 'f', startedAt: null, stages: stages),
    reportIsCurrent: current,
  ),
);

const _blockedRun = Run(
  id: 'r1',
  kind: 'implement',
  status: Verdict.blocked,
  startedAt: '2026-01-01T00:00:00Z',
  tasks: [TaskRun(id: 'T2', title: 'Regra', complexity: Complexity.m, tier0: Tier.sonnet, status: Verdict.blocked)],
);

void main() {
  group('pendingAttention', () {
    test('a session on an open gate is a gate item with the gate route', () {
      final items = pendingAttention([_session('s-plan', pending: 2)], [_gammaWithPlanGate()]);
      // The fixture's spec gate has no session: it follows as a gate without a conversation.
      expect(items.map((i) => i.key), ['pending:s-plan:2', 'gate:gamma:spec:1']);
      final item = items.first;
      expect(item.kind, AttentionKind.gate);
      expect(item.gate, 'plan');
      expect(item.project, 'gamma');
      expect(item.sessionId, 's-plan');
      expect(item.pending, 2);
      expect(item.key, 'pending:s-plan:2');
      expect(item.title, 'Aguardando você · gamma');
      expect(item.body, 'título s-plan');
      expect(item.route, '/p/gamma/gate/plan');
    });

    test('a request outside a gate is a request item with the session route', () {
      final items = pendingAttention([_session('s-other', pending: 3)], [_gammaWithPlanGate()]);
      // Neither gate has its conversation in the list: both follow the request.
      expect(items.map((i) => i.key), ['pending:s-other:3', 'gate:gamma:spec:1', 'gate:gamma:plan:1']);
      final item = items.first;
      expect(item.kind, AttentionKind.request);
      expect(item.gate, isNull);
      expect(item.project, 'gamma');
      expect(item.sessionId, 's-other');
      expect(item.pending, 3);
      expect(item.key, 'pending:s-other:3');
      expect(item.title, 'Aguardando você · gamma');
      expect(item.body, 'título s-other');
      expect(item.route, '/p/gamma/sessions/s-other');
    });

    test('an org session has no project', () {
      final item = pendingAttention([_session('s-org', project: '', org: 'acme')], const []).single;
      expect(item.kind, AttentionKind.request);
      expect(item.project, isNull);
      expect(item.sessionId, 's-org');
      expect(item.pending, 1);
      expect(item.gate, isNull);
      expect(item.key, 'pending:s-org:1');
      expect(item.title, 'Aguardando você · acme');
      expect(item.route, '/o/acme/sessions/s-org');
    });

    test('a blocked decision is a blocked item without session', () {
      final item = pendingAttention(const [], MockFlowRepository().projects).single;
      expect(item.kind, AttentionKind.blocked);
      expect(item.project, 'demo-app');
      expect(item.sessionId, isNull);
      expect(item.pending, 0);
      expect(item.gate, isNull);
      expect(item.key, 'blocked:demo-app:impl-20261001T141210Z:T4');
      expect(item.title, 'Ciclo parado · demo-app');
      expect(item.body, 'T4 · Sincronização offline com fila de mutações: o diagnóstico espera a sua decisão');
      expect(item.route, '/p/demo-app/runs/impl-20261001T141210Z/T4');
    });
  });

  group('orphanGates', () {
    test('an open plan gate without a session is one gate item without session', () {
      final projects = [
        _gated('loja', [_gateStage('plan', round: 3)]),
      ];
      final orphan = orphanGates(const [], projects).single;
      expect(orphan.project.name, 'loja');
      expect(orphan.stage.gate!.name, 'plan');

      final item = pendingAttention(const [], projects).single;
      expect(item.kind, AttentionKind.gate);
      expect(item.isOrphanGate, isTrue);
      expect(item.sessionId, isNull);
      expect(item.pending, 0);
      expect(item.project, 'loja');
      expect(item.gate, 'plan');
      expect(item.key, 'gate:loja:plan:3');
      expect(item.title, 'Gate aberto · loja');
      expect(item.body, _orphanBody);
      expect(item.route, '/p/loja/gate/plan');
      expect(attentionCount(const [], projects), 1);
    });

    test('an owner session missing from the list or ended leaves the gate without a conversation', () {
      final projects = [
        _gated('loja', [_gateStage('plan', session: 's-plan')]),
      ];
      expect(orphanGates(const [], projects), hasLength(1));
      expect(orphanGates([_session('s-other', project: 'loja')], projects), hasLength(1));
      for (final status in SessionStatus.values) {
        final sessions = [_session('s-plan', project: 'loja', pending: 0, status: status)];
        final alive = isLive(status) || status == SessionStatus.starting;
        expect(orphanGates(sessions, projects), hasLength(alive ? 0 : 1), reason: '$status');
        expect(pendingAttention(sessions, projects).where((i) => i.isOrphanGate), hasLength(alive ? 0 : 1));
      }
    });

    test('a running owner without a request is working: nothing waits', () {
      final projects = [
        _gated('loja', [_gateStage('plan', session: 's-plan')]),
      ];
      final sessions = [_session('s-plan', project: 'loja', pending: 0, status: SessionStatus.running)];
      expect(orphanGates(sessions, projects), isEmpty);
      expect(pendingAttention(sessions, projects), isEmpty);
      expect(attentionCount(sessions, projects), 0);
    });

    test('an owner with a pending request yields only the session item', () {
      final projects = [
        _gated('loja', [_gateStage('plan', session: 's-plan')]),
      ];
      final sessions = [_session('s-plan', project: 'loja', pending: 2)];
      final item = pendingAttention(sessions, projects).single;
      expect(item.key, 'pending:s-plan:2');
      expect(item.isOrphanGate, isFalse);
      expect(item.route, '/p/loja/gate/plan');
    });

    test('a paused cycle, a hidden project, a closed gate and a report of another cycle ask for nothing', () {
      final open = [_gateStage('plan')];
      final projects = [
        _gated('pausado', open, paused: true),
        _gated('oculto', open, hidden: true),
        _gated('aprovado', [_gateStage('plan', status: GateStatus.approved)]),
        _gated('antigo', open, current: false),
        const Project(name: 'sem-ciclo'),
      ];
      expect(orphanGates(const [], projects), isEmpty);
      expect(pendingAttention(const [], projects), isEmpty);
      expect(attentionCount(const [], projects), 0);
      expect(withDecisions(const {}, projects, const []), isEmpty);
    });

    test('two open gates without a session are two items, in pipeline order, counted per gate', () {
      final projects = [
        _gated('loja', [_gateStage('plan'), _gateStage('spec', round: 2)]),
      ];
      final items = pendingAttention(const [], projects);
      expect(items.map((i) => i.key), ['gate:loja:spec:2', 'gate:loja:plan:1']);
      expect(items.map((i) => i.route), ['/p/loja/gate/spec', '/p/loja/gate/plan']);
      expect(attentionCount(const [], projects), 2);
      expect(withDecisions(const {'loja': 1, 'outro': 4}, projects, const []), {'loja': 3, 'outro': 4});
    });

    test('the order is sessions, gates without a conversation, blocked decisions', () {
      final projects = [
        _gated('a', [_gateStage('plan')], runs: const [_blockedRun]),
        _gated('b', [_gateStage('spec')]),
      ];
      final sessions = [_session('s-b', project: 'b')];
      final items = pendingAttention(sessions, projects);
      expect(items.map((i) => i.key), ['pending:s-b:1', 'gate:a:plan:1', 'gate:b:spec:1', 'blocked:a:r1:T2']);
      expect(attentionCount(sessions, projects), items.length);
      expect(withDecisions(pendingByProject(sessions), projects, sessions), {'a': 2, 'b': 2});
    });
  });

  group('contagens na fixture', () {
    const org = 'synthetic';
    late FileFlowRepository repo;

    setUp(() => repo = FileFlowRepository('test/fixtures/workflow', stacksDir: 'test/fixtures/stacks'));
    tearDown(() => repo.dispose());

    test('Dock, pontos dos projetos, contagem da org e linhas da Caixa contam o mesmo conjunto', () async {
      const sessions = <SessionSummary>[];
      final loaded = await repo.watchProjects().firstWhere((l) => l.isNotEmpty);
      final config = await repo.watchConfig().first;
      // The repository orders by the mtime of each `current.json`, which a checkout does not fix: the order here is
      // the one the inbox criterion states (alpha, gamma, delta), with the rest after.
      const stated = ['alpha', 'gamma', 'delta'];
      final projects = [
        for (final name in stated) loaded.firstWhere((p) => p.name == name),
        for (final p in loaded)
          if (!stated.contains(p.name)) p,
      ];
      for (final name in stated) {
        final p = projects.firstWhere((p) => p.name == name);
        expect((p.hidden, p.org), (false, org), reason: name);
      }

      final items = pendingAttention(sessions, projects);
      final count = attentionCount(sessions, projects);
      expect(count, 5);
      expect(count, items.length);
      // A project of another org with something waiting would show only on the first two counts; the fixture has none.
      expect(withDecisions(pendingByProject(sessions), projects, sessions).values.fold(0, (a, b) => a + b), count);
      expect(decisionsInOrg(projects, org, sessions), count);
      expect(attentionCount(sessions, loaded), count);
      expect(decisionsInOrg(loaded, org, sessions), count);

      final waiting = orgQueue(org, sessions, projects, config).waiting;
      expect(waiting.map((i) => i.key), items.map((i) => i.key));
      final rows = inboxRows(org, waiting, const [], projects);
      expect(rows, hasLength(5));
      expect(rows[1].context, 'gamma · Tela gamma');
      expect(rows.map((r) => r.route), [
        '/p/alpha/gate/spec',
        '/p/gamma/gate/spec',
        '/p/gamma/gate/plan',
        '/p/delta/gate/pr',
        startsWith('/p/alpha/runs/'),
      ]);
      expect(rows.map((r) => r.action), everyElement('Decidir'));
    });
  });

  group('finishedTurns', () {
    test('a finished turn is a finished item with project and session', () {
      final now = [
        _session('s1', pending: 0, status: SessionStatus.idle),
        _session('s2', project: '', org: 'acme', pending: 0, status: SessionStatus.done),
      ];
      final items = finishedTurns({'s1': SessionStatus.running, 's2': SessionStatus.running}, now);
      expect(items.map((i) => i.kind), [AttentionKind.finished, AttentionKind.finished]);
      expect(items[0].project, 'gamma');
      expect(items[0].sessionId, 's1');
      expect(items[0].pending, 0);
      expect(items[0].gate, isNull);
      expect(items[0].key, startsWith('done:s1:'));
      expect(items[0].title, 'Turno concluído · gamma');
      expect(items[0].body, 'título s1');
      expect(items[0].route, '/p/gamma/sessions/s1');
      expect(items[1].project, isNull);
      expect(items[1].sessionId, 's2');
      expect(items[1].route, '/o/acme/sessions/s2');
    });
  });

  group('AttentionSnapshot.of', () {
    test('reads sessionId and pending, not the key', () {
      final snap = AttentionSnapshot.of(const [
        AttentionItem(
          key: 'opaque',
          title: '',
          body: '',
          route: '/',
          kind: AttentionKind.gate,
          sessionId: 'a:b',
          pending: 4,
          gate: 'plan',
        ),
        AttentionItem(key: 'k1', title: '', body: '', route: '/', kind: AttentionKind.blocked, project: 'p'),
        AttentionItem(
          key: 'pending:x:9',
          title: '',
          body: '',
          route: '/',
          kind: AttentionKind.finished,
          sessionId: 'x',
        ),
      ]);
      expect(snap.pending, {'a:b': 4});
      expect(snap.blocked, {'k1'});
    });

    test('a gate without a session does not throw and lands nowhere', () {
      final snap = AttentionSnapshot.of(const [
        AttentionItem(
          key: 'gate:p:plan:1',
          title: '',
          body: '',
          route: '/',
          kind: AttentionKind.gate,
          project: 'p',
          gate: 'plan',
        ),
      ]);
      expect(snap.pending, isEmpty);
      expect(snap.blocked, isEmpty);
    });
  });
}
