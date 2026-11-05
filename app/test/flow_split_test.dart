import 'dart:async';
import 'dart:convert';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/theme/app_colors.dart';
import 'package:claude_flow/data/metrics_models.dart';
import 'package:claude_flow/data/metrics_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/session_reducer.dart';
import 'package:claude_flow/data/sse.dart';
import 'package:claude_flow/features/flow/flow_page.dart';
import 'package:claude_flow/features/sessions/session_labels.dart';
import 'package:claude_flow/features/sessions/session_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _project = 'split-app';

/// Details go through the real reducer, from the engine's event log.
class _Sessions extends MockSessionsRepository {
  _Sessions(this.list, this.logs);

  final List<SessionSummary> list;
  final Map<String, List<Map<String, Object?>>> logs;
  final answerCalls = <(String id, String requestId, PermissionDecision decision, Map<String, String>? answers)>[];
  final sendCalls = <(String id, String text)>[];

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.value(list);

  @override
  Stream<SessionDetail> watchSession(String id) {
    final summary = list.firstWhere((s) => s.id == id);
    final frames = [
      for (final (i, e) in (logs[id] ?? const []).indexed)
        SseFrame('event', jsonEncode({'seq': i + 1, 'at': '2026-03-10T10:00:00Z', ...e})),
    ];
    return Stream.value(frames.fold(SessionDetail(summary: summary), applyFrame));
  }

  @override
  Future<void> answer(String id, String requestId, PermissionDecision decision, {Map<String, String>? answers}) async =>
      answerCalls.add((id, requestId, decision, answers));

  @override
  Future<void> send(String id, String text) async => sendCalls.add((id, text));
}

class _LiveSessions extends _Sessions {
  _LiveSessions(this.controller) : super(const [], const {});

  final StreamController<List<SessionSummary>> controller;

  @override
  Stream<List<SessionSummary>> watchSessions() => controller.stream;

  @override
  Stream<SessionDetail> watchSession(String id) => Stream.value(SessionDetail(summary: _session(id, '/kickoff')));
}

class _CountingMetrics implements MetricsRepository {
  int loads = 0;

  @override
  Future<ProjectMetrics> loadProject(Project project) async {
    loads++;
    return const ProjectMetrics.empty();
  }
}

SessionSummary _session(String id, String command, {SessionStatus status = SessionStatus.idle, int pending = 0}) =>
    SessionSummary(
      id: id,
      project: _project,
      command: command,
      title: 'sessão $id',
      status: status,
      createdAt: '2026-03-10T10:00:00Z',
      pendingPermissions: pending,
    );

const _gate = 'Aprovar a spec?';

Map<String, Object?> _text(String text) => {'kind': 'assistant_text', 'text': text};

const Map<String, Object?> _question = {
  'kind': 'permission',
  'requestId': 'q-1',
  'toolName': 'AskUserQuestion',
  'input': {
    'questions': [
      {
        'header': 'spec',
        'question': _gate,
        'options': [
          {'label': 'Aprovar (Recommended)', 'description': 'segue para o /plan'},
          {'label': 'Ajustar', 'description': 'descreva o ajuste em Outro'},
        ],
      },
    ],
  },
};

ReportDoc _report(List<Map<String, Object?>> stages) => parseReport(
  jsonEncode({
    'version': 1,
    'cycle': {'feature': 'Split'},
    'stages': stages,
  }),
)!;

final _twoStages = _report([
  {'stage': 'specify', 'status': 'done', 'summary_md': 'Spec escrita.', 'session_id': 's-spec'},
  {'stage': 'challenge', 'status': 'running', 'session_id': 's-chal'},
]);

Project _withCycle(ReportDoc report) => Project(
  name: _project,
  path: '/synthetic/$_project',
  cycle: Cycle(stage: Stage.challenge, autoMode: false, stageMinutes: const {}, runs: const [], report: report),
);

Future<_Sessions> _open(
  WidgetTester tester,
  Project project,
  List<SessionSummary> list,
  Map<String, List<Map<String, Object?>>> logs, {
  Size size = const Size(1600, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = _Sessions(list, logs);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: [project]),
      sessions: sessions,
      engine: const MockEngineController(),
    ),
  );
  await tester.pump();
  _router(tester).go('/p/$_project/flow');
  await tester.pumpAndSettle();
  return sessions;
}

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.toString();

final _side = find.byKey(const ValueKey('flow-side-panel'));
final _feed = find.byKey(const ValueKey('session-feed'));

Finder _inSide(Finder f) => find.descendant(of: _side, matching: f);

Finder _inFeed(Finder f) => find.descendant(of: _feed, matching: f);

Finder _md(String text) => find.textContaining(text, findRichText: true);

bool _highlighted(WidgetTester tester, Stage stage) {
  final colors = Theme.of(tester.element(find.byType(Scaffold).first)).extension<AppColors>()!;
  return tester.widget<Container>(find.byKey(ValueKey('timeline-stage-${stage.name}'))).color == colors.hover;
}

Future<void> _tapStage(WidgetTester tester, Stage stage) async {
  await tester.tap(find.byKey(ValueKey('timeline-stage-${stage.name}')));
  await tester.pumpAndSettle();
}

void main() {
  final list = [
    _session('s-spec', '/specify', status: SessionStatus.done),
    _session('s-chal', '/challenge-spec', pending: 1),
  ];
  final logs = {
    's-spec': [_text('Texto da spec.')],
    's-chal': [_text('Texto do desafio.'), _question],
  };

  testWidgets('o painel mostra a sessão em andamento ao lado da linha do tempo', (tester) async {
    await _open(tester, _withCycle(_twoStages), list, logs);

    expect(_side, findsOneWidget);
    expect(_inFeed(_md('Texto do desafio.')), findsOneWidget);
    expect(_inSide(find.text('/challenge-spec')), findsOneWidget);
    expect(_inSide(find.text('Interromper')), findsNothing);
    expect(
      tester.getTopLeft(_side).dx,
      greaterThan(tester.getTopRight(find.byKey(const ValueKey('timeline-stage-kickoff'))).dx - 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('clicar numa etapa troca para a sessão dela e muda o ?stage=; sem sessão vira placeholder', (
    tester,
  ) async {
    await _open(tester, _withCycle(_twoStages), list, logs);

    await _tapStage(tester, Stage.specify);
    expect(_location(tester), '/p/$_project/flow?stage=specify');
    expect(_inFeed(_md('Texto da spec.')), findsOneWidget);
    expect(_inFeed(_md('Texto do desafio.')), findsNothing);
    expect(_highlighted(tester, Stage.specify), isTrue);

    await _tapStage(tester, Stage.plan);
    expect(_location(tester), '/p/$_project/flow?stage=plan');
    expect(_feed, findsNothing);
    expect(_inSide(find.text('nenhuma sessão ativa nesta etapa')), findsOneWidget);
    expect(_inSide(find.text('Kickoff')), findsOneWidget);
    expect(_highlighted(tester, Stage.plan), isTrue);
    expect(_highlighted(tester, Stage.specify), isFalse);

    await _tapStage(tester, Stage.challenge);
    expect(_location(tester), '/p/$_project/flow?stage=challenge');
    expect(_inFeed(_md('Texto do desafio.')), findsOneWidget);
  });

  testWidgets('etapas que compartilham o session_id: o destaque é a etapa clicada, não a última da sessão', (
    tester,
  ) async {
    final shared = _report([
      for (final s in ['specify', 'challenge', 'plan', 'tasks'])
        {'stage': s, 'status': 'done', 'summary_md': 'Resumo de $s.', 'session_id': 's-all'},
    ]);
    await _open(
      tester,
      _withCycle(shared),
      [_session('s-all', '/tasks')],
      {
        's-all': [_text('Texto compartilhado.')],
      },
    );

    await _tapStage(tester, Stage.specify);

    expect(_location(tester), '/p/$_project/flow?stage=specify');
    expect(_highlighted(tester, Stage.specify), isTrue);
    expect(_highlighted(tester, Stage.tasks), isFalse);
    expect(_highlighted(tester, Stage.plan), isFalse);
    expect(_inFeed(_md('Texto compartilhado.')), findsOneWidget);
  });

  testWidgets('o chevron expande o relatório sem selecionar a etapa', (tester) async {
    await _open(tester, _withCycle(_twoStages), list, logs);

    await tester.tap(find.byKey(const ValueKey('timeline-chevron-specify')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline-report-specify')), findsOneWidget);
    expect(_location(tester), '/p/$_project/flow');
    expect(_highlighted(tester, Stage.specify), isFalse);
    expect(_inFeed(_md('Texto do desafio.')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline-chevron-specify')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline-report-specify')), findsNothing);
  });

  testWidgets('tocar na etapa seleciona sem expandir o relatório', (tester) async {
    await _open(tester, _withCycle(_twoStages), list, logs);

    await _tapStage(tester, Stage.specify);

    expect(find.byKey(const ValueKey('timeline-report-specify')), findsNothing);
  });

  testWidgets('sem sessão de pipeline viva, mostra a sessão da etapa running do relatório', (tester) async {
    await _open(
      tester,
      _withCycle(_twoStages),
      [_session('s-chal', 'continue o desafio')],
      {
        's-chal': [_text('Retomada fora do pipeline.')],
      },
    );

    expect(_inFeed(_md('Retomada fora do pipeline.')), findsOneWidget);
  });

  testWidgets('sem sessão nenhuma, placeholder com Kickoff', (tester) async {
    await _open(tester, _withCycle(_report([])), const [], const {});

    expect(_inSide(find.text('nenhuma sessão ativa nesta etapa')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Kickoff')).onPressed, isNotNull);
  });

  testWidgets('sem ciclo, o painel aparecer não remonta o empty state nem recarrega o histórico', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = StreamController<List<SessionSummary>>();
    addTearDown(controller.close);
    final metrics = _CountingMetrics();
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(
          data: [const Project(name: _project, path: '/synthetic/$_project')],
        ),
        sessions: _LiveSessions(controller),
        engine: const MockEngineController(),
        metrics: metrics,
      ),
    );
    controller.add(const []);
    await tester.pump();
    _router(tester).go('/p/$_project/flow');
    await tester.pumpAndSettle();
    expect(_side, findsNothing);
    final loads = metrics.loads;
    expect(loads, greaterThan(0));

    controller.add([_session('s-kick', '/kickoff', pending: 1)]);
    await tester.pumpAndSettle();

    expect(_side, findsOneWidget);
    expect(metrics.loads, loads);
  });

  testWidgets('sem ciclo e sem sessão: um único empty state, sem painel da direita', (tester) async {
    await _open(tester, const Project(name: _project, path: '/synthetic/$_project'), const [], const {});

    expect(find.widgetWithText(FilledButton, 'Novo kickoff'), findsOneWidget);
    expect(find.descendant(of: find.byType(FlowPage), matching: find.byType(FilledButton)), findsOneWidget);
    expect(_side, findsNothing);
    expect(find.byType(SessionPanel), findsNothing);
    expect(find.byKey(const ValueKey('flow-no-session')), findsNothing);
    expect(find.byKey(const ValueKey('flow-awaiting')), findsNothing);
    expect(find.byKey(const ValueKey('flow-drawer-toggle')), findsNothing);
  });

  testWidgets('sem ciclo, o painel volta quando há sessão de etapa', (tester) async {
    await _open(
      tester,
      const Project(name: _project, path: '/synthetic/$_project'),
      [_session('s-kick', '/kickoff')],
      {
        's-kick': [_text('Triando o card.')],
      },
    );

    expect(_side, findsOneWidget);
    expect(_inFeed(_md('Triando o card.')), findsOneWidget);
  });

  testWidgets('responder a pergunta no painel chama answer', (tester) async {
    final sessions = await _open(tester, _withCycle(_twoStages), list, logs);

    await tester.ensureVisible(_inFeed(find.text('Aprovar (Recommended)')));
    await tester.tap(_inFeed(find.text('Aprovar (Recommended)')));
    await tester.pumpAndSettle();
    await tester.tap(_inFeed(find.text('Responder')));
    await tester.pumpAndSettle();

    expect(sessions.answerCalls, hasLength(1));
    final (id, requestId, decision, answers) = sessions.answerCalls.single;
    expect((id, requestId, decision), ('s-chal', 'q-1', PermissionDecision.answer));
    expect(answers, {_gate: 'Aprovar (Recommended)'});
  });

  testWidgets('mandar mensagem no painel chama send', (tester) async {
    final sessions = await _open(tester, _withCycle(_twoStages), list, logs);

    await tester.enterText(_inSide(find.byType(TextField)).last, 'pode seguir');
    await tester.tap(_inSide(find.byIcon(Icons.arrow_upward)));
    await tester.pumpAndSettle();

    expect(sessions.sendCalls, [('s-chal', 'pode seguir')]);
  });

  testWidgets('o card Aguardando você fica no topo do painel', (tester) async {
    await _open(tester, _withCycle(_twoStages), list, logs);

    final card = _inSide(find.byKey(const ValueKey('flow-awaiting')));
    expect(card, findsOneWidget);
    expect(tester.getTopLeft(card).dy, lessThan(tester.getTopLeft(_feed).dy));
  });

  testWidgets('abaixo de 1200 px o painel vira gaveta aberta pelo botão com a contagem', (tester) async {
    await _open(tester, _withCycle(_twoStages), list, logs, size: const Size(1300, 900));

    expect(_side, findsNothing);
    final toggle = find.byKey(const ValueKey('flow-drawer-toggle'));
    expect(find.descendant(of: toggle, matching: find.text('Sessão da etapa · 1 aguardando')), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(_side, findsOneWidget);
    expect(_inFeed(find.text(_gate)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a contagem da gaveta inclui etapa running com sessão encerrada', (tester) async {
    await _open(
      tester,
      _withCycle(_twoStages),
      [
        _session('s-spec', '/specify', status: SessionStatus.done),
        _session('s-chal', '/challenge-spec', status: SessionStatus.done),
      ],
      const {},
      size: const Size(1300, 900),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('flow-drawer-toggle')),
        matching: find.text('Sessão da etapa · 1 aguardando'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('sessão reanexada sem mensagem nova aparece como interrompida no banner e no cabeçalho', (tester) async {
    await _open(
      tester,
      _withCycle(_twoStages),
      [_session('s-chal', '/challenge-spec')],
      {
        's-chal': [
          _text('Texto do desafio.'),
          {'kind': 'reattached'},
        ],
      },
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('stage-banner')),
        matching: find.text('Etapa em andamento: /challenge-spec ($kInterruptedLabel)'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('session-status')), matching: find.text(kInterruptedLabel)),
      findsOneWidget,
    );
  });
}
