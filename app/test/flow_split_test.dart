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
import 'package:claude_flow/features/flow/last_cycle_line.dart';
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
  Future<void> send(String id, String text, {List<ImageAttachment> images = const []}) async =>
      sendCalls.add((id, text, images));
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
  cycle: Cycle(stage: Stage.challenge, stageMinutes: const {}, runs: const [], report: report),
);

Future<_Sessions> _open(
  WidgetTester tester,
  Project project,
  List<SessionSummary> list,
  Map<String, List<Map<String, Object?>>> logs, {
  Size size = const Size(1600, 1400),
  String location = '/p/$_project/flow',
  List<Project> others = const [],
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sessions = _Sessions(list, logs);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: [project, ...others]),
      sessions: sessions,
      engine: const MockEngineController(),
    ),
  );
  await tester.pump();
  _router(tester).go(location);
  // A running session's typing indicator never settles.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return sessions;
}

Finder _byKey(String key) => find.byKey(ValueKey(key));

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(_byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(_byKey(key));
  await tester.pumpAndSettle();
}

/// The timeline starts collapsed under the steps bar.
Future<void> _showStages(WidgetTester tester) => _tapKey(tester, 'cycle-steps-toggle');

final _timeline = _byKey('timeline-stage-kickoff');
final _now = _byKey('cycle-now');
final _action = _byKey('cycle-now-action');

Finder _inNow(Finder f) => find.descendant(of: _now, matching: f);

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
    await _showStages(tester);

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
    await _showStages(tester);

    await _tapStage(tester, Stage.specify);
    expect(_location(tester), '/p/$_project/flow?stage=specify');
    expect(_inFeed(_md('Texto da spec.')), findsOneWidget);
    expect(_inFeed(_md('Texto do desafio.')), findsNothing);
    expect(_highlighted(tester, Stage.specify), isTrue);

    await _tapStage(tester, Stage.plan);
    expect(_location(tester), '/p/$_project/flow?stage=plan');
    expect(_feed, findsNothing);
    expect(_inSide(find.text('nenhuma sessão ativa nesta etapa')), findsOneWidget);
    expect(_inSide(find.text('Kickoff')), findsNothing);
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
    await _showStages(tester);

    await _tapStage(tester, Stage.specify);

    expect(_location(tester), '/p/$_project/flow?stage=specify');
    expect(_highlighted(tester, Stage.specify), isTrue);
    expect(_highlighted(tester, Stage.tasks), isFalse);
    expect(_highlighted(tester, Stage.plan), isFalse);
    expect(_inFeed(_md('Texto compartilhado.')), findsOneWidget);
  });

  testWidgets('o chevron expande o relatório sem selecionar a etapa', (tester) async {
    await _open(tester, _withCycle(_twoStages), list, logs);
    await _showStages(tester);

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
    await _showStages(tester);

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

  testWidgets('com ciclo ativo, o placeholder não oferece Kickoff', (tester) async {
    await _open(tester, _withCycle(_report([])), const [], const {});

    expect(_inSide(find.text('nenhuma sessão ativa nesta etapa')), findsOneWidget);
    expect(_inSide(find.byType(FilledButton)), findsNothing);
  });

  testWidgets('sem ciclo, o placeholder continua com Kickoff', (tester) async {
    await _open(tester, const Project(name: _project, path: '/synthetic/$_project'), [
      _session('s-rev', 'revise o PR', pending: 1),
    ], const {});

    expect(_inSide(find.text('nenhuma sessão ativa nesta etapa')), findsOneWidget);
    expect(_inSide(find.widgetWithText(FilledButton, 'Kickoff')), findsOneWidget);
  });

  testWidgets('sem ciclo e com kickoff vivo, a coluna principal mostra o kickoff em andamento', (tester) async {
    await _open(tester, const Project(name: _project, path: '/synthetic/$_project'), [
      _session('s-kick', '/kickoff 7579'),
    ], const {});

    final running = find.byKey(const ValueKey('flow-kickoff-running'));
    expect(find.descendant(of: running, matching: find.text('Kickoff em andamento')), findsOneWidget);
    expect(find.descendant(of: running, matching: find.text('sessão s-kick')), findsOneWidget);
    expect(find.text('Novo kickoff'), findsNothing);
    expect(find.byType(LastCycleLine), findsNothing);
  });

  testWidgets('sem ciclo, sessão viva de /complete não vira kickoff em andamento', (tester) async {
    await _open(tester, const Project(name: _project, path: '/synthetic/$_project'), [
      _session('s-done', '/complete'),
    ], const {});

    expect(find.byKey(const ValueKey('flow-kickoff-running')), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Novo kickoff'), findsOneWidget);
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

    controller.add([_session('s-rev', 'revise o PR', pending: 1)]);
    await tester.pumpAndSettle();

    expect(_side, findsOneWidget);
    expect(find.byType(LastCycleLine), findsOneWidget);
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

  testWidgets('tabela markdown no turno do assistente vira Table no feed', (tester) async {
    await _open(
      tester,
      const Project(name: _project, path: '/synthetic/$_project'),
      [_session('s-kick', '/kickoff')],
      {
        's-kick': [_text('Comparação:\n\n| | A | B |\n|---|---|---|\n| Pin | `ref` | commit |')],
      },
    );

    expect(_inFeed(find.byType(Table)), findsOneWidget);
    expect(_inFeed(_md('|---|')), findsNothing);
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

    expect(sessions.sendCalls.map((c) => (c.$1, c.$2)), [('s-chal', 'pode seguir')]);
  });

  testWidgets('o card Aguardando você fica no topo do painel', (tester) async {
    await _open(
      tester,
      _withCycle(_twoStages),
      [...list, _session('s-rev', 'revise o PR', pending: 1)],
      {
        ...logs,
        's-rev': [_question],
      },
    );

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

  group('estado recolhido', () {
    final verify = _byKey('flow-verify');

    testWidgets('detalhes e linha do tempo abertos sobrevivem à troca de split para gaveta', (tester) async {
      await _open(tester, _withCycle(_twoStages), list, logs, size: const Size(1440, 900));
      expect(_side, findsOneWidget);
      expect(_timeline, findsNothing);
      expect(verify, findsNothing);

      await _showStages(tester);
      await _tapKey(tester, 'cycle-details-toggle');
      expect(_timeline, findsOneWidget);
      expect(verify, findsOneWidget);

      // Below the split width (sidebar included) the same column moves under the drawer's Scaffold.
      tester.view.physicalSize = const Size(1300, 900);
      await tester.pumpAndSettle();

      expect(_side, findsNothing);
      expect(_byKey('flow-drawer-toggle'), findsOneWidget);
      expect(_timeline, findsOneWidget);
      expect(verify, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('trocar de projeto zera os dois', (tester) async {
      const other = 'other-app';
      await _open(
        tester,
        _withCycle(_twoStages),
        list,
        logs,
        others: [
          Project(
            name: other,
            path: '/synthetic/$other',
            cycle: Cycle(stage: Stage.plan, stageMinutes: const {}, runs: const [], report: _report([])),
          ),
        ],
      );
      await _showStages(tester);
      await _tapKey(tester, 'cycle-details-toggle');
      expect(_timeline, findsOneWidget);
      expect(verify, findsOneWidget);

      _router(tester).go('/p/$other/flow');
      await tester.pumpAndSettle();

      expect(find.descendant(of: _byKey('cycle-steps'), matching: find.text('Etapa 4 de 8')), findsOneWidget);
      expect(_timeline, findsNothing);
      expect(verify, findsNothing);
    });

    testWidgets('?stage= de uma etapa para outra não reabre a linha do tempo fechada', (tester) async {
      await _open(tester, _withCycle(_twoStages), list, logs, location: '/p/$_project/flow?stage=specify');
      expect(_timeline, findsOneWidget);

      await _tapKey(tester, 'cycle-steps-toggle');
      expect(_timeline, findsNothing);

      _router(tester).go('/p/$_project/flow?stage=plan');
      await tester.pumpAndSettle();

      expect(_location(tester), '/p/$_project/flow?stage=plan');
      expect(_timeline, findsNothing);
    });
  });

  group('barra de etapas', () {
    testWidgets('mostra a posição e os 8 segmentos; o link abre e fecha a linha do tempo', (tester) async {
      await _open(tester, _withCycle(_twoStages), list, logs);

      final steps = _byKey('cycle-steps');
      expect(find.descendant(of: steps, matching: find.text('Etapa 3 de 8')), findsOneWidget);
      for (final s in Stage.values) {
        expect(
          find.descendant(of: steps, matching: _byKey('cycle-step-${s.name}')),
          findsOneWidget,
          reason: s.name,
        );
      }
      expect(find.descendant(of: steps, matching: find.text(Stage.challenge.label)), findsOneWidget);
      expect(find.descendant(of: steps, matching: find.text('ver etapas')), findsOneWidget);
      expect(_timeline, findsNothing);

      await _showStages(tester);
      expect(_timeline, findsOneWidget);
      expect(find.descendant(of: steps, matching: find.text('ocultar etapas')), findsOneWidget);

      await _tapKey(tester, 'cycle-steps-toggle');
      expect(_timeline, findsNothing);
    });

    testWidgets('abrir com ?stage= já mostra a linha do tempo; tocar numa linha mantém e ocultar esconde', (
      tester,
    ) async {
      await _open(tester, _withCycle(_twoStages), list, logs, location: '/p/$_project/flow?stage=specify');
      expect(_timeline, findsOneWidget);
      expect(_highlighted(tester, Stage.specify), isTrue);

      await _tapStage(tester, Stage.plan);
      expect(_location(tester), '/p/$_project/flow?stage=plan');
      expect(_timeline, findsOneWidget);

      await _tapKey(tester, 'cycle-steps-toggle');
      expect(_location(tester), '/p/$_project/flow?stage=plan');
      expect(_timeline, findsNothing);
    });
  });

  group('cartão do ciclo', () {
    testWidgets('sessão da etapa rodando: nada precisa de você e o botão contornado acompanha a conversa', (
      tester,
    ) async {
      await _open(
        tester,
        _withCycle(_twoStages),
        [_session('s-chal', '/challenge-spec', status: SessionStatus.running)],
        logs,
        settle: false,
      );

      expect(_inNow(find.text('Nada precisa de você')), findsOneWidget);
      expect(_inNow(find.text('Etapa ${Stage.challenge.label} em andamento')), findsOneWidget);
      expect(tester.widget(_action), isA<OutlinedButton>());
      expect(find.descendant(of: _action, matching: find.text('Acompanhar a conversa')), findsOneWidget);
      // The split already shows the same session beside the card; the action stays.
      expect(_inSide(find.text('/challenge-spec')), findsOneWidget);
      expect(_byKey('stage-banner'), findsNothing);

      await tester.tap(_action);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_location(tester), '/p/$_project/sessions/s-chal');
    });

    testWidgets('a mesma sessão parada: precisa de você e o botão cheio abre a conversa', (tester) async {
      await _open(tester, _withCycle(_twoStages), [_session('s-chal', '/challenge-spec')], logs);

      expect(_inNow(find.text('Precisa de você')), findsOneWidget);
      expect(_inNow(find.text('A conversa da etapa ${Stage.challenge.label} está parada')), findsOneWidget);
      expect(tester.widget(_action), isA<FilledButton>());
      expect(find.descendant(of: _action, matching: find.text('Abrir a conversa')), findsOneWidget);
      expect(_byKey('stage-banner'), findsNothing);

      await tester.tap(_action);
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_project/sessions/s-chal');
    });

    testWidgets('sem ciclo e com kickoff vivo o banner da etapa continua, sem cartão', (tester) async {
      await _open(tester, const Project(name: _project, path: '/synthetic/$_project'), [
        _session('s-kick', '/kickoff 7579'),
      ], const {});

      expect(_byKey('stage-banner'), findsOneWidget);
      expect(_now, findsNothing);
      expect(_byKey('cycle-steps'), findsNothing);
    });
  });

  testWidgets('sessão reanexada sem mensagem nova aparece como interrompida no cabeçalho do painel', (tester) async {
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
      find.descendant(of: find.byKey(const ValueKey('session-status')), matching: find.text(kInterruptedLabel)),
      findsOneWidget,
    );
  });
}
