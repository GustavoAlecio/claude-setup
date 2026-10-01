import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/core/claude_home.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/theme/app_colors.dart';
import 'package:claude_flow/core/widgets/primitives.dart';
import 'package:claude_flow/data/flow_repository.dart';
import 'package:claude_flow/data/inventory_models.dart';
import 'package:claude_flow/data/inventory_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_inventory_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/features/about/about_flow.dart';
import 'package:claude_flow/features/about/about_inventory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _paths = EffectivePaths(home: '/home/u', workflowRoot: '/home/u/.claude/workflow');

Widget _app(FlowRepository repository, InventoryRepository inventory) => ClaudeFlowApp(
  repository: repository,
  sessions: MockSessionsRepository(),
  engine: const MockEngineController(),
  inventory: inventory,
  paths: _paths,
);

const _data = [
  Project(name: 'alpha', path: '/dev/a/alpha'),
  Project(name: 'beta', path: '/dev/a/beta'),
  Project(name: 'hid', path: '/dev/a/hid'),
];

Map<String, dynamic> _config() => {
  'engineDir': '/engine',
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
  'projects': [
    {'name': 'nopath', 'org': 'A'},
  ],
  'hidden': ['hid'],
  'lastOrg': 'A',
};

ProjectInventory _projectData(String name) => ProjectInventory(
  rules: [RuleEntry(name: '$name-rule', path: '/r/$name.md', summary: 'regra de $name')],
  adrs: [
    AdrEntry(id: '0001', title: 'Primeira de $name', status: 'accepted', path: '/a/1.md'),
    AdrEntry(id: '0002', title: 'Segunda de $name', status: 'superseded', path: '/a/2.md'),
  ],
  lessons: ['[flutter] lição de $name'],
  routing: Routing(
    bands: const [
      RoutingBand(
        complexity: 'M',
        risk: 'low',
        n: 4,
        passTier0: 3,
        escalated: 1,
        blocked: 0,
        attemptsPerTask: 1.25,
        finalTiers: {'sonnet': 3},
      ),
    ],
    overrides: {'L:high': '$name-tier'},
  ),
);

/// Answers every project with data named after it, so a picker switch is visible on screen.
class _PerProjectInventory extends MockInventoryRepository {
  final loaded = <String>[];

  @override
  Future<ProjectInventory> loadProject(Project project) async {
    loaded.add(project.name);
    return _projectData(project.name);
  }
}

class _SearchInventory implements InventoryRepository {
  @override
  Future<Inventory> loadInventory() async => const Inventory(
    claudeHome: '/h',
    skills: [InventoryItem(name: 'kickoff', path: '/h/skills/kickoff/SKILL.md', description: 'Entrada do pipeline.')],
    agents: [
      InventoryItem(name: 'dart-correctness', path: '/h/agents/dart-correctness.md', description: 'Revisa Dart.'),
      InventoryItem(name: 'flutter-architecture', path: '/h/agents/flutter-architecture.md', description: 'Camadas.'),
      InventoryItem(name: 'security', path: '/h/agents/security.md', description: 'Checa a Correctness da auth.'),
    ],
    workflows: [
      WorkflowEntry(
        path: '/h/workflows/smart-verify.js',
        meta: WorkflowMeta(name: 'smart-verify', description: 'G1 de correctness do ciclo.'),
      ),
    ],
  );

  @override
  Future<ProjectInventory> loadProject(Project project) async => const ProjectInventory();

  @override
  Future<({AdrEntry entry, String body})?> loadAdr(Project project, String id) async => null;
}

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

Future<void> _meta(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

Future<void> _openAbout(WidgetTester tester, InventoryRepository inventory, {FlowRepository? repository}) async {
  await tester.pumpWidget(_app(repository ?? MockFlowRepository(data: _data, config: _config()), inventory));
  await tester.pumpAndSettle();
  await _meta(tester, LogicalKeyboardKey.keyI);
  expect(_location(tester), '/about');
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

Finder _node(Stage stage) => find.byKey(ValueKey('about-node-${stage.label}'));

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 2000);
    view.devicePixelRatio = 1;
  });

  group('route and entries', () {
    testWidgets('⌘I from a project route and Voltar returns there; title clears the traffic lights', (tester) async {
      await tester.pumpWidget(_app(MockFlowRepository(), MockInventoryRepository()));
      await tester.pumpAndSettle();
      _router(tester).go('/p/notifications-api/runs');
      await tester.pumpAndSettle();

      await _meta(tester, LogicalKeyboardKey.keyI);
      expect(_location(tester), '/about');
      expect(find.text('Sobre o app'), findsOneWidget);
      expect(find.text('Execuções'), findsNothing, reason: 'no shell tabs on /about');
      expect(tester.getTopLeft(find.widgetWithText(TextButton, 'Voltar')).dy, greaterThanOrEqualTo(kTitleBarInset));

      await tester.tap(find.text('Voltar'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/notifications-api/runs');
    });

    testWidgets('⌘I from the landing and Voltar returns to /', (tester) async {
      await tester.pumpWidget(_app(MockFlowRepository(data: const [], config: const {}), MockInventoryRepository()));
      await tester.pumpAndSettle();
      expect(_location(tester), '/');

      await _meta(tester, LogicalKeyboardKey.keyI);
      expect(_location(tester), '/about');
      await tester.tap(find.text('Voltar'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/');
    });

    testWidgets('org menu item opens /about', (tester) async {
      await tester.pumpWidget(_app(MockFlowRepository(data: _data, config: _config()), MockInventoryRepository()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('current-org')));
      await tester.pumpAndSettle();
      expect(find.text('⌘I'), findsOneWidget);

      await tester.tap(find.text('Sobre o app'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/about');
    });
  });

  group('flow', () {
    testWidgets('8 nodes in Stage order with the mock models and phases', (tester) async {
      await _openAbout(tester, MockInventoryRepository());

      final centers = [for (final s in Stage.values) tester.getCenter(_node(s))];
      for (var i = 1; i < centers.length; i++) {
        final (prev, cur) = (centers[i - 1], centers[i]);
        expect(cur.dy > prev.dy || (cur.dy == prev.dy && cur.dx > prev.dx), isTrue, reason: Stage.values[i].label);
      }
      const models = {
        Stage.kickoff: 'sonnet',
        Stage.specify: 'opus',
        Stage.challenge: 'opus',
        Stage.plan: 'opus',
        Stage.tasks: 'sonnet',
        Stage.implement: 'sonnet',
        Stage.verify: 'opus',
        Stage.complete: 'sonnet',
      };
      for (final MapEntry(key: stage, value: model) in models.entries) {
        expect(_in(_node(stage), find.text(model)), findsOneWidget, reason: stage.label);
      }
      expect(_in(_node(Stage.kickoff), find.text('Entrada do pipeline.')), findsOneWidget);
      for (final phase in ['Implement', 'G0', 'G1', 'Ops', 'Diagnose']) {
        expect(_in(_node(Stage.implement), find.text('· $phase')), findsOneWidget);
      }
      for (final phase in ['G1', 'G2', 'Reentry']) {
        expect(_in(_node(Stage.verify), find.text('· $phase')), findsOneWidget);
      }
      expect(_in(_node(Stage.plan), find.text('alternativa: tot-plan')), findsOneWidget);
      expect(_in(_node(Stage.challenge), find.text('agente spec-challenger: não instalado')), findsOneWidget);

      await tester.tap(_node(Stage.specify));
      await tester.pumpAndSettle();
      final detail = find.byKey(const ValueKey('about-node-detail'));
      expect(_in(detail, find.text('Gera a especificação de negócio. Valida com o usuário.')), findsOneWidget);
      expect(_in(detail, find.text('/mock/.claude/skills/specify/SKILL.md')), findsOneWidget);
    });

    testWidgets('missing verify skill renders "não instalado" and keeps the other 7', (tester) async {
      await _openAbout(tester, MockInventoryRepository(omitSkills: {'verify'}));

      expect(_in(_node(Stage.verify), find.text('não instalado')), findsOneWidget);
      for (final stage in Stage.values.where((s) => s != Stage.verify)) {
        expect(_in(_node(stage), find.text(stage.label)), findsWidgets, reason: stage.label);
        expect(_in(_node(stage), find.text('não instalado')), findsNothing, reason: stage.label);
      }
    });

    testWidgets('ladder in order, tier0 per complexity, fixed risk text and blocking', (tester) async {
      await _openAbout(tester, MockInventoryRepository());

      final ladder = find.byKey(const ValueKey('about-ladder'));
      final xs = [
        for (final t in ['haiku', 'sonnet', 'opus', 'fable']) tester.getCenter(_in(ladder, find.text(t))).dx,
      ];
      expect(xs, [...xs]..sort());
      for (final line in ['S → haiku', 'M → sonnet', 'L → opus']) {
        expect(_in(ladder, find.text(line)), findsOneWidget);
      }
      expect(_in(ladder, find.text(kRiskRule)), findsOneWidget);
      expect(_in(ladder, find.text(kRiskRulePath)), findsOneWidget);
      expect(_in(ladder, find.text('critical, major')), findsOneWidget);
      expect(_in(ladder, find.text('flutter — G1: flutter-architecture · G2: qa-flutter')), findsOneWidget);
    });
  });

  group('inventory', () {
    testWidgets('search is case-insensitive over name and description; empty section says nenhum', (tester) async {
      await _openAbout(tester, _SearchInventory());
      await _tab(tester, 'Inventário');

      await tester.enterText(find.byKey(const ValueKey('about-search')), 'CORRECTNESS');
      await tester.pumpAndSettle();

      final skills = find.byKey(const ValueKey('about-skills'));
      final agents = find.byKey(const ValueKey('about-agents'));
      final workflows = find.byKey(const ValueKey('about-workflows'));
      expect(_in(skills, find.text('nenhum')), findsOneWidget);
      expect(_in(skills, find.text('kickoff')), findsNothing);
      expect(_in(agents, find.text('dart-correctness')), findsOneWidget);
      expect(_in(agents, find.text('security')), findsOneWidget);
      expect(_in(agents, find.text('flutter-architecture')), findsNothing);
      expect(_in(workflows, find.text('smart-verify')), findsOneWidget);
    });

    testWidgets('expanded state follows the item when the filter changes', (tester) async {
      await _openAbout(tester, _SearchInventory());
      await _tab(tester, 'Inventário');

      await tester.tap(find.text('dart-correctness'));
      await tester.pumpAndSettle();
      expect(find.text('/h/agents/dart-correctness.md'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('about-search')), 'security');
      await tester.pumpAndSettle();
      expect(_in(find.byKey(const ValueKey('about-agents')), find.text('security')), findsOneWidget);
      expect(find.text('/h/agents/security.md'), findsNothing, reason: 'security was never expanded');
    });

    testWidgets('agents grouped by shared prefix, outros last; pipeline skills marked', (tester) async {
      await _openAbout(tester, MockInventoryRepository());
      await _tab(tester, 'Inventário');

      final flutter = find.text('flutter (2)');
      final others = find.text('outros (2)');
      expect(flutter, findsOneWidget);
      expect(others, findsOneWidget);
      expect(tester.getTopLeft(flutter).dy, lessThan(tester.getTopLeft(others).dy));
      expect(find.text('qa (1)'), findsNothing);
      expect(_in(find.byKey(const ValueKey('about-skills')), find.text('pipeline')), findsNWidgets(8));
      expect(find.text('tools: Read, Grep'), findsNWidgets(2));
    });

    test('groupAgents keeps singletons in outros', () {
      InventoryItem a(String name) => InventoryItem(name: name, path: '/a/$name.md');
      final groups = groupAgents([a('flutter-a'), a('qa-flutter'), a('flutter-b'), a('dev-implementer'), a('solo')]);
      expect([for (final (name, items) in groups) '$name:${items.length}'], ['flutter:2', 'outros:3']);
    });
  });

  group('project', () {
    testWidgets('picker defaults to the route project, switches, and hides rules/ADRs without path', (tester) async {
      final inventory = _PerProjectInventory();
      await _openAbout(tester, inventory);
      await _tab(tester, 'Projeto');

      expect(find.text('org A'), findsOneWidget);
      expect(find.text('alpha-rule'), findsOneWidget);
      expect(find.text('regra de alpha'), findsOneWidget);
      final first = tester.getTopLeft(find.text('Primeira de alpha')).dy;
      expect(first, lessThan(tester.getTopLeft(find.text('Segunda de alpha')).dy), reason: 'ADRs by id');
      final colors = tester.element(find.text('Primeira de alpha')).colors;
      for (final status in ['accepted', 'superseded']) {
        final pill = tester.widget<Pill>(find.widgetWithText(Pill, status));
        expect(pill.color, adrStatusColor(colors, status));
      }
      expect(find.textContaining('lição de alpha', findRichText: true), findsOneWidget);
      expect(find.text('L:high → alpha-tier'), findsOneWidget);
      expect(find.textContaining('tentativas/task 1.3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('about-project-picker')));
      await tester.pumpAndSettle();
      expect(find.text('hid'), findsNothing, reason: 'hidden projects are not offered');
      await tester.tap(find.text('beta').last);
      await tester.pumpAndSettle();
      expect(find.text('beta-rule'), findsOneWidget);
      expect(find.text('alpha-rule'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('about-project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('nopath').last);
      await tester.pumpAndSettle();
      expect(find.text('sem path'), findsOneWidget);
      expect(find.text('RULES'), findsNothing);
      expect(find.text('ADRs'), findsNothing);
      expect(find.textContaining('lição de nopath', findRichText: true), findsOneWidget);
      expect(find.text('L:high → nopath-tier'), findsOneWidget);
      expect(inventory.loaded, ['alpha', 'beta', 'nopath']);
    });

    testWidgets('org without visible projects shows nenhum projeto', (tester) async {
      final config = _config()..['lastOrg'] = 'B';
      await _openAbout(
        tester,
        _PerProjectInventory(),
        repository: MockFlowRepository(data: const [], config: config),
      );
      await _tab(tester, 'Projeto');

      expect(find.text('org B'), findsOneWidget);
      expect(find.text('nenhum projeto'), findsOneWidget);
    });
  });

  testWidgets('config is read-only and lists orgs, registered, hidden, engineDir and engine state', (tester) async {
    await _openAbout(tester, MockInventoryRepository());
    await _tab(tester, 'Config');

    Finder row(String key, String text) => _in(find.byKey(ValueKey(key)), find.textContaining(text));
    expect(row('about-config-org-A', '/dev/a · 3 projetos visíveis'), findsOneWidget);
    expect(row('about-config-org-B', '0 projetos visíveis'), findsOneWidget);
    expect(row('about-config-project-nopath', 'sem path · org A'), findsOneWidget);
    expect(find.byKey(const ValueKey('about-config-hidden-hid')), findsOneWidget);
    expect(row('about-config-engine-dir', '/engine'), findsOneWidget);
    expect(row('about-config-engine-dir-effective', '/engine'), findsOneWidget);
    expect(row('about-config-engine-state', 'ok'), findsOneWidget);
    expect(find.textContaining('padrão (todas)'), findsOneWidget);
    expect(find.textContaining('/mock/.claude'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'nothing editable here');

    await tester.tap(find.text('Editar em Configurações'));
    await tester.pumpAndSettle();
    expect(_location(tester), '/settings');
  });

  testWidgets('config shows the effective engineDir with ~/ expanded and the workflow root', (tester) async {
    final config = _config()..['engineDir'] = '~/eng/';
    await _openAbout(
      tester,
      MockInventoryRepository(),
      repository: MockFlowRepository(data: _data, config: config),
    );
    await _tab(tester, 'Config');

    expect(
      _in(find.byKey(const ValueKey('about-config-engine-dir')), find.textContaining('~/eng/')),
      findsOneWidget,
      reason: 'config value is shown as written',
    );
    expect(
      _in(find.byKey(const ValueKey('about-config-engine-dir-effective')), find.text('/home/u/eng')),
      findsOneWidget,
    );
    expect(
      _in(find.byKey(const ValueKey('about-config-workflow-root')), find.text('/home/u/.claude/workflow')),
      findsOneWidget,
    );
  });

  testWidgets('Recarregar reads the inventory again', (tester) async {
    final inventory = _CountingInventory();
    await _openAbout(tester, inventory);
    await _tab(tester, 'Inventário');
    await _tab(tester, 'Fluxo');
    expect(inventory.loads, 1, reason: 'switching tabs reuses the loaded inventory');

    await tester.tap(find.text('Recarregar'));
    await tester.pumpAndSettle();
    expect(inventory.loads, 2);
  });
}

class _CountingInventory extends MockInventoryRepository {
  int loads = 0;

  @override
  Future<Inventory> loadInventory() {
    loads++;
    return super.loadInventory();
  }
}
