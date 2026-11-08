import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/data/workflow_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Cycle _cycle({DateTime? pausedAt}) =>
    Cycle(stage: Stage.implement, runs: const [], stageMinutes: const {}, feature: 'Favoritos', pausedAt: pausedAt);

Future<MockSessionsRepository> _open(WidgetTester tester, Cycle cycle) async {
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = MockSessionsRepository();
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(
        data: [Project(name: 'p', path: '/dev/p', cycle: cycle)],
      ),
      sessions: sessions,
      engine: const MockEngineController(),
    ),
  );
  await tester.pumpAndSettle();
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/p/flow');
  await tester.pumpAndSettle();
  return sessions;
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

  testWidgets('a paused cycle shows the banner; Retomar resumes and opens the palette', (tester) async {
    final sessions = await _open(tester, _cycle(pausedAt: DateTime.utc(2026, 10, 5)));

    expect(find.byKey(const ValueKey('flow-paused-banner')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('flow-resume-cycle')));
    await tester.pumpAndSettle();
    expect(sessions.cycleCalls, [('p', CycleAction.resume)]);
    expect(find.text('Executar skill em p…'), findsOneWidget);
  });
}
