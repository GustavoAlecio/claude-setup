import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/data/workflow_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Cycle _cycle({DateTime? pausedAt}) =>
    Cycle(stage: Stage.implement, runs: const [], stageMinutes: const {}, feature: 'Favoritos', pausedAt: pausedAt);

Future<MockSessionsRepository> _open(
  WidgetTester tester,
  Cycle cycle, {
  List<SessionSummary> sessions = const [],
  Map<String, Object?>? config,
}) async {
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = MockSessionsRepository();
  for (final s in sessions) {
    repository.addSession(s, const []);
  }
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(
        data: [Project(name: 'p', path: '/dev/p', cycle: cycle)],
        config: config,
      ),
      sessions: repository,
      engine: const MockEngineController(),
    ),
  );
  await tester.pumpAndSettle();
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/p/flow');
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  test('parseCycle reads paused and paused_at; a paused cycle asks for no decision', () {
    final paused = parseCycle({
      'status': 'implementing',
      'paused': true,
      'paused_at': '2026-10-05T10:00:00Z',
    }, projectName: 'p');
    expect(paused.pausedAt, DateTime.utc(2026, 10, 5, 10));
    expect(parseCycle({'status': 'implementing', 'paused': true}, projectName: 'p').paused, isTrue);
    expect(parseCycle({'status': 'implementing'}, projectName: 'p').paused, isFalse);
    expect(
      blockedDecision(
        Project(
          name: 'p',
          cycle: _cycle(pausedAt: DateTime.utc(2026)),
        ),
      ),
      isNull,
    );
  });

  testWidgets('the cycle menu pauses, and archiving asks first', (tester) async {
    final sessions = await _open(tester, _cycle());

    await tester.tap(find.byKey(const ValueKey('flow-cycle-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pausar ciclo'));
    await tester.pumpAndSettle();
    expect(sessions.cycleCalls, [('p', CycleAction.pause)]);

    await tester.tap(find.byKey(const ValueKey('flow-cycle-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arquivar como abandonado'));
    await tester.pumpAndSettle();
    expect(find.text('Arquivar «Favoritos» como abandonado?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(sessions.cycleCalls, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('flow-cycle-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arquivar como abandonado'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Arquivar'));
    await tester.pumpAndSettle();
    expect(sessions.cycleCalls.last, ('p', CycleAction.archive));
  });

  testWidgets('a paused cycle says so in the cycle card; Retomar resumes and opens the palette', (tester) async {
    final sessions = await _open(tester, _cycle(pausedAt: DateTime.utc(2026, 10, 5, 12)));

    final now = find.byKey(const ValueKey('cycle-now'));
    final action = find.byKey(const ValueKey('cycle-now-action'));
    expect(find.descendant(of: now, matching: find.text('Ciclo pausado')), findsOneWidget);
    expect(find.descendant(of: now, matching: find.text('Pausado na etapa implement')), findsOneWidget);
    expect(find.descendant(of: now, matching: find.textContaining('desde 05/10')), findsOneWidget);
    expect(tester.widget(action), isA<OutlinedButton>());

    await tester.tap(find.descendant(of: action, matching: find.text('Retomar')));
    await tester.pumpAndSettle();
    expect(sessions.cycleCalls, [('p', CycleAction.resume)]);
    expect(find.text('Executar skill em p…'), findsOneWidget);
  });

  testWidgets('a paused cycle over its budget shows no budget banner', (tester) async {
    final started = DateTime.utc(2026, 10, 1);
    Cycle cycle({DateTime? pausedAt}) =>
        Cycle(stage: Stage.implement, runs: const [], stageMinutes: const {}, startedAt: started, pausedAt: pausedAt);
    const spent = SessionSummary(
      id: 's1',
      project: 'p',
      command: 'x',
      title: 's1',
      status: SessionStatus.done,
      createdAt: '2026-10-02T10:00:00Z',
      cost: 6,
    );
    const config = {'cycleBudget': 5};
    final banner = find.byKey(const ValueKey('flow-budget-banner'));

    await _open(tester, cycle(), sessions: [spent], config: config);
    expect(banner, findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _open(
      tester,
      cycle(pausedAt: DateTime.utc(2026, 10, 5, 12)),
      sessions: [spent],
      config: config,
    );
    expect(find.text('Ciclo pausado'), findsOneWidget);
    expect(banner, findsNothing);
  });
}
