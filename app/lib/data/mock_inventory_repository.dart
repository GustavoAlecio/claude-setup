import 'inventory_models.dart';
import 'inventory_repository.dart';
import 'models.dart';

class MockInventoryRepository implements InventoryRepository {
  /// [omitSkills] drops skills by directory name to exercise the "não instalado" path.
  MockInventoryRepository({Set<String> omitSkills = const {}})
    : _inventory = Inventory(
        claudeHome: _home,
        skills: [
          for (final s in _skills)
            if (!omitSkills.contains(s.name)) s,
        ],
        agents: _agents,
        workflows: _workflows,
        stacks: const [
          StackInfo(name: 'flutter', g1Reviewers: ['flutter-architecture'], g2Agent: 'qa-flutter'),
        ],
        ladder: const Ladder(
          tiers: ['haiku', 'sonnet', 'opus', 'fable'],
          tier0: {'S': 'haiku', 'M': 'sonnet', 'L': 'opus'},
          blocking: ['critical', 'major'],
        ),
      ),
      _project = _projectData;

  const MockInventoryRepository.empty()
    : _inventory = const Inventory(claudeHome: _home),
      _project = const ProjectInventory();

  static const _home = '/mock/.claude';

  final Inventory _inventory;
  final ProjectInventory _project;

  @override
  Future<Inventory> loadInventory() async => _inventory;

  @override
  Future<ProjectInventory> loadProject(Project project) async => _project;

  @override
  Future<({AdrEntry entry, String body})?> loadAdr(Project project, String id) async {
    final entry = _project.adrs.where((a) => a.id == id).firstOrNull;
    return entry == null ? null : (entry: entry, body: _adrBodies[id] ?? '# ${entry.title}\n');
  }
}

const _pipeline = [
  ('kickoff', 'sonnet', 'Entrada do pipeline. Puxa o card e faz triage.'),
  ('specify', 'opus', 'Gera a especificação de negócio. Valida com o usuário.'),
  ('challenge-spec', 'opus', 'Ataca a spec aprovada antes do plan.'),
  ('plan', 'opus', 'Gera o plano técnico a partir da spec.'),
  ('tasks', 'sonnet', 'Cria tasks ordenadas e atômicas.'),
  ('implement', 'sonnet', 'Executa as tasks via workflow com escada de modelos.'),
  ('verify', 'opus', 'G1 arquitetural do ciclo e G2 QA.'),
  ('complete', 'sonnet', 'Propõe ADRs, gera lessons e arquiva o ciclo.'),
];

final _skills = [
  for (final (name, model, description) in _pipeline)
    InventoryItem(name: name, path: '$_mockSkills/$name/SKILL.md', description: description, model: model),
];

const _mockSkills = '/mock/.claude/skills';

const _agents = [
  InventoryItem(
    name: 'flutter-a',
    path: '/mock/.claude/agents/flutter-a.md',
    description: 'Revisa arquitetura Flutter.',
    model: 'sonnet',
    tools: ['Read', 'Grep'],
  ),
  InventoryItem(
    name: 'flutter-b',
    path: '/mock/.claude/agents/flutter-b.md',
    description: 'Revisa corretude Dart.',
    model: 'sonnet',
    tools: ['Read', 'Grep'],
  ),
  InventoryItem(
    name: 'qa-flutter',
    path: '/mock/.claude/agents/qa-flutter.md',
    description: 'QA de runtime do app Flutter.',
    model: 'sonnet',
    tools: ['Read', 'Bash'],
  ),
  InventoryItem(
    name: 'dev-implementer',
    path: '/mock/.claude/agents/dev-implementer.md',
    description: 'Implementa uma task do plano.',
    tools: ['Read', 'Edit', 'Write', 'Bash'],
  ),
];

const _workflows = [
  WorkflowEntry(
    path: '/mock/.claude/workflows/smart-implement.js',
    meta: WorkflowMeta(
      name: 'smart-implement',
      description: 'Executa as tasks com escada de modelos.',
      phases: [
        WorkflowPhase(title: 'Implement', detail: 'dev-implementer no tier corrente'),
        WorkflowPhase(title: 'G0', detail: 'format, codegen, analyze, testes'),
        WorkflowPhase(title: 'G1', detail: 'review arquitetural do diff'),
        WorkflowPhase(title: 'Ops', detail: 'rollback na escalada'),
        WorkflowPhase(title: 'Diagnose', detail: 'ToT quando a escada esgota'),
      ],
    ),
  ),
  WorkflowEntry(
    path: '/mock/.claude/workflows/smart-verify.js',
    meta: WorkflowMeta(
      name: 'smart-verify',
      description: 'G1 do ciclo e G2 QA.',
      phases: [
        WorkflowPhase(title: 'G1', detail: 'reviewers da stack'),
        WorkflowPhase(title: 'G2', detail: 'QA de aceite'),
        WorkflowPhase(title: 'Reentry', detail: 'findings para tasks'),
      ],
    ),
  ),
  WorkflowEntry(
    path: '/mock/.claude/workflows/tot-plan.js',
    meta: WorkflowMeta(
      name: 'tot-plan',
      description: 'Plano por tree-of-thought.',
      phases: [
        WorkflowPhase(title: 'Branch', detail: '3 planejadores'),
        WorkflowPhase(title: 'Judge', detail: '2 juízes'),
        WorkflowPhase(title: 'Synthesize', detail: 'escreve o plan.md'),
      ],
    ),
  ),
];

const _adrBodies = {
  '0001': '# Parser puro separado do IO\n\nParsers são funções puras. Veja [[0002-cubit]].\n',
  '0002': '# StreamCubit genérico\n\nDepende de [[0001]].\n',
};

const _projectData = ProjectInventory(
  adrSubmodule: GitSubmodule(path: 'docs', url: 'git@github.com:acme/org-docs.git'),
  rules: [
    RuleEntry(
      name: 'flutter-app',
      path: '/mock/demo-app/.claude/rules/flutter-app.md',
      summary: 'Estas regras valem para app/.',
    ),
  ],
  adrs: [
    AdrEntry(
      id: '0001',
      title: 'Parser puro separado do IO',
      status: 'accepted',
      path: '/mock/demo-app/docs/adr/0001-parser.md',
    ),
    AdrEntry(
      id: '0002',
      title: 'StreamCubit genérico',
      status: 'accepted',
      path: '/mock/demo-app/docs/adr/0002-cubit.md',
    ),
  ],
  lessons: ['[pipeline] Teste e implementação vão na mesma task.', '[flutter] Não recarregue tudo no onResume.'],
  routing: Routing(
    bands: [
      RoutingBand(
        complexity: 'M',
        risk: 'low',
        n: 4,
        passTier0: 3,
        escalated: 1,
        blocked: 0,
        attemptsPerTask: 1.3,
        finalTiers: {'sonnet': 3, 'opus': 1},
      ),
    ],
    overrides: {'L:high': 'fable'},
  ),
);
