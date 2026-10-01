import 'flow_repository.dart';
import 'mock_sessions.dart';
import 'models.dart';
import 'session_models.dart';

class MockFlowRepository implements FlowRepository {
  const MockFlowRepository({this.data = _projects});

  final List<Project> data;

  @override
  Stream<List<Project>> watchProjects() => Stream.value(data);

  @override
  Stream<Project?> watchProject(String name) => Stream.value(_project(name));

  @override
  Stream<Run?> watchRun(String project, String runId) =>
      Stream.value(_project(project)?.cycle?.runs.where((r) => r.id == runId).firstOrNull);

  @override
  List<SessionSummary> sessions() => mockSessions;

  @override
  SessionSummary? session(String id) => mockSessions.where((s) => s.id == id).firstOrNull;

  @override
  Future<void> reload() async {}

  Project? _project(String name) => data.where((p) => p.name == name).firstOrNull;
}

const _g0Pass = GateResult('G0', Verdict.pass);
const _g1Pass = GateResult('G1', Verdict.pass);

const _sameFinding = Finding(
  gate: 'G1',
  severity: 'major',
  file: 'lib/features/favorites/data/favorites_sync.dart',
  line: 88,
  ruleRef: 'docs/adr/0004-offline-first-sync.md',
  message: 'Sync grava direto no cache sem passar pela fila de mutações; viola a ordem garantida do ADR 0004.',
);

const _blockedRun = Run(
  id: 'impl-20261001T141210Z',
  kind: 'implement',
  status: Verdict.blocked,
  startedAt: '14:12',
  reason: 'same_failure_across_tiers',
  tasks: [
    TaskRun(
      id: 'T1',
      title: 'Modelo FavoriteItem + serialização',
      complexity: Complexity.s,
      tier0: Tier.haiku,
      status: Verdict.pass,
      files: ['lib/features/favorites/domain/favorite_item.dart'],
      attempts: [
        Attempt(number: 1, ordinal: 1, tier: Tier.haiku, gates: [_g0Pass, _g1Pass], tokensOut: 2140),
      ],
    ),
    TaskRun(
      id: 'T2',
      title: 'Teste do FavoritesCubit (Red)',
      complexity: Complexity.s,
      tier0: Tier.haiku,
      status: Verdict.pass,
      files: ['test/features/favorites/favorites_cubit_test.dart'],
      attempts: [
        Attempt(
          number: 1,
          ordinal: 1,
          tier: Tier.haiku,
          tokensOut: 3010,
          gates: [
            GateResult('G0', Verdict.fail, [
              Finding(
                gate: 'G0',
                severity: 'major',
                file: 'test/features/favorites/favorites_cubit_test.dart',
                ruleRef: 'missing_test',
                message: 'test mapped in plan/tasks does not exist',
              ),
            ]),
          ],
        ),
        Attempt(
          number: 2,
          ordinal: 2,
          tier: Tier.haiku,
          tokensOut: 2870,
          escalatedTo: Tier.sonnet,
          gates: [
            _g0Pass,
            GateResult('G1', Verdict.fail, [
              Finding(
                gate: 'G1',
                severity: 'major',
                file: 'test/features/favorites/favorites_cubit_test.dart',
                line: 31,
                ruleRef: '.claude/rules/testing.md#no-mock-only',
                message: 'Teste só verifica chamadas do mock; nenhum estado emitido é asserido.',
              ),
            ]),
          ],
        ),
        Attempt(
          number: 3,
          ordinal: 3,
          tier: Tier.sonnet,
          tokensOut: 4120,
          summary: 'Recomeço após rollback: blocTest com seed e expect de estados.',
          gates: [_g0Pass, _g1Pass],
        ),
      ],
    ),
    TaskRun(
      id: 'T3',
      title: 'FavoritesCubit com estados sealed',
      complexity: Complexity.m,
      tier0: Tier.sonnet,
      status: Verdict.pass,
      files: ['lib/features/favorites/presentation/favorites_cubit.dart'],
      attempts: [
        Attempt(number: 1, ordinal: 1, tier: Tier.sonnet, gates: [_g0Pass, _g1Pass], tokensOut: 5230),
      ],
    ),
    TaskRun(
      id: 'T4',
      title: 'Sincronização offline com fila de mutações',
      complexity: Complexity.l,
      risk: true,
      tier0: Tier.opus,
      status: Verdict.blocked,
      blockedReason: 'same_failure_across_tiers',
      files: ['lib/features/favorites/data/favorites_sync.dart'],
      attempts: [
        Attempt(
          number: 1,
          ordinal: 1,
          tier: Tier.opus,
          tokensOut: 9800,
          gates: [
            _g0Pass,
            GateResult('G1', Verdict.fail, [
              _sameFinding,
              Finding(
                gate: 'G1',
                severity: 'major',
                file: 'lib/features/favorites/data/favorites_sync.dart',
                line: 140,
                ruleRef: '.claude/rules/logging.md',
                message: 'debugPrint no lugar do logger do projeto.',
              ),
            ]),
          ],
        ),
        Attempt(
          number: 2,
          ordinal: 2,
          tier: Tier.opus,
          tokensOut: 7400,
          escalatedTo: Tier.fable,
          gates: [
            _g0Pass,
            GateResult('G1', Verdict.fail, [_sameFinding]),
          ],
        ),
        Attempt(
          number: 3,
          ordinal: 3,
          tier: Tier.fable,
          tokensOut: 11200,
          summary: 'Recomeço: fila persistida em Isar, flush no reconnect.',
          gates: [
            _g0Pass,
            GateResult('G1', Verdict.fail, [_sameFinding]),
          ],
        ),
      ],
      diagnosis: [
        Hypothesis(
          lens: 'plan',
          hypothesis:
              'O plano manda o sync escrever no cache local para resposta otimista, mas o ADR 0004 exige que toda escrita passe pela fila. As duas coisas não cabem juntas como o plano descreve.',
          confidence: 0.82,
          evidence: ['plan.md §Ordem de execução passo 4', 'docs/adr/0004-offline-first-sync.md §Decisão'],
          action: 'replan',
        ),
        Hypothesis(
          lens: 'spec',
          hypothesis:
              'O critério "favoritar funciona offline instantaneamente" não define se a UI pode refletir antes do enqueue.',
          confidence: 0.55,
          evidence: ['spec.md critério 3'],
          action: 'fix_spec',
        ),
        Hypothesis(
          lens: 'environment',
          hypothesis: 'Gates e testes estáveis; nenhum sinal de flake ou tooling.',
          confidence: 0.12,
          evidence: ['G0 passou nas 3 tentativas'],
          action: 'fix_environment',
        ),
      ],
    ),
    TaskRun(
      id: 'T5',
      title: 'Tela de favoritos com estado offline',
      complexity: Complexity.m,
      tier0: Tier.sonnet,
      status: Verdict.pending,
    ),
  ],
);

const _projects = <Project>[
  Project(
    name: 'demo-app',
    path: '~/development/demo-app',
    stack: 'flutter',
    cycle: Cycle(
      feature: 'Favoritos offline',
      tracker: 'LIN-142',
      stage: Stage.implement,
      branch: 'feat/lin-142-favoritos-offline',
      autoMode: true,
      stageMinutes: {
        Stage.kickoff: 2,
        Stage.specify: 6,
        Stage.challenge: 3,
        Stage.plan: 14,
        Stage.tasks: 2,
        Stage.implement: 38,
      },
      runs: [_blockedRun],
    ),
  ),
  Project(
    name: 'notifications-api',
    path: '~/development/notifications-api',
    stack: 'go',
    cycle: Cycle(
      feature: 'Retry com backoff',
      tracker: 'ADO 6731',
      stage: Stage.verify,
      branch: 'feat/3.12.0/6731-retry-backoff',
      autoMode: false,
      stageMinutes: {Stage.specify: 4, Stage.plan: 9, Stage.tasks: 1, Stage.implement: 21, Stage.verify: 5},
      runs: [],
    ),
  ),
  Project(name: 'web-console', path: '~/development/web-console', stack: 'react'),
];
