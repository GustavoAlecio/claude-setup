import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/features/sessions/session_events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _project = 'gate-app';

class _Sessions extends MockSessionsRepository {
  _Sessions(this.list, this.details);

  final List<SessionSummary> list;
  final Map<String, List<SessionEvent>> details;
  final answerCalls = <(String id, String requestId, PermissionDecision decision, Map<String, String>? answers)>[];

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.value(list);

  @override
  Stream<SessionDetail> watchSession(String id) {
    final summary = list.firstWhere((s) => s.id == id);
    return Stream.value(SessionDetail(summary: summary, events: details[id] ?? const []));
  }

  @override
  Future<void> answer(String id, String requestId, PermissionDecision decision, {Map<String, String>? answers}) async =>
      answerCalls.add((id, requestId, decision, answers));
}

/// Not a pipeline skill by default: such a session never becomes the side panel's session, so its question stays in
/// the card.
SessionSummary _session(
  String id, {
  String command = 'revise o PR',
  String project = _project,
  SessionStatus status = SessionStatus.waitingPermission,
  int pending = 1,
  String createdAt = '2026-03-10T10:00:00Z',
  String? org,
}) => SessionSummary(
  id: id,
  project: project,
  command: command,
  title: 'sessão $id',
  status: status,
  createdAt: createdAt,
  pendingPermissions: pending,
  org: org,
);

const _gate = 'Aprovar a spec?';

QuestionRequest _question(String requestId, {String question = _gate}) => QuestionRequest(
  '2026-03-10T10:05:00Z',
  requestId: requestId,
  seq: 3,
  questions: [
    Question(
      question: question,
      header: 'spec',
      options: const [
        QuestionOption('Aprovar (Recommended)', 'segue para o /plan'),
        QuestionOption('Ajustar', 'descreva o ajuste em Outro'),
        QuestionOption('Rejeitar', 'encerra a etapa'),
      ],
    ),
  ],
);

ReportDoc _report(List<Map<String, Object?>> stages) => parseReport(
  jsonEncode({
    'version': 1,
    'cycle': {'feature': 'Gates'},
    'stages': stages,
  }),
)!;

Project _withCycle({ReportDoc? report}) => Project(
  name: _project,
  path: '/synthetic/$_project',
  cycle: Cycle(stage: Stage.challenge, stageMinutes: const {}, runs: const [], report: report),
);

const _noCycle = Project(name: _project, path: '/synthetic/$_project');

Future<_Sessions> _open(
  WidgetTester tester,
  Project project,
  List<SessionSummary> list, {
  Map<String, List<SessionEvent>> details = const {},
  bool settle = true,
  Size size = const Size(1600, 3200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = _Sessions(list, details);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: [project]),
      sessions: sessions,
      engine: const MockEngineController(),
    ),
  );
  await tester.pump();
  _router(tester).go('/p/$_project/flow');
  // A running session's typing indicator never settles.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return sessions;
}

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.toString();

final _card = find.byKey(const ValueKey('flow-awaiting'));

final _side = find.byKey(const ValueKey('flow-side-panel'));

Finder _inCard(Finder matching) => find.descendant(of: _card, matching: matching);

const _gamma = 'gamma';

/// The shell's sidebar, beside the Fluxo.
const _sidebar = 232.0;

/// The gamma fixture (`plan` and `spec` open, `tasks` passed) with the plan stage run by `s-plan` and the challenge
/// stage by `s-spec`.
/// [answered] records an answer on every plan question while the gate stays `open`, as the skill does mid-write.
Project _gammaProject({bool current = true, bool answered = false}) {
  final doc = jsonDecode(File('test/fixtures/workflow/gamma/report.json').readAsStringSync()) as Map<String, dynamic>;
  final stages = (doc['stages'] as List).cast<Map<String, dynamic>>();
  final plan = stages.firstWhere((s) => s['stage'] == 'plan');
  plan['session_id'] = 's-plan';
  if (answered) {
    for (final q in ((plan['gate'] as Map<String, dynamic>)['questions'] as List).cast<Map<String, dynamic>>()) {
      q['answer'] = ((q['options'] as List).first as Map<String, dynamic>)['id'];
    }
  }
  stages.firstWhere((s) => s['stage'] == 'challenge')['session_id'] = 's-spec';
  return Project(
    name: _gamma,
    path: '/synthetic/$_gamma',
    cycle: Cycle(
      stage: Stage.plan,
      stageMinutes: const {},
      runs: const [],
      report: parseReport(jsonEncode(doc)),
      reportIsCurrent: current,
    ),
  );
}

/// The request `wf-report.py show plan` makes the skill ask for the gamma fixture.
QuestionRequest _planRequest() {
  final show = jsonDecode(File('test/fixtures/show/gamma-plan.json').readAsStringSync()) as Map<String, dynamic>;
  return QuestionRequest(
    '2026-03-10T10:05:00Z',
    requestId: 'rq-plan',
    seq: 5,
    questions: [
      for (final q in (show['questions'] as List).cast<Map<String, dynamic>>())
        Question(
          question: q['question'] as String,
          header: q['header'] as String,
          options: [
            for (final o in (q['options'] as List).cast<Map<String, dynamic>>())
              QuestionOption(o['label'] as String, o['description'] as String),
          ],
        ),
    ],
  );
}

Future<void> _openGamma(
  WidgetTester tester, {
  Size size = const Size(1400, 1400),
  bool current = true,
  bool withSpec = false,
  bool withOther = false,
  bool answered = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = _Sessions(
    [
      _session('s-plan', command: '/plan', project: _gamma),
      if (withSpec) _session('s-spec', project: _gamma, createdAt: '2026-03-10T09:00:00Z'),
      if (withOther) _session('s-rev', project: _gamma, createdAt: '2026-03-10T08:00:00Z'),
    ],
    {
      's-plan': [_planRequest()],
      's-spec': [_question('q-spec')],
      's-rev': [_question('q-rev', question: 'Pergunta do review?')],
    },
  );
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(
        data: [_gammaProject(current: current, answered: answered)],
      ),
      sessions: sessions,
      engine: const MockEngineController(),
    ),
  );
  await tester.pump();
  _router(tester).go('/p/$_gamma/flow');
  await tester.pumpAndSettle();
}

Finder _byKey(String key) => find.byKey(ValueKey(key));

/// Below the split width the side panel lives in the drawer.
Future<void> _revealSide(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('flow-drawer-toggle'));
  if (toggle.evaluate().isEmpty) return;
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

const _delta = 'delta';

/// The delta fixture (`pr` on the complete stage, run by `s-complete`) with gamma's tasks stage, run by `s-tasks`,
/// whose gate is [tasks]; the `pr` gate is [pr].
Project _deltaProject({required String tasks, required String pr}) {
  Map<String, dynamic> read(String name) =>
      jsonDecode(File('test/fixtures/workflow/$name/report.json').readAsStringSync()) as Map<String, dynamic>;
  final doc = read(_delta);
  final tasksStage = (read(_gamma)['stages'] as List).cast<Map<String, dynamic>>().firstWhere(
    (s) => s['stage'] == 'tasks',
  );
  tasksStage['session_id'] = 's-tasks';
  (tasksStage['gate'] as Map<String, dynamic>)['status'] = tasks;
  final stages = (doc['stages'] as List).cast<Map<String, dynamic>>();
  (stages.firstWhere((s) => s['stage'] == 'complete')['gate'] as Map<String, dynamic>)['status'] = pr;
  doc['stages'] = [tasksStage, ...stages];
  return Project(
    name: _delta,
    path: '/synthetic/$_delta',
    cycle: Cycle(
      stage: Stage.complete,
      stageMinutes: const {},
      runs: const [],
      report: parseReport(jsonEncode(doc)),
      reportIsCurrent: true,
    ),
  );
}

/// The request `wf-report.py show pr` makes the skill ask for the delta fixture.
QuestionRequest _prRequest() {
  final show = jsonDecode(File('test/fixtures/show/delta-pr.json').readAsStringSync()) as Map<String, dynamic>;
  return QuestionRequest(
    '2026-03-12T10:05:00Z',
    requestId: 'rq-pr',
    seq: 7,
    questions: [
      for (final q in (show['questions'] as List).cast<Map<String, dynamic>>())
        Question(
          question: q['question'] as String,
          header: q['header'] as String,
          options: [
            for (final o in (q['options'] as List).cast<Map<String, dynamic>>())
              QuestionOption(o['label'] as String, o['description'] as String),
          ],
        ),
    ],
  );
}

Future<void> _openDelta(WidgetTester tester, {required String tasks, required String pr, String? stage}) async {
  tester.view.physicalSize = const Size(1400 + _sidebar, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = _Sessions(
    [
      _session('s-complete', command: '/complete', project: _delta),
      _session('s-tasks', command: '/tasks', project: _delta, status: SessionStatus.done, pending: 0),
      _session('s-rev', project: _delta, createdAt: '2026-03-10T08:00:00Z'),
    ],
    {
      's-complete': [_prRequest()],
      's-rev': [_question('q-rev', question: 'Pergunta do review?')],
    },
  );
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(
        data: [_deltaProject(tasks: tasks, pr: pr)],
      ),
      sessions: sessions,
      engine: const MockEngineController(),
    ),
  );
  await tester.pump();
  _router(tester).go(stage == null ? '/p/$_delta/flow' : '/p/$_delta/flow?stage=$stage');
  await tester.pumpAndSettle();
}

void main() {
  group('card Aguardando você', () {
    testWidgets('pergunta pendente da sessão do projeto vira card; Aprovar responde pelo answer', (tester) async {
      final sessions = await _open(
        tester,
        _withCycle(),
        [_session('s1'), _session('s-stage', command: '/challenge-spec', status: SessionStatus.idle, pending: 0)],
        details: {
          's1': [_question('q-1')],
        },
      );

      expect(_inCard(find.text('Aguardando você')), findsOneWidget);
      expect(_inCard(find.text(_gate)), findsOneWidget);
      expect(find.descendant(of: _side, matching: _card), findsOneWidget);
      expect(tester.getTopLeft(_card).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('session-feed'))).dy));

      await tester.tap(_inCard(find.text('Aprovar (Recommended)')));
      await tester.pumpAndSettle();
      await tester.tap(_inCard(find.text('Responder')));
      await tester.pumpAndSettle();

      expect(sessions.answerCalls, hasLength(1));
      final (id, requestId, decision, answers) = sessions.answerCalls.single;
      expect((id, requestId, decision), ('s1', 'q-1', PermissionDecision.answer));
      expect(answers, {_gate: 'Aprovar (Recommended)'});
      expect(tester.takeException(), isNull);
    });

    testWidgets('com cycle == null o card aparece no painel ao lado do empty state', (tester) async {
      await _open(
        tester,
        _noCycle,
        [_session('s1')],
        details: {
          's1': [_question('q-1')],
        },
      );

      expect(_inCard(find.text(_gate)), findsOneWidget);
      expect(find.descendant(of: _side, matching: _card), findsOneWidget);
      expect(find.text('Nenhum ciclo ativo. Comece com /kickoff ou /specify.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sessão de org ou de outro projeto não aparece', (tester) async {
      await _open(
        tester,
        _withCycle(),
        [_session('s-org', project: '', org: 'acme'), _session('s-other', project: 'other-app')],
        details: {
          's-org': [_question('q-org')],
          's-other': [_question('q-other')],
        },
      );

      expect(_card, findsNothing);
      expect(find.text(_gate), findsNothing);
    });

    testWidgets('sessão encerrada com pendência antiga não aparece', (tester) async {
      await _open(
        tester,
        _withCycle(),
        [_session('s-done', status: SessionStatus.done)],
        details: {
          's-done': [_question('q-1')],
        },
      );

      expect(_card, findsNothing);
    });

    testWidgets('relatório da etapa com o mesmo session_id aparece acima da pergunta', (tester) async {
      final report = _report([
        {'stage': 'specify', 'status': 'done', 'summary_md': 'Spec escrita.', 'session_id': 's1'},
        {
          'stage': 'challenge',
          'status': 'done',
          'summary_md': 'Dois achados aplicados.',
          'session_id': 's1',
          'decisions': [
            {'id': 'd1', 'by': 'challenger', 'text_md': 'Critério reescrito.'},
          ],
        },
      ]);
      await _open(
        tester,
        _withCycle(report: report),
        [_session('s1')],
        details: {
          's1': [_question('q-1')],
        },
      );

      final block = find.byKey(const ValueKey('awaiting-report-challenge'));
      expect(block, findsOneWidget);
      expect(find.byKey(const ValueKey('awaiting-report-specify')), findsNothing);
      expect(
        find.descendant(of: block, matching: find.textContaining('Dois achados aplicados.', findRichText: true)),
        findsOneWidget,
      );
      expect(find.descendant(of: block, matching: find.text('challenger')), findsOneWidget);
      expect(tester.getTopLeft(block).dy, lessThan(tester.getTopLeft(_inCard(find.text(_gate))).dy));
    });

    testWidgets('sem relatório da sessão aparece só a pergunta', (tester) async {
      final report = _report([
        {'stage': 'challenge', 'status': 'done', 'summary_md': 'De outra sessão.', 'session_id': 's-x'},
      ]);
      await _open(
        tester,
        _withCycle(report: report),
        [_session('s1')],
        details: {
          's1': [_question('q-1')],
        },
      );

      expect(_inCard(find.text(_gate)), findsOneWidget);
      expect(find.byKey(const ValueKey('awaiting-report-challenge')), findsNothing);
    });

    testWidgets('PermissionRequest vira linha que abre em Sessões, sem responder no Fluxo', (tester) async {
      final sessions = await _open(
        tester,
        _withCycle(),
        [_session('s1')],
        details: {
          's1': [
            const PermissionRequest(
              '2026-03-10T10:05:00Z',
              requestId: 'p-1',
              seq: 2,
              toolName: 'Bash',
              target: 'rm -rf build',
            ),
          ],
        },
      );

      expect(_inCard(find.text('Permissão pendente em sessão s1 —')), findsOneWidget);
      expect(_inCard(find.text('Responder')), findsNothing);

      await tester.tap(_inCard(find.text('abrir em Sessões')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/p/$_project/sessions/s1');
      expect(sessions.answerCalls, isEmpty);
    });

    testWidgets('etapa running com sessão detached mostra sessão encerrada quando o painel exibe outra', (
      tester,
    ) async {
      final report = _report([
        {'stage': 'specify', 'status': 'done', 'session_id': 's-spec'},
        {'stage': 'challenge', 'status': 'running', 'session_id': 's-dead'},
      ]);
      await _open(tester, _withCycle(report: report), [
        _session('s-spec', status: SessionStatus.done, pending: 0),
        _session('s-dead', status: SessionStatus.detached, pending: 0),
      ]);
      _router(tester).go('/p/$_project/flow?stage=specify');
      await tester.pumpAndSettle();

      expect(_inCard(find.text('challenge-spec: sessão encerrada — retome em Sessões')), findsOneWidget);

      await tester.tap(_inCard(find.text('abrir em Sessões')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_project/sessions/s-dead');
    });

    testWidgets('etapa running com sessão viva não mostra aviso', (tester) async {
      final report = _report([
        {'stage': 'challenge', 'status': 'running', 'session_id': 's-live'},
      ]);
      await _open(tester, _withCycle(report: report), [
        _session('s-live', status: SessionStatus.running, pending: 0),
      ], settle: false);

      expect(_card, findsNothing);
    });

    testWidgets('só a sessão exibida no painel pendente: sem card, a pergunta fica no painel', (tester) async {
      await _open(
        tester,
        _withCycle(),
        [_session('s-stage', command: '/challenge-spec')],
        details: {
          's-stage': [_question('q-1')],
        },
      );

      expect(_card, findsNothing);
      expect(
        find.descendant(of: find.byKey(const ValueKey('session-feed')), matching: find.text(_gate)),
        findsOneWidget,
      );
    });

    testWidgets('duas sessões pendentes: o card lista só a que não está no painel', (tester) async {
      await _open(
        tester,
        _withCycle(),
        [_session('s-stage', command: '/challenge-spec'), _session('s-rev')],
        details: {
          's-stage': [_question('q-stage', question: 'Pergunta da etapa?')],
          's-rev': [_question('q-rev', question: 'Pergunta do review?')],
        },
      );

      expect(_inCard(find.byKey(const ValueKey('awaiting-s-rev'))), findsOneWidget);
      expect(_inCard(find.byKey(const ValueKey('awaiting-s-stage'))), findsNothing);
      expect(_inCard(find.text('Pergunta do review?')), findsOneWidget);
      expect(_inCard(find.text('Pergunta da etapa?')), findsNothing);
    });

    testWidgets('na gaveta o card também filtra e o contador do botão não muda', (tester) async {
      await _open(
        tester,
        _withCycle(),
        [_session('s-stage', command: '/challenge-spec'), _session('s-rev')],
        details: {
          's-stage': [_question('q-stage', question: 'Pergunta da etapa?')],
          's-rev': [_question('q-rev', question: 'Pergunta do review?')],
        },
        size: const Size(1300, 1400),
      );

      final toggle = find.byKey(const ValueKey('flow-drawer-toggle'));
      expect(find.descendant(of: toggle, matching: find.text('Sessão da etapa · 2 aguardando')), findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(_inCard(find.text('Pergunta do review?')), findsOneWidget);
      expect(_inCard(find.text('Pergunta da etapa?')), findsNothing);
    });

    testWidgets('sessão encerrada exibida no painel sai do card: o aviso de retomar está logo abaixo', (tester) async {
      final report = _report([
        {'stage': 'challenge', 'status': 'running', 'session_id': 's-dead'},
      ]);
      await _open(tester, _withCycle(report: report), [_session('s-dead', status: SessionStatus.detached, pending: 0)]);

      expect(find.descendant(of: _side, matching: find.byKey(const ValueKey('session-feed'))), findsOneWidget);
      expect(find.byKey(const ValueKey('flow-awaiting')), findsNothing);
      expect(
        find.descendant(of: _side, matching: find.textContaining('O processo desta sessão terminou')),
        findsOneWidget,
      );
    });

    testWidgets('várias pendências viram lista, a mais antiga primeiro', (tester) async {
      await _open(
        tester,
        _withCycle(),
        [_session('s-new', createdAt: '2026-03-10T12:00:00Z'), _session('s-old', createdAt: '2026-03-10T08:00:00Z')],
        details: {
          's-new': [_question('q-new', question: 'Pergunta nova?')],
          's-old': [_question('q-old', question: 'Pergunta antiga?')],
        },
      );

      final older = tester.getTopLeft(_inCard(find.text('Pergunta antiga?'))).dy;
      final newer = tester.getTopLeft(_inCard(find.text('Pergunta nova?'))).dy;
      expect(older, lessThan(newer));
    });
  });

  group('gate no Fluxo', () {
    // Widths of the Fluxo itself: 1400 keeps the side panel next to the timeline, 1000 puts it in the drawer.
    for (final width in [1400.0, 1000.0]) {
      testWidgets('Fluxo com $width px: Decidir acima da linha do tempo e toque leva à rota', (tester) async {
        await _openGamma(tester, size: Size(width + _sidebar, 1400));

        final row = _byKey('flow-gate-row-plan');
        expect(row, findsOneWidget);
        expect(_byKey('flow-gate-row-spec'), findsOneWidget);
        expect(_byKey('flow-gate-row-tasks'), findsNothing);
        expect(
          tester.getTopLeft(row).dy,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('timeline-stage-kickoff'))).dy),
        );
        expect(find.descendant(of: row, matching: find.text('3 decisões antes de gerar as tasks')), findsOneWidget);

        await tester.tap(find.descendant(of: row, matching: find.text('Decidir')));
        await tester.pumpAndSettle();
        expect(_location(tester), '/p/$_gamma/gate/plan');
      });

      testWidgets('Fluxo com $width px: perguntas todas respondidas com o gate open mantêm o título de decisões', (
        tester,
      ) async {
        await _openGamma(tester, size: Size(width + _sidebar, 1400), answered: true);

        final row = _byKey('flow-gate-row-plan');
        expect(find.descendant(of: row, matching: find.text('3 decisões antes de gerar as tasks')), findsOneWidget);
        expect(find.descendant(of: row, matching: find.text('Aprovar o plano?')), findsNothing);
      });

      testWidgets('Fluxo com $width px: a sessão da etapa mostra a nota sem botão no lugar do QuestionCard do gate', (
        tester,
      ) async {
        await _openGamma(tester, size: Size(width + _sidebar, 1400));
        expect(find.byKey(const ValueKey('flow-drawer-toggle')), width >= 1200 ? findsNothing : findsOneWidget);
        await _revealSide(tester);

        final request = find.descendant(of: _side, matching: _byKey('flow-gate-request-plan'));
        expect(request, findsOneWidget);
        expect(find.descendant(of: _side, matching: find.byType(QuestionCard)), findsNothing);

        expect(find.descendant(of: request, matching: find.text('Decidir')), findsNothing);
        expect(
          find.descendant(of: request, matching: find.text('decida na linha Decidir, acima da linha do tempo')),
          findsOneWidget,
        );
      });

      testWidgets('Fluxo com $width px: um só botão Decidir por gate na tela', (tester) async {
        await _openGamma(tester, size: Size(width + _sidebar, 1400), withSpec: true);
        await _revealSide(tester);

        expect(find.text('Decidir'), findsNWidgets(2));
        expect(find.descendant(of: _byKey('flow-gate-row-plan'), matching: find.text('Decidir')), findsOneWidget);
        expect(find.descendant(of: _byKey('flow-gate-row-spec'), matching: find.text('Decidir')), findsOneWidget);
      });
    }

    testWidgets('Aguardando você omite a sessão do gate; pergunta sem gate mantém o card', (tester) async {
      await _openGamma(tester, withSpec: true, withOther: true);
      await _revealSide(tester);

      expect(_byKey('awaiting-s-spec'), findsNothing);
      expect(_byKey('flow-gate-request-spec'), findsNothing);
      expect(_inCard(find.text('Decidir')), findsNothing);
      expect(_inCard(find.byType(QuestionCard)), findsOneWidget);
      expect(_inCard(find.text('Pergunta do review?')), findsOneWidget);
    });

    testWidgets('aba Sessões mantém o QuestionCard do mesmo pedido', (tester) async {
      await _openGamma(tester);
      _router(tester).go('/p/$_gamma/sessions/s-plan');
      await tester.pumpAndSettle();

      expect(find.byType(QuestionCard), findsOneWidget);
      expect(_byKey('flow-gate-request-plan'), findsNothing);
    });

    testWidgets('Passou sem você lista o gate passed abaixo da linha do tempo e abre a tela dele', (tester) async {
      await _openGamma(tester);

      final passed = _byKey('flow-passed-tasks');
      expect(passed, findsOneWidget);
      expect(_byKey('flow-passed-plan'), findsNothing);
      expect(
        tester.getTopLeft(passed).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey('timeline-stage-kickoff'))).dy),
      );

      await tester.tap(find.descendant(of: passed, matching: find.text('ver')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_gamma/gate/tasks');
    });

    testWidgets('relatório de outro ciclo não mostra gate e mantém o card', (tester) async {
      await _openGamma(tester, current: false);
      await _revealSide(tester);

      expect(_byKey('flow-gate-row-plan'), findsNothing);
      expect(_byKey('flow-passed-tasks'), findsNothing);
      expect(find.descendant(of: _side, matching: find.byType(QuestionCard)), findsOneWidget);
    });
  });

  group('gate pr no Fluxo', () {
    testWidgets('Decidir mostra o pr depois do tasks e leva à tela do gate pr', (tester) async {
      await _openDelta(tester, tasks: 'open', pr: 'open');

      final tasks = _byKey('flow-gate-row-tasks');
      final pr = _byKey('flow-gate-row-pr');
      expect(tasks, findsOneWidget);
      expect(pr, findsOneWidget);
      expect(tester.getTopLeft(pr).dy, greaterThan(tester.getTopLeft(tasks).dy));
      expect(find.descendant(of: pr, matching: find.text('2 pontos antes do PR')), findsOneWidget);

      await tester.tap(find.descendant(of: pr, matching: find.text('Decidir')));
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_delta/gate/pr');
    });

    testWidgets('Passou sem você lista o pr depois do tasks', (tester) async {
      await _openDelta(tester, tasks: 'passed', pr: 'passed');

      final tasks = _byKey('flow-passed-tasks');
      final pr = _byKey('flow-passed-pr');
      expect(tasks, findsOneWidget);
      expect(pr, findsOneWidget);
      expect(tester.getTopLeft(pr).dy, greaterThan(tester.getTopLeft(tasks).dy));
    });

    testWidgets('a sessão do complete mostra a nota do pr no painel; o único QuestionCard é o do card', (tester) async {
      await _openDelta(tester, tasks: 'passed', pr: 'open');

      expect(find.descendant(of: _side, matching: _byKey('flow-gate-request-pr')), findsOneWidget);
      expect(find.descendant(of: _side, matching: find.byType(QuestionCard)), findsOneWidget);
      expect(_inCard(find.byType(QuestionCard)), findsOneWidget);
      expect(_inCard(find.text('Pergunta do review?')), findsOneWidget);
    });

    testWidgets('com o painel em outra etapa, Aguardando você omite a sessão do complete', (tester) async {
      await _openDelta(tester, tasks: 'passed', pr: 'open', stage: 'tasks');

      expect(_card, findsOneWidget);
      expect(_byKey('awaiting-s-complete'), findsNothing);
      expect(_inCard(find.byKey(const ValueKey('awaiting-s-rev'))), findsOneWidget);
      expect(_byKey('flow-gate-request-pr'), findsNothing);
    });
  });
}
