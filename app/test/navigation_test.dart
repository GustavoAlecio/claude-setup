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

String _route(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first)).routerDelegate.currentConfiguration.uri.path;

Text _onlyText(WidgetTester tester, String key) =>
    tester.widget<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)));

FontWeight? _weight(WidgetTester tester, String key) => _onlyText(tester, key).style!.fontWeight;

String? _label(WidgetTester tester, String key) => _onlyText(tester, key).data;

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
    // The run summary lives in the cycle details, collapsed under the footer.
    expect(find.textContaining('T4 bloqueou'), findsNothing);
    final details = find.byKey(const ValueKey('cycle-details-toggle'));
    await tester.ensureVisible(details);
    await tester.pumpAndSettle();
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.textContaining('T4 bloqueou'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('subtab-runs')));
    await tester.pumpAndSettle();
    expect(find.text('Escada por task'), findsOneWidget);
    expect(find.text('ângulo: plan'), findsOneWidget);

    final t4 = find.text('Sincronização offline com fila de mutações');
    await tester.ensureVisible(t4);
    await tester.pumpAndSettle();
    await tester.tap(t4);
    await tester.pumpAndSettle();
    expect(find.text('O que aconteceu'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-decide')), findsOneWidget);
    expect(find.textContaining('mesma falha da tentativa 1'), findsNWidgets(2));
    expect(find.textContaining('opus → fable'), findsOneWidget);
    expect(_route(tester), startsWith('/p/demo-app/runs/'));
    expect(
      find.descendant(of: find.byKey(const ValueKey('task-back')), matching: find.text('Execuções')),
      findsOneWidget,
    );
    expect(_weight(tester, 'group-cycle'), FontWeight.w600);
    expect(_weight(tester, 'subtab-runs'), FontWeight.w600);
    expect(_weight(tester, 'subtab-flow'), FontWeight.w400);
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

  testWidgets('the autopilot shows the real flag; turning it on asks first, turning it off does not', (tester) async {
    final repo = MockFlowRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    Finder pill(String label) =>
        find.descendant(of: find.byKey(const ValueKey('auto-mode')), matching: find.text(label));
    expect(pill('off'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auto-mode')));
    await tester.pumpAndSettle();
    expect(find.text('Ligar o piloto automático?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(repo.autoMode, isFalse);

    await tester.tap(find.byKey(const ValueKey('auto-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ligar'));
    await tester.pumpAndSettle();
    expect(repo.autoMode, isTrue);
    expect(pill('on'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auto-mode')));
    await tester.pumpAndSettle();
    expect(find.text('Ligar o piloto automático?'), findsNothing);
    expect(repo.autoMode, isFalse);
  });

  testWidgets('a blocked task takes the cycle card, whose Decidir opens the diagnosis', (tester) async {
    await tester.pumpWidget(_app(MockFlowRepository()));
    await tester.pumpAndSettle();

    final now = find.byKey(const ValueKey('cycle-now'));
    final action = find.byKey(const ValueKey('cycle-now-action'));
    expect(find.descendant(of: now, matching: find.text('Precisa de você')), findsOneWidget);
    expect(find.descendant(of: now, matching: find.text('A task T4 travou')), findsOneWidget);
    expect(tester.widget(action), isA<FilledButton>());
    expect(find.descendant(of: action, matching: find.text('Decidir')), findsOneWidget);
    expect(find.text('Decidir'), findsOneWidget);
    expect(find.byKey(const ValueKey('cycle-tasks')), findsOneWidget);

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(_route(tester), matches(RegExp(r'^/p/demo-app/runs/[^/]+/T4$')));
    expect(find.byKey(const ValueKey('task-decide')), findsOneWidget);
    expect(now, findsNothing);

    final back = find.byKey(const ValueKey('task-back'));
    expect(find.descendant(of: back, matching: find.text('Ciclo')), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(_route(tester), '/p/demo-app/flow');
  });

  testWidgets('pending task row is not navigable', (tester) async {
    await tester.pumpWidget(_app(MockFlowRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('subtab-runs')));
    await tester.pumpAndSettle();

    final t5 = find.text('Tela de favoritos com estado offline');
    await tester.scrollUntilVisible(t5, 200, scrollable: find.byType(Scrollable).last);
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
    await tester.tap(find.byKey(const ValueKey('subtab-runs')));
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

  group('project header', () {
    const groups = ['group-cycle', 'group-talks', 'group-prs', 'group-reference'];

    testWidgets('four groups in order and the cycle sub-tabs on the Fluxo', (tester) async {
      await tester.pumpWidget(_app(MockFlowRepository()));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/flow');

      final xs = [for (final k in groups) tester.getTopLeft(find.byKey(ValueKey(k))).dx];
      expect([...xs]..sort(), xs);
      expect([for (final k in groups) _label(tester, k)], ['Ciclo', 'Conversas', 'PRs', 'Referência']);
      expect(
        find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('group-'),
        ),
        findsNWidgets(4),
      );

      for (final old in ['Sessões', 'Artefatos', 'Reviews', 'Métricas', 'ADRs']) {
        expect(find.text(old), findsNothing, reason: old);
      }
      expect(find.text('Execuções'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('subtabs')), matching: find.text('Execuções')),
        findsOneWidget,
      );

      expect(_weight(tester, 'group-cycle'), FontWeight.w600);
      for (final k in groups.skip(1)) {
        expect(_weight(tester, k), FontWeight.w400, reason: k);
      }
      expect(_weight(tester, 'subtab-flow'), FontWeight.w600);
      expect(_weight(tester, 'subtab-runs'), FontWeight.w400);

      await tester.tap(find.byKey(const ValueKey('subtab-runs')));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/runs');
      expect(find.text('Escada por task'), findsOneWidget);
      expect(_weight(tester, 'subtab-runs'), FontWeight.w600);
    });

    testWidgets('each group opens its first tab with its own sub-tabs', (tester) async {
      await tester.pumpWidget(_app(MockFlowRepository()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('group-talks')));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/sessions');
      expect(find.byKey(const ValueKey('subtabs')), findsNothing);
      expect(_weight(tester, 'group-talks'), FontWeight.w600);

      await tester.tap(find.byKey(const ValueKey('group-prs')));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/prs');
      expect(find.text('nenhum PR registrado; abra com /pr-open'), findsOneWidget);
      expect(find.byKey(const ValueKey('subtabs')), findsNothing);

      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/demo-app/reviews?pr=157');
      await tester.pumpAndSettle();
      expect(_weight(tester, 'group-prs'), FontWeight.w600);
      expect(find.byKey(const ValueKey('subtabs')), findsNothing);
      expect(find.byKey(const ValueKey('reviews-back')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reviews-back')));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/prs');

      await tester.tap(find.byKey(const ValueKey('group-reference')));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/artifacts');
      expect(find.text('nenhum artefato'), findsOneWidget);
      expect(_label(tester, 'subtab-artifacts'), 'Documentos');
      expect(find.byKey(const ValueKey('subtab-adrs')), findsOneWidget);
      expect(_label(tester, 'subtab-metrics'), 'Números');

      await tester.tap(find.byKey(const ValueKey('subtab-metrics')));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/metrics');
      expect(find.byKey(const ValueKey('metrics-show-cycles')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('subtab-adrs')));
      await tester.pumpAndSettle();
      expect(_route(tester), '/p/demo-app/adrs');
      expect(find.text('este projeto não tem ADRs'), findsOneWidget);
      expect(_weight(tester, 'group-reference'), FontWeight.w600);
    });

    testWidgets('queue stays in the cycle group with the Fluxo sub-tab', (tester) async {
      await tester.pumpWidget(_app(MockFlowRepository()));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/demo-app/queue');
      await tester.pumpAndSettle();
      expect(_weight(tester, 'group-cycle'), FontWeight.w600);
      expect(_weight(tester, 'subtab-flow'), FontWeight.w600);
      expect(_weight(tester, 'subtab-runs'), FontWeight.w400);
    });
  });

  group('org tabs', () {
    testWidgets('the org keeps its three tabs, without groups nor sub-tabs', (tester) async {
      await tester.pumpWidget(_app(MockFlowRepository()));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/o/demo/fila');
      await tester.pumpAndSettle();

      for (final label in ['Caixa de entrada', 'Para revisar', 'Sessões']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.byKey(const ValueKey('subtabs')), findsNothing);
      for (final g in ['group-cycle', 'group-talks', 'group-prs', 'group-reference']) {
        expect(find.byKey(ValueKey(g)), findsNothing, reason: g);
      }

      // The sidebar repeats "Para revisar"; the header tab is the one right of it.
      final tab = find.text('Para revisar').last;
      expect(tester.getTopLeft(tab).dx, greaterThan(tester.getSize(find.byKey(const ValueKey('sidebar'))).width));
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(_route(tester), '/o/demo/revisar');
      expect(find.text('nenhum PR esperando sua revisão'), findsOneWidget);
    });
  });

  testWidgets('the sidebar home reaches the org review tab', (tester) async {
    await tester.pumpWidget(_app(MockFlowRepository()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sidebar-home')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Para revisar'));
    await tester.pumpAndSettle();
    expect(find.text('nenhum PR esperando sua revisão'), findsOneWidget);
    expect(
      GoRouter.of(tester.element(find.byType(Scaffold).first)).routerDelegate.currentConfiguration.uri.toString(),
      '/o/demo/revisar',
    );
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
        GoRouter.of(tester.element(find.byType(Scaffold).first)).routeInformationProvider.value.uri.toString();

    Future<void> openRuns(WidgetTester tester) async {
      await tester.pumpWidget(_app(MockFlowRepository(data: data)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('subtab-runs')));
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
        find.text('ângulo: plan'),
        findsNothing,
        reason: 'T2 blocked in the older run was resolved by the newer one',
      );
    });

    testWidgets('by-run row opens the task in its own run and sections collapse', (tester) async {
      await openRuns(tester);

      await tester.tap(find.text('Titulo T2').first);
      await tester.pumpAndSettle();
      expect(location(tester), '/p/duplo/runs/impl-20260310T100000Z/T2?from=runs');

      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/duplo/runs');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Titulo T2').last);
      await tester.pumpAndSettle();
      expect(location(tester), '/p/duplo/runs/impl-20260311T100000Z/T2?from=runs');

      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/duplo/runs');
      await tester.pumpAndSettle();
      await tester.tap(find.text('impl-20260310T100000Z'));
      await tester.pumpAndSettle();
      expect(find.text('Titulo T1'), findsNothing);
      expect(find.text('Titulo T2'), findsOneWidget);
    });

    testWidgets('cycle mode: one row per task in plan order with attempts of all runs', (tester) async {
      await openRuns(tester);
      // "Ciclo" is also the header group; the runs mode toggle comes after it in the tree.
      await tester.tap(find.text('Ciclo').last);
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
      expect(location(tester), '/p/duplo/runs/impl-20260311T100000Z/T2?from=runs');
    });
  });
}
