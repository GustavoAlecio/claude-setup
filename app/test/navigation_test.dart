import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/flow_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/engine/engine_supervisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Widget _app(FlowRepository repository, {EngineController engine = const MockEngineController()}) =>
    ClaudeFlowApp(repository: repository, sessions: MockSessionsRepository(), engine: engine);

class _StoppedEngine extends MockEngineController {
  const _StoppedEngine();

  @override
  Stream<EngineState> watch() => Stream.value(
    EngineState.stopped(
      error: 'engine saiu com código 1: ${'falha ao iniciar o servidor local do engine; ' * 6}',
      stderrTail: const ['Error: listen EADDRINUSE 127.0.0.1:0'],
    ),
  );
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('flow → runs → blocked task shows the ToT diagnosis', (tester) async {
    await tester.pumpWidget(_app(MockFlowRepository()));
    await tester.pumpAndSettle();

    expect(find.text('Favoritos offline'), findsWidgets);
    expect(find.textContaining('T4 bloqueou'), findsOneWidget);

    await tester.tap(find.text('Execuções'));
    await tester.pumpAndSettle();
    expect(find.text('Escada por task'), findsOneWidget);
    expect(find.text('lente: plan'), findsOneWidget);

    final t4 = find.text('Sincronização offline com fila de mutações');
    await tester.ensureVisible(t4);
    await tester.pumpAndSettle();
    await tester.tap(t4);
    await tester.pumpAndSettle();
    expect(find.text('Tentativas'), findsOneWidget);
    expect(find.text('repetido ×3'), findsNWidgets(3));
    expect(find.text('igual à #1'), findsNWidgets(2));
    expect(find.text('→ fable'), findsOneWidget);
  });

  testWidgets('engine footer hugs its content when ok and grows up to its cap on error', (tester) async {
    final footer = find.byKey(const ValueKey('engine-footer'));
    await tester.pumpWidget(_app(MockFlowRepository()));
    await tester.pumpAndSettle();
    final ok = tester.getSize(footer).height;
    expect(find.text('engine ok'), findsOneWidget);
    expect(ok, lessThan(50));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(MockFlowRepository(), engine: const _StoppedEngine()));
    await tester.pumpAndSettle();
    final stopped = tester.getSize(footer).height;
    expect(find.text('engine parado'), findsOneWidget);
    expect(stopped, greaterThan(ok));
    expect(stopped, lessThanOrEqualTo(120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending task row is not navigable', (tester) async {
    await tester.pumpWidget(_app(MockFlowRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Execuções'));
    await tester.pumpAndSettle();

    final t5 = find.text('Tela de favoritos com estado offline');
    await tester.ensureVisible(t5);
    await tester.pumpAndSettle();
    await tester.tap(t5);
    await tester.pumpAndSettle();
    expect(find.text('Escada por task'), findsOneWidget);
  });

  testWidgets('runs: legend stays fixed at the bottom while a long table scrolls inside', (tester) async {
    final tasks = [
      for (var i = 1; i <= 40; i++)
        TaskRun(
          id: 'T$i',
          title: 'Task numero $i',
          complexity: Complexity.m,
          tier0: Tier.sonnet,
          status: Verdict.pending,
        ),
    ];
    final data = [
      Project(
        name: 'longo',
        path: '/dev/longo',
        cycle: Cycle(
          stage: Stage.implement,
          autoMode: false,
          stageMinutes: const {},
          runs: [
            Run(
              id: 'impl-20260311T140000Z',
              kind: 'implement',
              status: Verdict.running,
              startedAt: '14:00',
              tasks: tasks,
            ),
          ],
        ),
      ),
    ];
    await tester.pumpWidget(_app(MockFlowRepository(data: data)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Execuções'));
    await tester.pumpAndSettle();

    final legend = find.text('risco alto');
    expect(legend, findsOneWidget);
    final screenHeight = tester.view.physicalSize.height;
    final before = tester.getTopLeft(legend);
    expect(before.dy, lessThan(screenHeight));
    expect(find.text('Task numero 40'), findsNothing);

    await tester.drag(find.byType(ListView).last, const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(find.text('Task numero 40'), findsOneWidget);
    expect(find.text('Task numero 1'), findsNothing);
    expect(tester.getTopLeft(legend), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Configurações sits outside the shell and Voltar returns to the last project route', (tester) async {
    await tester.pumpWidget(_app(MockFlowRepository()));
    await tester.pumpAndSettle();
    GoRouter router() => GoRouter.of(tester.element(find.byType(Scaffold).first));

    router().go('/p/notifications-api/runs');
    await tester.pumpAndSettle();
    router().go('/settings');
    await tester.pumpAndSettle();
    expect(find.text('Configurações'), findsOneWidget);
    expect(find.text('Execuções'), findsNothing, reason: 'no shell tabs on /settings');

    await tester.tap(find.text('Voltar'));
    await tester.pumpAndSettle();
    expect(router().routerDelegate.currentConfiguration.uri.path, '/p/notifications-api/runs');
  });

  group('two runs in one cycle', () {
    Attempt attempt(int n, Tier tier, Verdict v, {Tier? escalatedTo}) =>
        Attempt(number: n, ordinal: n, tier: tier, gates: [GateResult('g0', v)], escalatedTo: escalatedTo);

    TaskRun task(String id, Verdict status, List<Attempt> attempts, {List<Hypothesis> diagnosis = const []}) => TaskRun(
      id: id,
      title: 'Titulo $id',
      complexity: Complexity.m,
      tier0: Tier.haiku,
      status: status,
      attempts: attempts,
      diagnosis: diagnosis,
    );

    final older = Run(
      id: 'impl-20260310T100000Z',
      kind: 'implement',
      status: Verdict.blocked,
      startedAt: '10/03 10:00',
      tasks: [
        task('T1', Verdict.pass, [attempt(1, Tier.haiku, Verdict.pass)]),
        task(
          'T2',
          Verdict.blocked,
          [attempt(1, Tier.haiku, Verdict.fail), attempt(2, Tier.sonnet, Verdict.fail)],
          diagnosis: const [Hypothesis(lens: 'plan', hypothesis: 'h', confidence: 0.5, evidence: [], action: 'a')],
        ),
        task('T3', Verdict.pending, const []),
      ],
    );
    final newer = Run(
      id: 'impl-20260311T100000Z',
      kind: 'implement',
      status: Verdict.running,
      startedAt: '11/03 10:00',
      tasks: [
        task('T2', Verdict.pass, [attempt(1, Tier.opus, Verdict.pass)]),
        task('T3', Verdict.running, [attempt(1, Tier.haiku, Verdict.running)]),
      ],
    );
    // Cycle.runs is newest first, like the file repository returns it.
    final data = [
      Project(
        name: 'duplo',
        path: '/dev/duplo',
        cycle: Cycle(
          stage: Stage.implement,
          autoMode: false,
          stageMinutes: const {},
          runs: [newer, older],
          plan: [
            for (final id in ['T1', 'T2', 'T3'])
              TaskRun(
                id: id,
                title: 'Titulo $id',
                complexity: Complexity.m,
                tier0: Tier.haiku,
                status: Verdict.pending,
              ),
          ],
        ),
      ),
    ];

    String location(WidgetTester tester) =>
        GoRouter.of(tester.element(find.byType(Scaffold).first)).routeInformationProvider.value.uri.path;

    Future<void> openRuns(WidgetTester tester) async {
      await tester.pumpWidget(_app(MockFlowRepository(data: data)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Execuções'));
      await tester.pumpAndSettle();
    }

    testWidgets('by-run sections are chronological, each with only its own tasks', (tester) async {
      await openRuns(tester);

      final first = tester.getTopLeft(find.text('impl-20260310T100000Z'));
      final second = tester.getTopLeft(find.text('impl-20260311T100000Z'));
      expect(first.dy, lessThan(second.dy));
      expect(find.text('Titulo T1'), findsOneWidget);
      expect(find.text('Titulo T2'), findsNWidgets(2));
      expect(find.text('Titulo T3'), findsNWidgets(2));
      expect(find.text('Titulo T1').evaluate().length, 1);
      expect(tester.getTopLeft(find.text('Titulo T1')).dy, lessThan(second.dy));
      expect(
        find.text('lente: plan'),
        findsNothing,
        reason: 'T2 blocked in the older run was resolved by the newer one',
      );
    });

    testWidgets('by-run row opens the task in its own run and sections collapse', (tester) async {
      await openRuns(tester);

      await tester.tap(find.text('Titulo T2').first);
      await tester.pumpAndSettle();
      expect(location(tester), '/p/duplo/runs/impl-20260310T100000Z/T2');

      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/duplo/runs');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Titulo T2').last);
      await tester.pumpAndSettle();
      expect(location(tester), '/p/duplo/runs/impl-20260311T100000Z/T2');

      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/duplo/runs');
      await tester.pumpAndSettle();
      await tester.tap(find.text('impl-20260310T100000Z'));
      await tester.pumpAndSettle();
      expect(find.text('Titulo T1'), findsNothing);
      expect(find.text('Titulo T2'), findsOneWidget);
    });

    testWidgets('cycle mode: one row per task in plan order with attempts of all runs', (tester) async {
      await openRuns(tester);
      await tester.tap(find.text('Ciclo'));
      await tester.pumpAndSettle();

      for (final id in ['T1', 'T2', 'T3']) {
        expect(find.text('Titulo $id'), findsOneWidget);
      }
      expect(tester.getTopLeft(find.text('Titulo T1')).dy, lessThan(tester.getTopLeft(find.text('Titulo T2')).dy));
      expect(tester.getTopLeft(find.text('Titulo T2')).dy, lessThan(tester.getTopLeft(find.text('Titulo T3')).dy));
      expect(find.byTooltip('R1 #1 haiku fail  →  R1 #2 sonnet fail  →  R2 #1 opus pass'), findsOneWidget);
      expect(find.byTooltip('#1 haiku pass'), findsOneWidget);
      expect(find.byTooltip('R2 #1 haiku running'), findsNothing, reason: 'T3 ran in a single run, no run prefix');
      expect(find.byTooltip('#1 haiku running'), findsOneWidget);

      await tester.tap(find.text('Titulo T2'));
      await tester.pumpAndSettle();
      expect(location(tester), '/p/duplo/runs/impl-20260311T100000Z/T2');
    });
  });
}
