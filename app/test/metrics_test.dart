import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/inventory_models.dart';
import 'package:claude_flow/data/inventory_repository.dart';
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

Future<GoRouter> _open(
  WidgetTester tester,
  String location, {
  MetricsRepository? metrics,
  InventoryRepository? inventory,
}) async {
  tester.view.physicalSize = const Size(1600, 1400);
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

final _cycleTitle = find.descendant(
  of: find.byKey(const ValueKey('metrics-cycle-2026-04-20_metricas')),
  matching: find.text('Métricas'),
);

void main() {
  testWidgets('cards show the fixed values of the mock sample', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    expect(find.byType(MetricsPage), findsOneWidget);
    expect(_cardValue('completed', '3'), findsOneWidget);
    expect(_cardValue('tasks', '5'), findsOneWidget);
    expect(_cardValue('pass-tier0', '80%'), findsOneWidget);
    expect(_cardValue('escalations', '1'), findsOneWidget);
    expect(_cardValue('tokens-dev', '870'), findsOneWidget);
    expect(_cardValue('tokens-g0', '0'), findsOneWidget);
    expect(_cardValue('tokens-g1', '310'), findsOneWidget);
    expect(_cardValue('tokens-g2', '30'), findsOneWidget);
  });

  testWidgets('cycles are ordered current first, then date and persisted_at desc, no-trace last', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    const order = ['ciclo-atual', '2026-04-20_metricas', '2026-04-20_adrs', '2026-04-10_sem-trace'];
    final tops = [for (final dir in order) tester.getTopLeft(find.byKey(ValueKey('metrics-cycle-$dir'))).dy];
    expect(tops, [...tops]..sort());
    expect(find.text('em andamento'), findsOneWidget);
    expect(find.textContaining('sem trace'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('expanding a cycle mounts its tasks with tier0 to final tier', (tester) async {
    await _open(tester, '/p/demo-app/metrics');
    const task = ValueKey('metrics-task-2026-04-20_metricas-T1');
    expect(find.byKey(task), findsNothing);

    await tester.tap(_cycleTitle);
    await tester.pumpAndSettle();

    final row = find.byKey(task);
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('sonnet')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('opus')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('2 tentativa(s)')), findsOneWidget);
    expect(find.byKey(const ValueKey('metrics-task-2026-04-20_metricas-T2')), findsOneWidget);

    await tester.tap(_cycleTitle);
    await tester.pumpAndSettle();
    expect(find.byKey(task), findsNothing);
  });

  testWidgets('bands table and overrides come from the routing', (tester) async {
    await _open(tester, '/p/demo-app/metrics');

    final band = find.byKey(const ValueKey('metrics-band-M:low'));
    expect(band, findsOneWidget);
    expect(find.descendant(of: band, matching: find.text('3/4 (75%)')), findsOneWidget);
    expect(find.descendant(of: band, matching: find.text('1.30')), findsOneWidget);
    expect(find.descendant(of: band, matching: find.text('sonnet: 3, opus: 1')), findsOneWidget);
    expect(find.text('L:high → fable'), findsOneWidget);
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
  });

  testWidgets('no cycles shows the empty message', (tester) async {
    await _open(tester, '/p/demo-app/metrics', metrics: const MockMetricsRepository.empty());

    expect(find.text('nenhum ciclo registrado'), findsOneWidget);
    expect(_cardValue('completed', '0'), findsOneWidget);
  });

  testWidgets('/o/x/metrics does not render the MetricsPage', (tester) async {
    await _open(tester, '/o/x/metrics');

    expect(find.byType(MetricsPage), findsNothing);
  });
}
