import 'dart:async';

import '../engine/engine_config.dart';
import 'config_mutations.dart';
import 'flow_repository.dart';
import 'models.dart';
import 'orgs.dart';
import 'project_scan.dart' as scan;

/// In-memory repository: the config lives in a mutable raw map and goes through the same
/// [applyConfigMutation] and [annotateProjects] as the file repository.
class MockFlowRepository implements FlowRepository {
  MockFlowRepository({
    this.data = _projects,
    this.numstats = const [],
    Map<String, dynamic>? config,
    this.suggestions = const [],
  }) : _raw = config ?? defaultConfig(data);

  final List<Project> data;
  final List<FileStat> numstats;
  final List<String> suggestions;

  Map<String, dynamic> _raw;
  final _changes = StreamController<void>.broadcast();

  /// Org `demo` over the parent folders of [data]'s paths, opened by default.
  static Map<String, dynamic> defaultConfig(List<Project> data) {
    final roots = <String>{
      for (final p in data)
        if (p.path != null) parentPath(p.path!),
    };
    return {
      'orgs': [
        {'name': 'demo', 'roots': roots.toList()},
      ],
      'lastOrg': 'demo',
    };
  }

  DashboardConfig get config => DashboardConfig.fromMap(_raw);

  /// Current `.dashboard.json` content, as the file repository would have written it.
  Map<String, dynamic> get rawConfig => _raw;

  List<Project> get projects => annotateProjects(data, config, canonical: normalizePath);

  @override
  Stream<List<Project>> watchProjects() => _watch(() => projects);

  @override
  Stream<Project?> watchProject(String name) => watchProjects().map((l) => _find(l, name));

  @override
  Stream<Run?> watchRun(String project, String runId) =>
      watchProject(project).map((p) => p?.cycle?.runs.where((r) => r.id == runId).firstOrNull);

  @override
  Stream<DashboardConfig> watchConfig() => _watch(() => config);

  @override
  Future<void> updateConfig(ConfigMutation mutation) async {
    final out = applyConfigMutation(_raw, mutation);
    if (out == null) return;
    _raw = out;
    _changes.add(null);
  }

  @override
  Future<void> reload() async {}

  @override
  Future<List<FileStat>> numstat(String project, String checkpoint) async => numstats;

  @override
  Future<scan.ProjectDir> inspectDirectory(String dir) =>
      scan.inspectDirectory(dir, workflowExists: (name) => data.any((p) => p.name == name));

  @override
  Future<List<String>> suggestedRoots() async => suggestions;

  Stream<T> _watch<T>(T Function() current) => Stream.multi((controller) {
    controller.add(current());
    final sub = _changes.stream.listen((_) => controller.add(current()));
    controller.onCancel = sub.cancel;
  });

  static Project? _find(List<Project> list, String name) => list.where((p) => p.name == name).firstOrNull;
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
