import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/theme/app_colors.dart';
import 'package:claude_flow/data/inventory_models.dart';
import 'package:claude_flow/data/file_metrics_repository.dart';
import 'package:claude_flow/data/inventory_repository.dart';
import 'package:claude_flow/data/metrics_models.dart';
import 'package:claude_flow/data/metrics_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_inventory_repository.dart';
import 'package:claude_flow/data/mock_metrics_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/features/metrics/metrics_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _RoutingInventory extends MockInventoryRepository {
  _RoutingInventory(this.routing);

  final Routing routing;

  @override
  Future<ProjectInventory> loadProject(Project project) async => ProjectInventory(routing: routing);
}

class _FixedMetrics implements MetricsRepository {
  const _FixedMetrics(this.metrics);

  final ProjectMetrics metrics;

  @override
  Future<ProjectMetrics> loadProject(Project project) async => metrics;
}

/// Histórico do `alpha` gerado pelo `gen.sh`: um ciclo com `report.json` e outro sem.
Future<MetricsRepository> _alphaHistory(WidgetTester tester) async {
  final fixtures = Directory('test/fixtures').absolute.path;
  final metrics = await tester.runAsync(
    () => FileMetricsRepository(fixtures, '$fixtures/workflow').loadProject(const Project(name: 'alpha')),
  );
  return _FixedMetrics(metrics!);
}

Future<GoRouter> _open(
  WidgetTester tester,
  String location, {
  MetricsRepository? metrics,
  InventoryRepository? inventory,
  Size size = const Size(1600, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(),
      sessions: MockSessionsRepository(),
      engine: const MockEngineController(),
      metrics: metrics ?? MockMetricsRepository.sample(),
      inventory: inventory ?? MockInventoryRepository(),
    ),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
  router.go(location);
  await tester.pumpAndSettle();
  return router;
}

Finder _cardValue(String id, String value) =>
    find.descendant(of: find.byKey(ValueKey('metrics-card-$id')), matching: find.text(value));

Finder _inBand(String band, String text) =>
    find.descendant(of: find.byKey(ValueKey('metrics-band-$band')), matching: find.text(text));

Future<void> _show(WidgetTester tester, String section) async {
  // Below the fold the sliver is laid out but not painted, which the default finder skips.
  final toggle = find.byKey(ValueKey('metrics-show-$section'), skipOffstage: false);
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

Color _barColor(WidgetTester tester, String band) =>
    tester.widget<ColoredBox>(find.byKey(ValueKey('metrics-band-bar-$band'))).color;

RoutingBand _band(String complexity, String risk, int passTier0, int n) => RoutingBand(
  complexity: complexity,
  risk: risk,
  n: n,
  passTier0: passTier0,
  escalated: n - passTier0,
  blocked: 0,
  attemptsPerTask: 1,
  finalTiers: const {},
);

CycleMetrics _tracedCycle(int i, String feature) => CycleMetrics(
  dir: '2026-05-0${i}_ciclo-$i',
  date: '2026-05-0$i',
  feature: feature,
  status: 'completed',
  tasksLabel: '1/1',
  tasks: const [
    TaskMetrics(
      key: 'T1',
      tier0: 'sonnet',
      tierFinal: 'sonnet',
      attempts: 1,
      escalated: false,
      passedTier0: true,
      blocked: false,
      tokens: 100,
    ),
  ],
  escalations: 0,
  verifyRuns: 1,
  rounds: 1,
  tokensByRole: const {'dev': 100, 'g0': 0, 'g1': 0, 'g2': 0, 'outros': 0},
  hasTokens: true,
  tokensMissing: 0,
  ignoredLines: 0,
  runsWithoutTrace: 0,
  warnings: const [],
  current: false,
  hasTrace: true,
);

final _cycleTitle = find.descendant(
  of: find.byKey(const ValueKey('metrics-cycle-2026-04-20_metricas')),
  matching: find.text('Métricas'),
);

void main() {
  testWidgets('the four numbers show the fixed values of the mock sample, each over its label', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    expect(find.byType(MetricsPage), findsOneWidget);
    expect(_cardValue('completed', '3'), findsOneWidget);
    expect(_cardValue('completed', 'ciclos concluídos'), findsOneWidget);
    expect(_cardValue('pass-tier0', '80%'), findsOneWidget);
    expect(_cardValue('pass-tier0', 'das tasks passaram sem trocar de modelo'), findsOneWidget);
    expect(_cardValue('escalations', '1'), findsOneWidget);
    expect(_cardValue('escalations', 'task escalou de modelo'), findsOneWidget);
    expect(_cardValue('cost', '\$0.62'), findsOneWidget, reason: 'sum of the demo-app sessions in the mock');
    expect(_cardValue('cost', 'gastos nas conversas'), findsOneWidget);
    expect(find.byKey(const ValueKey('metrics-card-tasks')), findsNothing);

    final value = tester.getRect(_cardValue('completed', '3'));
    final label = tester.getRect(_cardValue('completed', 'ciclos concluídos'));
    expect(label.top, greaterThanOrEqualTo(value.bottom));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('metrics-card-completed'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('metrics-card-cost'))).dy,
      reason: 'the four numbers sit on one line',
    );
  });

  testWidgets('labels of the numbers follow the count', (tester) async {
    final one = _tracedCycle(1, 'Um');
    await _open(
      tester,
      '/p/demo-app/metrics',
      metrics: _FixedMetrics(
        ProjectMetrics(
          cycles: [one],
          completedCycles: 1,
          tasks: 3,
          passedTier0: 1,
          escalations: 2,
          tokensByRole: one.tokensByRole,
          hasTokens: true,
        ),
      ),
    );

    expect(_cardValue('completed', '1'), findsOneWidget);
    expect(_cardValue('completed', 'ciclo concluído'), findsOneWidget);
    expect(_cardValue('pass-tier0', '33%'), findsOneWidget);
    expect(_cardValue('escalations', '2'), findsOneWidget);
    expect(_cardValue('escalations', 'tasks escalaram de modelo'), findsOneWidget);
  });

  testWidgets('without tasks the pass rate is a dash', (tester) async {
    await _open(tester, '/p/demo-app/metrics', metrics: const MockMetricsRepository.empty());

    expect(_cardValue('pass-tier0', '—'), findsOneWidget);
    expect(_cardValue('completed', 'ciclos concluídos'), findsOneWidget);
    expect(_cardValue('escalations', 'tasks escalaram de modelo'), findsOneWidget);
  });

  testWidgets('token cards only exist after opening "Ver gasto por papel do agente"', (tester) async {
    await _open(tester, '/p/demo-app/metrics');
    expect(find.byKey(const ValueKey('metrics-card-tokens-dev')), findsNothing);

    await _show(tester, 'tokens');

    expect(_cardValue('tokens-dev', '870'), findsOneWidget);
    expect(_cardValue('tokens-g0', '0'), findsOneWidget);
    expect(_cardValue('tokens-g1', '310'), findsOneWidget);
    expect(_cardValue('tokens-g2', '30'), findsOneWidget);

    await _show(tester, 'tokens');
    expect(find.byKey(const ValueKey('metrics-card-tokens-dev')), findsNothing);
  });

  testWidgets('the insight card states the band that gets stuck', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    Finder inInsight(String text) =>
        find.descendant(of: find.byKey(const ValueKey('metrics-insight')), matching: find.text(text));
    expect(inInsight('Tasks grandes e de risco alto travam mais'), findsOneWidget);
    expect(
      inInsight(
        'Nos ciclos deste projeto, só 2 de 5 passaram sem trocar de modelo. '
        'Todas as outras faixas ficam em 75% ou mais. Vale quebrar essas tasks antes de implementar.',
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('metrics-insight'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('metrics-card-completed'))).dy),
    );
  });

  testWidgets('no stuck band, no insight card and no highlighted bar', (tester) async {
    await _open(
      tester,
      '/p/demo-app/metrics',
      inventory: _RoutingInventory(Routing(bands: [_band('M', 'low', 3, 4), _band('S', 'low', 9, 10)])),
    );

    expect(find.byKey(const ValueKey('metrics-insight')), findsNothing);
    final warn = AppColors.dark.warn;
    expect(_barColor(tester, 'M:low'), isNot(warn));
    expect(_barColor(tester, 'S:low'), isNot(warn));
    expect(tester.widget<Text>(_inBand('M:low', 'Média')).style!.fontWeight, isNot(FontWeight.w600));
  });

  testWidgets('the page is one column of at most 720 px', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    expect(tester.getSize(find.byKey(const ValueKey('metrics-insight'))).width, 720);
    expect(tester.getSize(find.byKey(const ValueKey('metrics-bands'))).width, 720);
  });

  testWidgets('cycles only exist after opening "Ver ciclo por ciclo"', (tester) async {
    await _open(tester, '/p/demo-app/metrics');
    const cycle = ValueKey('metrics-cycle-2026-04-20_metricas');
    expect(find.byKey(cycle), findsNothing);
    expect(find.text('Ciclos'), findsNothing);

    await _show(tester, 'cycles');
    expect(find.byKey(cycle), findsOneWidget);
    expect(find.text('Ciclos'), findsOneWidget);

    await _show(tester, 'cycles');
    expect(find.byKey(cycle), findsNothing);
  });

  testWidgets('cycles are ordered current first, then date and persisted_at desc, no-trace last', (tester) async {
    await _open(tester, '/p/demo-app/metrics');
    await _show(tester, 'cycles');

    const order = ['ciclo-atual', '2026-04-20_metricas', '2026-04-20_adrs', '2026-04-10_sem-trace'];
    final tops = [for (final dir in order) tester.getTopLeft(find.byKey(ValueKey('metrics-cycle-$dir'))).dy];
    expect(tops, [...tops]..sort());
    expect(find.text('em andamento'), findsOneWidget);
    expect(find.textContaining('sem trace'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('expanding a cycle mounts its tasks with tier0 to final tier', (tester) async {
    await _open(tester, '/p/demo-app/metrics');
    await _show(tester, 'cycles');
    const task = ValueKey('metrics-task-2026-04-20_metricas-T1');
    expect(find.byKey(task), findsNothing);

    await tester.tap(_cycleTitle);
    await tester.pumpAndSettle();

    final row = find.byKey(task);
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('sonnet')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('opus')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('2 tentativas')), findsOneWidget);
    expect(find.byKey(const ValueKey('metrics-task-2026-04-20_metricas-T2')), findsOneWidget);

    await tester.tap(_cycleTitle);
    await tester.pumpAndSettle();
    expect(find.byKey(task), findsNothing);
  });

  testWidgets('bands show label, share and "X de N" in size order, and overrides stay', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    final band = find.byKey(const ValueKey('metrics-band-M:low'));
    expect(band, findsOneWidget);
    expect(_inBand('M:low', 'Média'), findsOneWidget);
    expect(_inBand('M:low', '75%'), findsOneWidget);
    expect(_inBand('M:low', '3 de 4'), findsOneWidget);
    expect(_inBand('M:low', '1.30'), findsNothing);
    expect(_inBand('M:low', 'sonnet: 3, opus: 1'), findsNothing);
    expect(_inBand('L:high', '40%'), findsOneWidget);
    expect(_inBand('L:high', '2 de 5'), findsOneWidget);
    expect(
      tester.getTopLeft(band).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('metrics-band-L:high'))).dy),
      reason: 'the mock file lists L:high first',
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('metrics-overrides')), matching: find.text('L:high → fable')),
      findsOneWidget,
    );
  });

  testWidgets('the stuck band has the warn bar and the bold label, the others do not', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    final colors = AppColors.dark;
    expect(_barColor(tester, 'L:high'), colors.warn);
    expect(_barColor(tester, 'M:low'), colors.textMuted);
    expect(tester.widget<Text>(_inBand('L:high', 'Grande, risco alto')).style!.fontWeight, FontWeight.w600);
    expect(tester.widget<Text>(_inBand('M:low', 'Média')).style!.fontWeight, isNot(FontWeight.w600));
  });

  testWidgets('the bar is as wide as the share of the band', (tester) async {
    await _open(
      tester,
      '/p/demo-app/metrics',
      inventory: _RoutingInventory(
        Routing(bands: [_band('S', 'low', 4, 4), _band('M', 'low', 1, 2), _band('L', 'low', 0, 3)]),
      ),
    );

    double width(String b) => tester.getSize(find.byKey(ValueKey('metrics-band-bar-$b'))).width;
    expect(width('S:low'), greaterThan(0));
    expect(width('M:low'), closeTo(width('S:low') / 2, 0.01));
    expect(width('L:low'), 0);
    expect(_inBand('M:low', '50%'), findsOneWidget);
    expect(_inBand('L:low', '0 de 3'), findsOneWidget);
  });

  testWidgets('without bands the page asks for /complete', (tester) async {
    await _open(tester, '/p/demo-app/metrics', inventory: const MockInventoryRepository.empty());

    expect(find.text('rode /complete para gerar as faixas'), findsOneWidget);
    expect(find.byKey(const ValueKey('metrics-band-M:low')), findsNothing);
  });

  testWidgets('routing error replaces the table', (tester) async {
    await _open(tester, '/p/demo-app/metrics', inventory: _RoutingInventory(const Routing(error: 'JSON inválido')));

    expect(find.textContaining('JSON inválido'), findsOneWidget);
    expect(find.text('rode /complete para gerar as faixas'), findsNothing);
    expect(find.byKey(const ValueKey('metrics-bands')), findsNothing);
    expect(find.byKey(const ValueKey('metrics-insight')), findsNothing);
  });

  testWidgets('no cycles shows the empty message', (tester) async {
    await _open(tester, '/p/demo-app/metrics', metrics: const MockMetricsRepository.empty());
    expect(_cardValue('completed', '0'), findsOneWidget);
    expect(find.text('nenhum ciclo registrado'), findsNothing);

    await _show(tester, 'cycles');

    expect(find.text('nenhum ciclo registrado'), findsOneWidget);
  });

  testWidgets('/o/x/metrics does not render the MetricsPage', (tester) async {
    await _open(tester, '/o/x/metrics');

    expect(find.byType(MetricsPage), findsNothing);
  });

  testWidgets('"ver relatório" só nos ciclos com relatório e abre o componente em modo leitura', (tester) async {
    await _open(tester, '/p/demo-app/metrics', metrics: await _alphaHistory(tester));
    await _show(tester, 'cycles');
    const withReport = ValueKey('metrics-report-2026-04-02_metricas-alpha');
    expect(find.byKey(withReport), findsOneWidget);
    expect(find.byKey(const ValueKey('metrics-report-2026-03-20_sem-trace-alpha')), findsNothing);

    await tester.tap(find.byKey(withReport));
    await tester.pumpAndSettle();

    final timeline = find.byKey(const ValueKey('metrics-report-timeline'));
    expect(timeline, findsOneWidget);
    expect(find.descendant(of: timeline, matching: find.text('sem relatório desta etapa')), findsNothing);

    await tester.tap(find.descendant(of: timeline, matching: find.text('implement')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: timeline, matching: find.text('T1 e T2 concluídas.', findRichText: true)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: timeline, matching: find.textContaining('Escalada para opus', findRichText: true)),
      findsOneWidget,
    );
    expect(find.descendant(of: timeline, matching: find.text('plan.md')), findsOneWidget);
    expect(find.descendant(of: timeline, matching: find.byType(TextButton)), findsNothing);

    await tester.tap(find.byTooltip('Fechar'));
    await tester.pumpAndSettle();
    expect(timeline, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('o dialog do relatório mostra QA, dados reais e PR do ciclo arquivado', (tester) async {
    await _open(tester, '/p/demo-app/metrics', metrics: await _alphaHistory(tester));
    await _show(tester, 'cycles');

    await tester.tap(find.byKey(const ValueKey('metrics-report-2026-04-02_metricas-alpha')));
    await tester.pumpAndSettle();

    Finder inPanel(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);
    expect(inPanel('flow-qa', find.textContaining('Abrir a página alpha', findRichText: true)), findsOneWidget);
    expect(inPanel('flow-real-data', find.textContaining('dados sintéticos', findRichText: true)), findsOneWidget);
    expect(inPanel('flow-pr', find.text('PR #12')), findsOneWidget);
  });

  testWidgets('1100x700 with five bands and six cycles renders both sections without overflow', (tester) async {
    final cycles = [_tracedCycle(1, 'F' * 80), for (var i = 2; i <= 6; i++) _tracedCycle(i, 'Ciclo $i')];
    await _open(
      tester,
      '/p/demo-app/metrics',
      size: const Size(1100, 700),
      metrics: _FixedMetrics(
        ProjectMetrics(
          cycles: cycles,
          completedCycles: 6,
          tasks: 6,
          passedTier0: 6,
          escalations: 0,
          tokensByRole: const {'dev': 600, 'g0': 0, 'g1': 0, 'g2': 0, 'outros': 0},
          hasTokens: true,
        ),
      ),
      inventory: _RoutingInventory(
        Routing(
          bands: [
            _band('S', 'low', 10, 10),
            _band('M', 'low', 9, 10),
            _band('M', 'high', 4, 5),
            _band('L', 'low', 4, 5),
            _band('L', 'high', 2, 5),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('metrics-insight')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('metrics-bands'))).width, 720);

    await _show(tester, 'cycles');
    await _show(tester, 'tokens');

    final cycle = find.byKey(ValueKey('metrics-cycle-${cycles.first.dir}'));
    await tester.ensureVisible(cycle);
    await tester.pumpAndSettle();
    expect(tester.getSize(cycle).width, greaterThan(720));
    expect(find.byKey(const ValueKey('metrics-card-tokens-dev'), skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Último ciclo no Fluxo sem ciclo ativo', () {
    final lastCycle = find.byKey(const ValueKey('last-cycle'));

    testWidgets('mostra a feature e o PR do ciclo mais recente com relatório e abre o dialog', (tester) async {
      await _open(tester, '/p/web-console/flow', metrics: await _alphaHistory(tester));

      expect(lastCycle, findsOneWidget);
      expect(find.textContaining('Último ciclo: Métricas alpha'), findsOneWidget);
      expect(find.text('ver relatório (PR #12)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('last-cycle-open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('metrics-report-timeline')), findsOneWidget);
      expect(find.byKey(const ValueKey('flow-pr')), findsOneWidget);
    });

    testWidgets('sem histórico com relatório não mostra nada', (tester) async {
      await _open(tester, '/p/web-console/flow', metrics: const MockMetricsRepository.empty());

      expect(lastCycle, findsNothing);
    });

    testWidgets('ignora ciclos arquivados sem relatório', (tester) async {
      await _open(tester, '/p/web-console/flow', metrics: MockMetricsRepository.sample());

      expect(lastCycle, findsNothing);
    });

    testWidgets('com ciclo ativo a linha não aparece', (tester) async {
      await _open(tester, '/p/demo-app/flow', metrics: await _alphaHistory(tester));

      expect(lastCycle, findsNothing);
    });
  });
}
