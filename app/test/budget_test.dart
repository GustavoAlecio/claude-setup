import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/budget.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

SessionSummary _session(String id, String createdAt, double cost, {String project = 'p', String? org}) =>
    SessionSummary(
      id: id,
      project: project,
      command: 'x',
      title: id,
      status: SessionStatus.done,
      createdAt: createdAt,
      cost: cost,
      org: org,
    );

final _cycle = Cycle(
  stage: Stage.implement,
  runs: const [],
  stageMinutes: const {},
  startedAt: DateTime.utc(2026, 10, 1),
);

void main() {
  test('cycleCost counts only the project sessions created since the cycle began', () {
    final sessions = [
      _session('before', '2026-09-30T23:00:00Z', 9),
      _session('a', '2026-10-01T00:00:00Z', 1.5),
      _session('b', '2026-10-03T10:00:00Z', 2),
      _session('other', '2026-10-03T10:00:00Z', 5, project: 'q'),
      _session('org', '2026-10-03T10:00:00Z', 5, project: '', org: 'o'),
    ];
    expect(cycleCost(_cycle, 'p', sessions), 3.5);
    expect(
      cycleCost(const Cycle(stage: Stage.plan, runs: [], stageMinutes: {}), 'p', sessions),
      0,
      reason: 'no start date: nothing is blamed on the cycle',
    );
  });

  test('cycleCost also counts the sessions the report names, even created before the cycle or under another name', () {
    final cycle = Cycle(
      stage: Stage.specify,
      runs: const [],
      stageMinutes: const {},
      startedAt: DateTime.utc(2026, 10, 1),
      report: const ReportDoc(
        feature: null,
        startedAt: null,
        stages: [StageReport(stage: Stage.kickoff, status: ReportStatus.done, sessionId: 'conversa')],
      ),
    );
    final sessions = [
      _session('conversa', '2026-09-30T23:00:00Z', 4, project: 'outro-nome'),
      _session('before', '2026-09-30T23:00:00Z', 9),
      _session('a', '2026-10-01T00:00:00Z', 1.5),
    ];
    expect(cycleCost(cycle, 'p', sessions), 5.5);
  });

  test('budget: org overrides global; near from 80%, over at 100%', () {
    const config = DashboardConfig(
      cycleBudget: 10,
      orgs: [OrgConfig(name: 'cheap', cycleBudget: 2), OrgConfig(name: 'inherits')],
    );
    expect(cycleBudgetFor('cheap', config), 2);
    expect(cycleBudgetFor('inherits', config), 10);
    expect(cycleBudgetFor(null, const DashboardConfig()), isNull);
    expect(budgetState(1, null), BudgetState.none);
    expect(budgetState(7.9, 10), BudgetState.ok);
    expect(budgetState(8, 10), BudgetState.near);
    expect(budgetState(10, 10), BudgetState.over);
    expect(parseBudget(0), isNull);
    expect(parseBudget('5'), isNull);
    expect(parseBudget(7.5), 7.5);
  });

  testWidgets('the Fluxo shows the cycle cost against the budget and warns once it is passed', (tester) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sessions = MockSessionsRepository()
      ..addSession(_session('s1', '2026-10-02T10:00:00Z', 6), const [])
      ..addSession(_session('s2', '2026-10-02T11:00:00Z', 0), const []);
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(
          data: [Project(name: 'p', path: '/dev/p', cycle: _cycle)],
          config: {
            'cycleBudget': 5,
            'orgs': [
              {
                'name': 'o',
                'roots': ['/dev'],
              },
            ],
            'lastOrg': 'o',
          },
        ),
        sessions: sessions,
        engine: const MockEngineController(),
      ),
    );
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/p/flow');
    await tester.pumpAndSettle();

    expect(find.text('O ciclo passou do orçamento: \$6.00 de \$5.00.'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('flow-cycle-cost')), matching: find.text('\$6.00 de \$5.00')),
      findsOneWidget,
    );
  });
}
