import 'dart:convert';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
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

SessionSummary _session(
  String id, {
  String project = _project,
  SessionStatus status = SessionStatus.waitingPermission,
  int pending = 1,
  String createdAt = '2026-03-10T10:00:00Z',
  String? org,
}) => SessionSummary(
  id: id,
  project: project,
  command: '/challenge-spec',
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
  cycle: Cycle(stage: Stage.challenge, autoMode: true, stageMinutes: const {}, runs: const [], report: report),
);

const _noCycle = Project(name: _project, path: '/synthetic/$_project');

Future<_Sessions> _open(
  WidgetTester tester,
  Project project,
  List<SessionSummary> list, {
  Map<String, List<SessionEvent>> details = const {},
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1600, 3200);
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

void main() {
  group('card Aguardando você', () {
    testWidgets('pergunta pendente da sessão do projeto vira card; Aprovar responde pelo answer', (tester) async {
      final sessions = await _open(
        tester,
        _withCycle(),
        [_session('s1')],
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

    testWidgets('etapa running com sessão detached mostra sessão encerrada', (tester) async {
      final report = _report([
        {'stage': 'challenge', 'status': 'running', 'session_id': 's-dead'},
      ]);
      await _open(tester, _withCycle(report: report), [_session('s-dead', status: SessionStatus.detached, pending: 0)]);

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
}
