import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/orgs.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/workflow_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = 'test/fixtures/workflow';

String _fixture(String path) => File('$_fixtures/$path').readAsStringSync();

String _report(List<Object?> stages, {Object? version = 1, Object? cycle}) => jsonEncode({
  'version': version,
  'cycle': cycle ?? {'feature': 'F', 'started_at': '2026-03-10T08:00:00Z'},
  'stages': stages,
});

Map<String, Object?> _stage(String name, {String status = 'done', Map<String, Object?> extra = const {}}) => {
  'stage': name,
  'status': status,
  ...extra,
};

Run _fixtureRun(String project, String id) =>
    parseResultRun(id, jsonDecode(_fixture('$project/runs/$id/result.json')) as Map<String, dynamic>, const {});

TaskRun _task(
  String id, {
  Tier tier = Tier.sonnet,
  int attempts = 1,
  Tier? escalatedTo,
  Verdict status = Verdict.pass,
}) => TaskRun(
  id: id,
  title: id,
  complexity: Complexity.m,
  tier0: Tier.sonnet,
  status: status,
  attempts: [
    for (var i = 1; i <= attempts; i++)
      Attempt(number: i, ordinal: i, tier: tier, gates: const [], escalatedTo: i == 1 ? escalatedTo : null),
  ],
);

Run _run(String id, String kind, List<TaskRun> tasks, {Verdict status = Verdict.pass}) =>
    Run(id: id, kind: kind, status: status, startedAt: '', tasks: tasks);

SessionSummary _session(
  String id,
  String command, {
  String project = 'alpha',
  SessionStatus status = SessionStatus.running,
  String createdAt = '2026-03-10T10:00:00Z',
  String? org,
  int pending = 0,
}) => SessionSummary(
  id: id,
  project: project,
  command: command,
  title: command,
  status: status,
  createdAt: createdAt,
  org: org,
  pendingPermissions: pending,
);

void main() {
  group('parseReport', () {
    test('relatório completo do gen.sh', () {
      final doc = parseReport(_fixture('gamma/report.json'))!;

      expect(doc.feature, 'Tela gamma');
      expect(doc.startedAt, '2026-03-10T08:00:00Z');
      expect(doc.stages.map((s) => s.stage), [
        Stage.kickoff,
        Stage.specify,
        Stage.challenge,
        Stage.plan,
        Stage.tasks,
        Stage.implement,
        Stage.verify,
      ]);
      final challenge = doc.stage(Stage.challenge)!;
      expect(challenge.findings.single.source, 'spec-challenger');
      expect(challenge.findings.single.accepted.single.severity, 'major');
      expect(challenge.findings.single.rejected.single.reasonMd, 'Fora do escopo da fase.');
      expect(challenge.decisions.map((d) => d.by), ['challenger', 'user']);
      final plan = doc.stage(Stage.plan)!;
      expect(plan.decisions.first.alternativeMd, 'Um cubit por seção.');
      expect(plan.decisions.last.kind, DecisionKind.mistake);
      expect(plan.artifacts, ['plan.md']);
      final verify = doc.stage(Stage.verify)!;
      expect(verify.status, ReportStatus.running);
    });

    test('relatório parcial: só as etapas gravadas, com o status do arquivo', () {
      final doc = parseReport(_fixture('alpha/report.json'))!;

      expect(doc.stages.map((s) => s.stage), [Stage.kickoff, Stage.specify, Stage.challenge]);
      expect(doc.stage(Stage.challenge)!.status, ReportStatus.running);
      expect(doc.stage(Stage.plan), isNull);
    });

    test('relatório de projeto sem feature no current.json', () {
      final doc = parseReport(_fixture('legacy/report.json'))!;

      expect(doc.feature, isNull);
      expect(doc.stage(Stage.kickoff)!.status, ReportStatus.blocked);
    });

    test('inválido, vazio, raiz que não é objeto e versão 2 viram null', () {
      expect(parseReport(''), isNull);
      expect(parseReport('{"version": 1, "stages": ['), isNull);
      expect(parseReport('[]'), isNull);
      expect(parseReport('{"stages": []}'), isNull);
      expect(parseReport(_report([_stage('kickoff')], version: 2)), isNull);
      expect(parseReport(_report([_stage('kickoff')], version: '1')), isNull);
    });

    test('campos desconhecidos são ignorados e entradas malformadas descartadas', () {
      final doc = parseReport(
        jsonEncode({
          'version': 1,
          'future': {'x': 1},
          'cycle': 'quebrado',
          'stages': [
            _stage(
              'plan',
              extra: {
                'novo': true,
                'attempt': 'x',
                'artifacts': ['a.md', 3],
                'decisions': 'nada',
              },
            ),
            _stage('kickoff', status: 'estranho'),
            _stage('inexistente'),
            _stage('kickoff', extra: {'summary_md': 'duplicada'}),
            'texto',
            {'status': 'done'},
            _stage(
              'tasks',
              extra: {
                'decisions': [
                  {'by': 'user'},
                  {'id': 'x'},
                  {'text_md': 'sem id'},
                  {'id': 'd', 'text_md': 'ok', 'kind': 'qualquer'},
                  7,
                ],
                'findings': [
                  {
                    'accepted': 'x',
                    'rejected': [
                      {'id': 'r'},
                    ],
                  },
                ],
              },
            ),
          ],
        }),
      )!;

      expect(doc.feature, isNull);
      expect(doc.stages.map((s) => s.stage), [Stage.kickoff, Stage.plan, Stage.tasks]);
      final kickoff = doc.stage(Stage.kickoff)!;
      expect(kickoff.status, ReportStatus.running);
      expect(kickoff.summaryMd, '');
      final plan = doc.stage(Stage.plan)!;
      expect(plan.attempt, 1);
      expect(plan.artifacts, ['a.md']);
      expect(plan.decisions, isEmpty);
      final tasks = doc.stage(Stage.tasks)!;
      expect(tasks.decisions.single.textMd, 'ok');
      expect(tasks.decisions.single.by, 'orchestrator');
      expect(tasks.decisions.single.kind, DecisionKind.decision);
      expect(tasks.findings.single.accepted, isEmpty);
      expect(tasks.findings.single.rejected.single.id, 'r');
    });

    test('etapas saem na ordem do enum mesmo gravadas fora de ordem', () {
      final doc = parseReport(_report([_stage('verify'), _stage('kickoff'), _stage('plan')]))!;

      expect(doc.stages.map((s) => s.stage), [Stage.kickoff, Stage.plan, Stage.verify]);
    });

    test('nunca lança com tipos errados em cada campo', () {
      expect(
        () => parseReport(
          _report([
            _stage(
              'plan',
              extra: {
                'decisions': [
                  {'text_md': 1, 'by': 2},
                ],
                'findings': 5,
                'verify': 'x',
                'run_ids': 'x',
                'summary_md': 3,
              },
            ),
            _stage(
              'verify',
              extra: {
                'verify': {
                  'round': 'x',
                  'gates': [
                    1,
                    {'findings': 'y'},
                  ],
                },
              },
            ),
          ]),
        ),
        returnsNormally,
      );
    });
  });

  group('decisões', () {
    test('todas as etapas em ordem, e o filtro por autor', () {
      final doc = parseReport(_fixture('gamma/report.json'));

      final all = allDecisions(doc);
      expect(all.map((d) => d.stage), [
        Stage.specify,
        Stage.challenge,
        Stage.challenge,
        Stage.plan,
        Stage.plan,
        Stage.implement,
        Stage.implement,
      ]);
      expect(all.map((d) => d.decision.by), [
        'orchestrator',
        'challenger',
        'user',
        'orchestrator',
        'orchestrator',
        'agent:T1',
        'agent:T2',
      ]);
      expect(allDecisions(doc, by: 'orchestrator'), hasLength(3));
      expect(allDecisions(doc, by: 'agent:T2').single.stage, Stage.implement);
      expect(allDecisions(doc, by: 'ninguém'), isEmpty);
      expect(decisionAuthors(doc), ['orchestrator', 'challenger', 'user', 'agent:T1', 'agent:T2']);
    });

    test('sem relatório não há decisões', () {
      expect(allDecisions(null), isEmpty);
      expect(decisionAuthors(null), isEmpty);
    });
  });

  group('taskTable', () {
    test('plano em ordem; tentativas e escaladas somam os runs, tier final e status vêm do mais recente', () {
      final cycle = Cycle(
        stage: Stage.verify,
        autoMode: false,
        stageMinutes: const {},
        plan: [
          for (final id in ['T1', 'T2', 'T3'])
            TaskRun(
              id: id,
              title: 'Task $id',
              complexity: id == 'T2' ? Complexity.l : Complexity.s,
              risk: id == 'T2',
              tier0: Tier.haiku,
              status: Verdict.pending,
            ),
        ],
        runs: [
          _run('verify-20260310T113000Z', 'verify', [_task('T1', tier: Tier.opus, attempts: 2, status: Verdict.pass)]),
          _run('impl-20260310T101500Z', 'implement', [
            _task('T1', tier: Tier.sonnet, escalatedTo: Tier.opus, attempts: 2),
            _task('T2', tier: Tier.sonnet, status: Verdict.blocked),
          ]),
        ],
      );

      final rows = taskTable(cycle);

      expect(rows.map((r) => r.id), ['T1', 'T2', 'T3']);
      expect(rows[0].tier0, Tier.haiku);
      expect(rows[0].tierFinal, Tier.opus);
      expect(rows[0].attempts, 4);
      expect(rows[0].escalations, 1);
      expect(rows[0].status, Verdict.pass);
      expect(rows[1].complexity, Complexity.l);
      expect(rows[1].risk, isTrue);
      expect(rows[1].status, Verdict.blocked);
      expect(rows[2].attempts, 0);
      expect(rows[2].tierFinal, Tier.haiku);
      expect(rows[2].status, Verdict.pending);
    });

    test('sem plano usa as tasks dos runs de implement, sem as correções do verify', () {
      final cycle = Cycle(
        stage: Stage.verify,
        autoMode: false,
        stageMinutes: const {},
        runs: [
          _run('verify-20260310T113000Z', 'verify', [_task('V1')]),
          _run('impl-20260310T101500Z', 'implement', [_task('T1'), _task('T2')]),
        ],
      );

      expect(taskTable(cycle).map((r) => r.id), ['T1', 'T2']);
    });

    test('ciclo sem plano nem runs: tabela vazia', () {
      expect(taskTable(const Cycle(stage: Stage.kickoff, autoMode: false, stageMinutes: {}, runs: [])), isEmpty);
    });
  });

  group('verifySummary', () {
    test('rodadas do fixture do mais antigo ao mais novo, com veredito por gate e tasks de correção', () {
      final runs = [_fixtureRun('gamma', 'verify-20260310T113000Z'), _fixtureRun('gamma', 'verify-20260310T110000Z')];

      final summary = verifySummary(runs);

      expect(summary.map((r) => r.runId), ['verify-20260310T110000Z', 'verify-20260310T113000Z']);
      expect(summary.map((r) => r.round), [1, 2]);
      expect(summary[0].status, Verdict.inconclusive);
      expect(summary[0].reason, 'qa_inconclusive');
      expect(summary[0].gates.any((g) => g.gate == 'g2' && g.verdict == Verdict.inconclusive), isTrue);
      expect(summary[0].fixTasks, isEmpty);
      expect(summary[1].status, Verdict.pass);
      expect(summary[1].fixTasks.map((t) => t.id), ['V1']);
      expect(summary[1].blocking, isEmpty);
    });

    test('achados bloqueantes vêm só dos gates da última rodada, e runs de implement ficam de fora', () {
      final finding = const Finding(gate: 'g1', severity: 'major', file: 'lib/a.dart', ruleRef: 'r', message: 'm');
      final minor = const Finding(gate: 'g1', severity: 'minor', file: 'lib/b.dart', ruleRef: 'r', message: 'm');
      final run = Run(
        id: 'verify-20260310T113000Z',
        kind: 'verify',
        status: Verdict.blocked,
        startedAt: '',
        tasks: const [],
        round: 3,
        gates: [
          GateResult('g1', Verdict.fail, [finding, minor]),
        ],
      );

      final summary = verifySummary([run, _run('impl-20260310T101500Z', 'implement', const [])]);

      expect(summary, hasLength(1));
      expect(summary.single.round, 3);
      expect(summary.single.blocking, [finding]);
    });
  });

  group('classify', () {
    test('report.json e o arquivado caem no escopo do projeto; lock e tmp são ignorados', () {
      const root = '/w';

      expect(
        classify(root, '$root/alpha/report.json'),
        isA<ProjectScope>().having((s) => s.project, 'project', 'alpha'),
      );
      expect(
        classify(root, '$root/alpha/report.2026-03-10T08:00:00Z.json'),
        isA<ProjectScope>().having((s) => s.project, 'project', 'alpha'),
      );
      expect(
        classify(root, '$root/alpha/report.json.tmp', destination: '$root/alpha/report.json'),
        isA<ProjectScope>().having((s) => s.project, 'project', 'alpha'),
      );
      expect(classify(root, '$root/alpha/report.json.tmp'), isNull);
      expect(classify(root, '$root/alpha/.report.json.lock'), isNull);
    });
  });

  group('runningStageSession', () {
    const project = Project(name: 'alpha');

    test('sessão do projeto com comando de skill do pipeline e status vivo', () {
      for (final status in [SessionStatus.running, SessionStatus.idle, SessionStatus.waitingPermission]) {
        expect(runningStageSession([_session('s', '/kickoff ABC-1', status: status)], project)?.id, 's');
      }
      for (final cmd in [
        '/kickoff',
        '/specify x',
        '/challenge-spec',
        '/plan',
        '/tasks',
        '/implement',
        '/verify',
        '/complete',
        '/fix bug',
      ]) {
        expect(runningStageSession([_session('s', cmd)], project), isNotNull, reason: cmd);
      }
    });

    test('ignora outros comandos, status encerrado, org e outro projeto', () {
      final sessions = [
        _session('a', '/review 412'),
        _session('b', '/planning'),
        _session('c', 'plan'),
        _session('d', '/kickoff', status: SessionStatus.done),
        _session('e', '/kickoff', status: SessionStatus.starting),
        _session('f', '/kickoff', org: 'acme'),
        _session('g', '/kickoff', project: 'beta'),
        _session('h', ''),
      ];

      expect(runningStageSession(sessions, project), isNull);
    });

    test('a mais recente quando há mais de uma', () {
      final sessions = [
        _session('velha', '/specify', createdAt: '2026-03-10T09:00:00Z'),
        _session('nova', '/plan', createdAt: '2026-03-10T11:00:00Z'),
        _session('meio', '/kickoff', createdAt: '2026-03-10T10:00:00Z'),
      ];

      expect(runningStageSession(sessions, project)!.id, 'nova');
    });

    test('lista vazia', () {
      expect(runningStageSession(const [], project), isNull);
    });
  });

  group('sessão da etapa', () {
    test('session_id é lido; ausente ou não-string vira null', () {
      final doc = parseReport(
        _report([
          _stage('specify', extra: {'session_id': 's1'}),
          _stage('plan', extra: {'session_id': 7}),
          _stage('tasks'),
        ]),
      )!;

      expect([for (final s in doc.stages) s.sessionId], ['s1', null, null]);
    });

    test('stageOfSession: a etapa mais recente da sessão; sem correspondência, null', () {
      final doc = parseReport(
        _report([
          _stage('specify', extra: {'session_id': 's1', 'started_at': '2026-03-10T08:00:00Z'}),
          _stage('challenge', extra: {'session_id': 's1', 'started_at': '2026-03-10T09:00:00Z'}),
          _stage('plan', extra: {'session_id': 's2', 'started_at': '2026-03-10T10:00:00Z'}),
        ]),
      );

      expect(stageOfSession(doc, 's1')?.stage, Stage.challenge);
      expect(stageOfSession(doc, 's2')?.stage, Stage.plan);
      expect(stageOfSession(doc, 's3'), isNull);
      expect(stageOfSession(null, 's1'), isNull);
    });

    test('pendingProjectSessions: só do projeto, sem org, com pendência respondível, a mais antiga primeiro', () {
      final sessions = [
        _session('nova', '/plan', pending: 1, createdAt: '2026-03-10T11:00:00Z'),
        _session('velha', '/specify', pending: 1, createdAt: '2026-03-10T09:00:00Z'),
        _session('sem', '/tasks'),
        _session('org', '/plan', project: '', org: 'acme', pending: 1),
        _session('outro', '/plan', project: 'beta', pending: 1),
        _session('morta', '/plan', status: SessionStatus.detached, pending: 1),
      ];

      expect([for (final s in pendingProjectSessions(sessions, 'alpha')) s.id], ['velha', 'nova']);
    });

    test('endedStageSessions: etapa running com sessão encerrada; viva, ausente ou etapa done não contam', () {
      final doc = parseReport(
        _report([
          _stage('challenge', status: 'running', extra: {'session_id': 'dead'}),
          _stage('plan', status: 'running', extra: {'session_id': 'live'}),
          _stage('tasks', status: 'running', extra: {'session_id': 'gone'}),
          _stage('specify', extra: {'session_id': 'dead'}),
        ]),
      );
      final sessions = [
        _session('dead', '/challenge-spec', status: SessionStatus.detached),
        _session('live', '/plan', status: SessionStatus.idle),
      ];

      expect([for (final e in endedStageSessions(doc, sessions)) (e.stage, e.session.id)], [(Stage.challenge, 'dead')]);
    });
  });
}
