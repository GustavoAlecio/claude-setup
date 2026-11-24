import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/theme/app_colors.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/features/flow/gate_page.dart';
import 'package:claude_flow/features/reviews/reviews_diff.dart';
import 'package:claude_flow/features/shell/shell_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _project = 'gamma';

/// Projects the test swaps while the screen is open, as the report watcher would.
class _Flow extends MockFlowRepository {
  _Flow(List<Project> data) : _current = data, super(data: data);

  List<Project> _current;
  final _bump = StreamController<void>.broadcast();

  @override
  List<Project> get data => _current;

  set current(List<Project> next) {
    _current = next;
    _bump.add(null);
  }

  @override
  Stream<List<Project>> watchProjects() => Stream.multi((controller) {
    controller.add(projects);
    final sub = _bump.stream.listen((_) => controller.add(projects));
    controller.onCancel = sub.cancel;
  });
}

/// Sessions whose list and events the test controls; a successful answer resolves the request like the engine does.
class _Sessions extends MockSessionsRepository {
  _Sessions(List<SessionSummary> list, Map<String, List<SessionEvent>> events)
    : summaries = {for (final s in list) s.id: s},
      events = {for (final s in list) s.id: events[s.id] ?? const []};

  final Map<String, SessionSummary> summaries;
  final Map<String, List<SessionEvent>> events;
  final _bump = StreamController<void>.broadcast();
  final answerCalls = <(String id, String requestId, PermissionDecision decision, Map<String, String>? answers)>[];

  /// Holds every answer until completed.
  Completer<void>? hold;
  bool fail = false;

  void update() => _bump.add(null);

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.multi((controller) {
    controller.add(summaries.values.toList());
    final sub = _bump.stream.listen((_) => controller.add(summaries.values.toList()));
    controller.onCancel = sub.cancel;
  });

  SessionDetail _detail(String id) => SessionDetail(summary: summaries[id]!, events: events[id]!);

  @override
  Stream<SessionDetail> watchSession(String id) => Stream.multi((controller) {
    if (summaries.containsKey(id)) controller.add(_detail(id));
    final sub = _bump.stream.listen((_) {
      if (summaries.containsKey(id)) controller.add(_detail(id));
    });
    controller.onCancel = sub.cancel;
  });

  @override
  Future<void> answer(String id, String requestId, PermissionDecision decision, {Map<String, String>? answers}) async {
    answerCalls.add((id, requestId, decision, answers));
    if (hold case final hold?) await hold.future;
    if (fail) throw const SessionsException('engine parado', statusCode: 503);
    events[id] = [
      for (final e in events[id]!)
        e is QuestionRequest && e.requestId == requestId ? e.resolve(decision, answers: answers) : e,
    ];
    summaries[id] = summaries[id]!.copyWith(status: SessionStatus.idle, pendingPermissions: 0);
    update();
  }
}

Map<String, dynamic> _gammaJson() =>
    jsonDecode(File('test/fixtures/workflow/gamma/report.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _stage(Map<String, dynamic> doc, String name) =>
    (doc['stages'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['stage'] == name);

/// The gamma fixture with the plan stage run by `s-plan` and the challenge stage by [specSession].
ReportDoc _report({String? specSession, void Function(Map<String, dynamic> plan)? plan}) {
  final doc = _gammaJson();
  _stage(doc, 'plan')['session_id'] = 's-plan';
  if (specSession != null) _stage(doc, 'challenge')['session_id'] = specSession;
  plan?.call(_stage(doc, 'plan')['gate'] as Map<String, dynamic>);
  return parseReport(jsonEncode(doc))!;
}

Project _gamma(ReportDoc report, {bool current = true}) => Project(
  name: _project,
  path: '/synthetic/$_project',
  cycle: Cycle(stage: Stage.plan, runs: const [], stageMinutes: const {}, report: report, reportIsCurrent: current),
);

SessionSummary _session(
  String id, {
  String command = '/plan',
  SessionStatus status = SessionStatus.waitingPermission,
  int pending = 1,
}) => SessionSummary(
  id: id,
  project: _project,
  command: command,
  title: 'sessão $id',
  status: status,
  createdAt: '2026-03-10T10:00:00Z',
  pendingPermissions: pending,
);

/// The questions `wf-report.py show plan` hands the skill for the gamma fixture.
List<Question> _showQuestions() {
  final show = jsonDecode(File('test/fixtures/show/gamma-plan.json').readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final q in (show['questions'] as List).cast<Map<String, dynamic>>())
      Question(
        question: q['question'] as String,
        header: q['header'] as String,
        options: [
          for (final o in (q['options'] as List).cast<Map<String, dynamic>>())
            QuestionOption(o['label'] as String, o['description'] as String),
        ],
      ),
  ];
}

QuestionRequest _request(List<Question> questions, {String id = 'rq-plan', int seq = 5}) =>
    QuestionRequest('2026-03-10T10:05:00Z', requestId: id, seq: seq, questions: questions);

const _specQuestion = 'Aprovar a spec?';

QuestionRequest _approval() => _request(const [
  Question(
    question: _specQuestion,
    header: 'spec',
    options: [
      QuestionOption('Aprovar (Recomendado)', 'segue para o /plan'),
      QuestionOption('Ajustar', 'descreva o ajuste'),
      QuestionOption('Rejeitar', 'encerra a etapa'),
    ],
  ),
], id: 'rq-spec');

Future<(_Flow, _Sessions)> _open(
  WidgetTester tester, {
  required ReportDoc report,
  List<SessionSummary> sessions = const [],
  Map<String, List<SessionEvent>> events = const {},
  String gate = 'plan',
  String? from,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final flow = _Flow([_gamma(report)]);
  final repo = _Sessions(sessions, events);
  await tester.pumpWidget(ClaudeFlowApp(repository: flow, sessions: repo, engine: const MockEngineController()));
  await tester.pumpAndSettle();
  if (from != null) {
    _router(tester).go(from);
    await tester.pumpAndSettle();
  }
  _router(tester).go('/p/$_project/gate/$gate');
  await tester.pumpAndSettle();
  return (flow, repo);
}

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.toString();

Finder _key(String key) => find.byKey(ValueKey(key));

FilledButton _send(WidgetTester tester) => tester.widget<FilledButton>(_key('gate-send'));

Color? _numberColor(WidgetTester tester, int i) => tester.widget<Text>(_key('gate-q-$i-number')).style?.color;

AppColors _colors(WidgetTester tester) => tester.element(find.byType(GatePage)).colors;

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<void> _answerAll(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await _tap(tester, 'gate-option-$i-0');
  }
}

Future<(_Flow, _Sessions)> _deciding(
  WidgetTester tester, {
  List<Question>? questions,
  List<SessionSummary> also = const [],
}) => _open(
  tester,
  report: _report(),
  sessions: [_session('s-plan'), ...also],
  events: {
    's-plan': [_request(questions ?? _showQuestions())],
  },
);

const _delta = 'delta';

Map<String, dynamic> _deltaJson() =>
    jsonDecode(File('test/fixtures/workflow/delta/report.json').readAsStringSync()) as Map<String, dynamic>;

String _deltaDiff() => File('test/fixtures/workflow/delta/pr.diff').readAsStringSync();

/// The delta fixture (`pr` open on the complete stage, run by `s-complete`), with [gate] and [doc] edited in place.
ReportDoc _deltaReport({void Function(Map<String, dynamic> gate)? gate, void Function(Map<String, dynamic> doc)? doc}) {
  final json = _deltaJson();
  gate?.call(_stage(json, 'complete')['gate'] as Map<String, dynamic>);
  doc?.call(json);
  return parseReport(jsonEncode(json))!;
}

Project _deltaProject(ReportDoc report, {List<TaskRun> plan = const []}) => Project(
  name: _delta,
  path: '/synthetic/$_delta',
  cycle: Cycle(
    stage: Stage.complete,
    runs: const [],
    stageMinutes: const {},
    plan: plan,
    report: report,
    reportIsCurrent: true,
  ),
);

TaskRun _task(String id) =>
    TaskRun(id: id, title: 'ajuste $id', complexity: Complexity.m, tier0: Tier.opus, status: Verdict.pending);

SessionSummary _completeSession({SessionStatus status = SessionStatus.waitingPermission, int pending = 1}) =>
    SessionSummary(
      id: 's-complete',
      project: _delta,
      command: '/complete',
      title: 'sessão s-complete',
      status: status,
      createdAt: '2026-03-12T10:00:00Z',
      pendingPermissions: pending,
    );

/// The questions `wf-report.py show pr` hands the skill for the delta fixture.
List<Question> _prQuestions() {
  final show = jsonDecode(File('test/fixtures/show/delta-pr.json').readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final q in (show['questions'] as List).cast<Map<String, dynamic>>())
      Question(
        question: q['question'] as String,
        header: q['header'] as String,
        options: [
          for (final o in (q['options'] as List).cast<Map<String, dynamic>>())
            QuestionOption(o['label'] as String, o['description'] as String),
        ],
      ),
  ];
}

MockDocsRepository _docs([String? diff]) => MockDocsRepository.empty()..write('pr.diff', diff ?? _deltaDiff());

/// Opens `/p/<project>/gate/<gate>` over [projects] (the delta fixture by default) with [docs] as the docs repository.
Future<(_Flow, _Sessions, MockDocsRepository)> _openPr(
  WidgetTester tester, {
  ReportDoc? report,
  List<Project>? projects,
  MockDocsRepository? docs,
  List<SessionSummary>? sessions,
  Map<String, List<SessionEvent>>? events,
  String project = _delta,
  String gate = 'pr',
  List<TaskRun> plan = const [],
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final flow = _Flow(projects ?? [_deltaProject(report ?? _deltaReport(), plan: plan)]);
  final repo = _Sessions(
    sessions ?? [_completeSession()],
    events ??
        {
          's-complete': [_request(_prQuestions(), id: 'rq-pr')],
        },
  );
  final repository = docs ?? _docs();
  await tester.pumpWidget(
    ClaudeFlowApp(repository: flow, sessions: repo, engine: const MockEngineController(), docs: repository),
  );
  await tester.pumpAndSettle();
  _router(tester).go('/p/$project/gate/$gate');
  await tester.pumpAndSettle();
  return (flow, repo, repository);
}

Finder _lines(String key) => find.descendant(of: _key(key), matching: find.byType(DiffLineView));

Finder _keyPrefix(String prefix) =>
    find.byWidgetPredicate((w) => (w.key is ValueKey<String>) && (w.key! as ValueKey<String>).value.startsWith(prefix));

/// [files] files of [lines] added lines each, the first one with [big] lines.
String _bigDiff({int files = 33, int lines = 100, int big = 500}) => [
  for (var f = 0; f < files; f++) ...[
    'diff --git a/lib/big/f$f.dart b/lib/big/f$f.dart',
    'new file mode 100644',
    'index 0000000..1111111',
    '--- /dev/null',
    '+++ b/lib/big/f$f.dart',
    '@@ -0,0 +1,${f == 0 ? big : lines} @@',
    for (var l = 0; l < (f == 0 ? big : lines); l++) '+l$l',
  ],
  '',
].join('\n');

void main() {
  group('tela do gate', () {
    testWidgets('abre fora do shell, com contexto, título, resumo, riscos e perguntas nessa ordem', (tester) async {
      await _deciding(tester);

      expect(find.byType(GatePage), findsOneWidget);
      expect(find.byType(ShellPage), findsNothing);
      expect(find.text('3 decisões antes de gerar as tasks'), findsOneWidget);
      expect(find.text('Plano em duas tasks, com a tela gamma atrás de um repositório novo.'), findsOneWidget);
      expect(find.text('crítico'), findsOneWidget);
      expect(find.text('autor'), findsOneWidget);
      expect(find.text('Pendência 1 de 1'), findsOneWidget);
      expect(_key('gate-skip'), findsNothing);
      expect(find.textContaining('Ficou de fora do resumo: 1 pergunta, 1 candidata'), findsOneWidget);

      final keys = ['gate-context', 'gate-title', 'gate-summary', 'gate-risks', 'gate-questions'];
      final tops = [for (final k in keys) tester.getTopLeft(_key(k)).dy];
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i], greaterThan(tops[i - 1]), reason: '${keys[i]} abaixo de ${keys[i - 1]}');
      }
    });

    testWidgets('spec lê a etapa challenge; pr sem bloco, gate desconhecido e outro ciclo ficam indisponíveis', (
      tester,
    ) async {
      final (flow, _) = await _open(tester, report: _report(), gate: 'spec');
      expect(find.text('Aprovar a spec?'), findsOneWidget);
      expect(find.text('Spec com dois critérios de aceite e nenhuma decisão em aberto.'), findsOneWidget);
      expect(find.text('a etapa rodou no terminal, sem sessão no app'), findsOneWidget);

      for (final gate in ['pr', 'arquitetura']) {
        _router(tester).go('/p/$_project/gate/$gate');
        await tester.pumpAndSettle();
        expect(_key('gate-unavailable'), findsOneWidget, reason: gate);
        expect(_key('gate-back'), findsOneWidget);
        expect(find.byType(ShellPage), findsNothing);
      }

      _router(tester).go('/p/nenhum/gate/plan');
      await tester.pumpAndSettle();
      expect(_key('gate-unavailable'), findsOneWidget);

      flow.current = [_gamma(_report(), current: false)];
      _router(tester).go('/p/$_project/gate/plan');
      await tester.pumpAndSettle();
      expect(_key('gate-unavailable'), findsOneWidget);
    });

    testWidgets('trocar de gate recria a tela, sem herdar o estado do envio', (tester) async {
      await _deciding(tester);
      final before = tester.state(find.byType(GatePage));

      _router(tester).go('/p/$_project/gate/spec');
      await tester.pumpAndSettle();

      expect(tester.state(find.byType(GatePage)), isNot(same(before)));
    });

    testWidgets('o envio só habilita na terceira resposta; números mudam de cor ao responder', (tester) async {
      await _deciding(tester);
      final c = _colors(tester);

      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
      expect(_send(tester).onPressed, isNull);
      expect(find.text('0 de 3 decididas'), findsOneWidget);
      expect(_numberColor(tester, 0), c.warn);

      await _tap(tester, 'gate-option-0-0');
      expect(_numberColor(tester, 0), c.textSecondary);
      expect(_numberColor(tester, 1), c.warn);
      expect(find.text('1 de 3 decididas'), findsOneWidget);
      expect(_send(tester).onPressed, isNull);

      await _tap(tester, 'gate-option-1-1');
      expect(_send(tester).onPressed, isNull);

      await tester.enterText(_key('gate-free-2'), 'só na primeira abertura');
      await tester.pumpAndSettle();
      expect(find.text('3 de 3 decididas'), findsOneWidget);
      expect(_numberColor(tester, 2), c.textSecondary);
      expect(_send(tester).onPressed, isNotNull);
    });

    testWidgets('desenha e envia os rótulos do pedido, com texto livre no lugar da opção', (tester) async {
      final show = _showQuestions();
      final first = show.first;
      final rewritten = [
        Question(
          question: first.question,
          header: first.header,
          options: [
            first.options[1],
            QuestionOption('${first.options[0].label} (Recomendado)', first.options[0].description),
          ],
        ),
        ...show.skip(1),
      ];
      final (_, sessions) = await _deciding(tester, questions: rewritten);

      expect(find.text('Opção A (Recomendado)'), findsOneWidget);
      expect(find.text('Segue o caminho mais simples.'), findsNothing);
      expect(find.text('Segue o caminho mais simples. Preferida pelo autor.'), findsNWidgets(3));

      await _tap(tester, 'gate-option-0-1');
      await _tap(tester, 'gate-option-1-0');
      await _tap(tester, 'gate-option-2-0');
      await tester.enterText(_key('gate-free-1'), 'manter as duas rotas');
      await tester.pumpAndSettle();
      await _tap(tester, 'gate-send');

      expect(sessions.answerCalls, hasLength(1));
      final (id, requestId, decision, answers) = sessions.answerCalls.single;
      expect((id, requestId, decision), ('s-plan', 'rq-plan', PermissionDecision.answer));
      expect(answers, {
        show[0].question: 'Opção A (Recomendado)',
        show[1].question: 'manter as duas rotas',
        show[2].question: 'Opção A',
      });
    });

    testWidgets('envio único: uma chamada, botão desligado enquanto envia', (tester) async {
      final (_, sessions) = await _deciding(tester);
      final hold = sessions.hold = Completer<void>();
      await _answerAll(tester);

      await tester.tap(_key('gate-send'));
      await tester.pump();
      expect(_send(tester).onPressed, isNull);
      await tester.tap(_key('gate-send'), warnIfMissed: false);
      await tester.pump();
      expect(sessions.answerCalls, hasLength(1));
      expect(sessions.answerCalls.single.$4, {for (final q in _showQuestions()) q.question: 'Opção A'});

      hold.complete();
      await tester.pumpAndSettle();
      expect(sessions.answerCalls, hasLength(1));
    });

    testWidgets('envio com falha mostra o aviso, reabilita o botão e mantém a seleção', (tester) async {
      final (_, sessions) = await _deciding(tester);
      sessions.fail = true;
      await _answerAll(tester);

      await _tap(tester, 'gate-send');
      expect(find.text('${const SessionsException('engine parado')}'), findsOneWidget);
      expect(_send(tester).onPressed, isNotNull);
      expect(find.byIcon(Icons.radio_button_checked), findsNWidgets(3));
      expect(find.text('3 de 3 decididas'), findsOneWidget);
    });

    testWidgets('gate sem perguntas: Ajustar pede texto, Aprovar envia o rótulo do pedido', (tester) async {
      final (_, sessions) = await _open(
        tester,
        report: _report(specSession: 's-spec'),
        sessions: [_session('s-spec', command: '/challenge-spec')],
        events: {
          's-spec': [_approval()],
        },
        gate: 'spec',
      );
      expect(find.text('Aprovar a spec?'), findsWidgets);
      expect(_send(tester).onPressed, isNull);

      await _tap(tester, 'gate-option-0-1');
      expect(_send(tester).onPressed, isNull);
      await tester.enterText(_key('gate-free-0'), 'cortar o critério 2');
      await tester.pumpAndSettle();
      expect(_send(tester).onPressed, isNotNull);

      await tester.enterText(_key('gate-free-0'), '');
      await _tap(tester, 'gate-option-0-0');
      await _tap(tester, 'gate-send');
      expect(sessions.answerCalls.single.$4, {_specQuestion: 'Aprovar (Recomendado)'});
    });

    testWidgets('gate sem perguntas: Ajustar com texto envia o texto', (tester) async {
      final (_, sessions) = await _open(
        tester,
        report: _report(specSession: 's-spec'),
        sessions: [_session('s-spec', command: '/challenge-spec')],
        events: {
          's-spec': [_approval()],
        },
        gate: 'spec',
      );
      await _tap(tester, 'gate-option-0-1');
      await tester.enterText(_key('gate-free-0'), 'cortar o critério 2');
      await tester.pumpAndSettle();
      await _tap(tester, 'gate-send');
      expect(sessions.answerCalls.single.$4, {_specQuestion: 'cortar o critério 2'});
    });

    for (final (label, option) in [('Aprovar (Recomendado)', 0), ('Rejeitar', 2)]) {
      testWidgets('gate sem perguntas: texto no Ajustar não sobrepõe $label marcado', (tester) async {
        final (_, sessions) = await _open(
          tester,
          report: _report(specSession: 's-spec'),
          sessions: [_session('s-spec', command: '/challenge-spec')],
          events: {
            's-spec': [_approval()],
          },
          gate: 'spec',
        );
        await _tap(tester, 'gate-option-0-1');
        await tester.enterText(_key('gate-free-0'), 'cortar o critério 2');
        await tester.pumpAndSettle();
        await _tap(tester, 'gate-option-0-$option');
        expect(_send(tester).onPressed, isNotNull);

        await _tap(tester, 'gate-send');
        expect(sessions.answerCalls.single.$4, {_specQuestion: label});
      });
    }

    for (final status in ['approved', 'passed', 'rejected', 'revising']) {
      testWidgets('leitura com gate $status: sem envio nem opções, com as respostas', (tester) async {
        await _open(
          tester,
          report: _report(
            plan: (gate) {
              gate['status'] = status;
              final questions = (gate['questions'] as List).cast<Map<String, dynamic>>();
              questions[0]['answer'] = 'b';
              questions[1]['answer'] = {'text': 'as duas convivem'};
            },
          ),
          sessions: [_session('s-plan', pending: 0, status: SessionStatus.running)],
        );
        expect(_key('gate-send'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) => (w.key is ValueKey<String>) && (w.key! as ValueKey<String>).value.startsWith('gate-option-'),
          ),
          findsNothing,
        );
        expect(_key('gate-summary'), findsOneWidget);
        expect(_key('gate-risks'), findsOneWidget);
        expect(find.text('Opção B'), findsOneWidget);
        expect(find.text('as duas convivem'), findsOneWidget);
        expect(find.text('revisando com as suas escolhas'), status == 'revising' ? findsOneWidget : findsNothing);
        final title = tester.widget<Text>(_key('gate-title')).data;
        expect(title, switch (status) {
          'approved' => 'Plano aprovado',
          'passed' => 'Plano passou sem decisão',
          'rejected' => 'Plano rejeitado',
          _ => isNot(anyOf('Plano aprovado', 'Plano passou sem decisão', 'Plano rejeitado')),
        });
      });
    }

    testWidgets('rodada 2 mostra Você escolheu e O que mudou', (tester) async {
      await _open(
        tester,
        report: _report(
          plan: (gate) {
            gate['round'] = 2;
            gate['history'] = [
              {
                'round': 1,
                'questions': [
                  {
                    'id': 'Q0',
                    'text': 'Incluir a tela de detalhe?',
                    'options': [
                      {'id': 'a', 'label': 'Fora', 'consequence': ''},
                      {'id': 'b', 'label': 'Dentro', 'consequence': ''},
                    ],
                    'answer': 'b',
                  },
                ],
              },
            ];
            gate['changes'] = ['Tela de detalhe incluída no escopo.'];
          },
        ),
        sessions: [_session('s-plan')],
        events: {
          's-plan': [_request(_showQuestions())],
        },
      );
      expect(find.textContaining('rodada 2'), findsOneWidget);
      expect(find.text('Você escolheu'), findsOneWidget);
      expect(find.text('Incluir a tela de detalhe?'), findsOneWidget);
      expect(find.text('Dentro'), findsOneWidget);
      expect(find.text('O que mudou'), findsOneWidget);
      expect(find.text('· Tela de detalhe incluída no escopo.'), findsOneWidget);
      expect(tester.getTopLeft(_key('gate-changes')).dy, lessThan(tester.getTopLeft(_key('gate-questions')).dy));
    });

    testWidgets('rodada nova zera a seleção', (tester) async {
      final (flow, sessions) = await _deciding(tester);
      await _answerAll(tester);
      expect(find.byIcon(Icons.radio_button_checked), findsNWidgets(3));

      sessions.events['s-plan'] = [_request(_showQuestions(), id: 'rq-plan-2', seq: 9)];
      flow.current = [_gamma(_report(plan: (gate) => gate['round'] = 2))];
      sessions.update();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.radio_button_checked), findsNothing);
      expect(find.text('0 de 3 decididas'), findsOneWidget);
    });

    testWidgets('enviado → revisando → approved leva à próxima pendência', (tester) async {
      final (flow, sessions) = await _deciding(tester, also: [_session('s-other', command: 'revise o PR')]);
      await _answerAll(tester);
      await _tap(tester, 'gate-send');

      expect(find.text('registrando suas respostas'), findsOneWidget);
      expect(_key('gate-send'), findsNothing);

      flow.current = [_gamma(_report(plan: (gate) => gate['status'] = 'revising'))];
      await tester.pumpAndSettle();
      expect(find.text('revisando com as suas escolhas'), findsOneWidget);
      expect(_location(tester), '/p/$_project/gate/plan');

      flow.current = [_gamma(_report(plan: (gate) => gate['status'] = 'approved'))];
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_project/sessions/s-other');
    });

    testWidgets('approved depois do envio, com pendência só em outro projeto, vai para o Fluxo do próprio', (
      tester,
    ) async {
      final (flow, _) = await _deciding(
        tester,
        also: [
          const SessionSummary(
            id: 's-elsewhere',
            project: 'alpha',
            command: 'revise o PR',
            title: 'sessão s-elsewhere',
            status: SessionStatus.waitingPermission,
            createdAt: '2026-03-10T10:00:00Z',
            pendingPermissions: 1,
          ),
        ],
      );
      await _answerAll(tester);
      await _tap(tester, 'gate-send');

      flow.current = [_gamma(_report(plan: (gate) => gate['status'] = 'approved'))];
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/gamma/flow');
    });

    testWidgets('approved depois do envio, sem pendência, vai para o Fluxo do projeto', (tester) async {
      final (flow, _) = await _deciding(tester);
      await _answerAll(tester);
      await _tap(tester, 'gate-send');

      flow.current = [_gamma(_report(plan: (gate) => gate['status'] = 'approved'))];
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_project/flow');
    });

    testWidgets('approved sem envio nesta visita fica em leitura', (tester) async {
      final (flow, _) = await _deciding(tester);
      flow.current = [_gamma(_report(plan: (gate) => gate['status'] = 'approved'))];
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_project/gate/plan');
      expect(_key('gate-send'), findsNothing);
    });

    testWidgets('envio da rodada 1 seguido de approved na rodada 2 não navega', (tester) async {
      final (flow, _) = await _deciding(tester);
      await _answerAll(tester);
      await _tap(tester, 'gate-send');

      flow.current = [
        _gamma(
          _report(
            plan: (gate) {
              gate['round'] = 2;
              gate['status'] = 'approved';
            },
          ),
        ),
      ];
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/$_project/gate/plan');
      expect(tester.widget<Text>(_key('gate-title')).data, 'Plano aprovado');
    });

    testWidgets('rodada 2 sem perguntas mostra o ajuste da rodada 1 em Você escolheu', (tester) async {
      await _open(
        tester,
        report: _report(
          plan: (gate) {
            gate['round'] = 2;
            gate['history'] = [
              {
                'round': 1,
                'questions': <Object>[],
                'answer': {'text': 'Separar a migração em outra task.'},
              },
            ];
            gate['changes'] = ['Migração virou task própria.'];
          },
        ),
        sessions: [_session('s-plan', status: SessionStatus.running, pending: 0)],
        events: const {},
      );
      final history = _key('gate-history');
      expect(history, findsOneWidget);
      expect(find.descendant(of: history, matching: find.text('Separar a migração em outra task.')), findsOneWidget);
    });

    testWidgets('aguardando pergunta: permissão pendente oferece abrir a conversa', (tester) async {
      await _open(
        tester,
        report: _report(),
        sessions: [_session('s-plan')],
        events: {
          's-plan': [
            const PermissionRequest(
              '2026-03-10T10:05:00Z',
              requestId: 'rq-edit',
              seq: 4,
              toolName: 'Edit',
              target: 'plan.md',
            ),
          ],
        },
      );
      expect(find.text('a sessão espera outra resposta'), findsOneWidget);
      expect(_key('gate-send'), findsNothing);
      expect(_key('gate-risks'), findsOneWidget);

      await _tap(tester, 'gate-open-session');
      expect(_location(tester), '/p/$_project/sessions/s-plan');
    });

    testWidgets('aguardando pergunta: sessão encerrada', (tester) async {
      await _open(
        tester,
        report: _report(),
        sessions: [_session('s-plan', status: SessionStatus.done, pending: 0)],
      );
      expect(find.text('sessão encerrada, retome em Sessões'), findsOneWidget);
    });

    testWidgets('voltar leva à última rota do shell', (tester) async {
      await _open(tester, report: _report(), from: '/p/$_project/runs');
      await _tap(tester, 'gate-back');
      expect(_location(tester), '/p/$_project/runs');
    });

    testWidgets('Pular vai para a próxima pendência', (tester) async {
      await _deciding(tester, also: [_session('s-other', command: 'revise o PR')]);
      expect(find.text('Pendência 1 de 2'), findsOneWidget);
      await _tap(tester, 'gate-skip');
      expect(_location(tester), '/p/$_project/sessions/s-other');
    });

    testWidgets('opções, voltar, Pular e envio têm pelo menos 44 de altura', (tester) async {
      await _deciding(tester, also: [_session('s-other', command: 'revise o PR')]);
      for (final key in ['gate-option-0-0', 'gate-option-2-1', 'gate-back', 'gate-skip', 'gate-send']) {
        expect(tester.getSize(_key(key)).height, greaterThanOrEqualTo(44), reason: key);
      }
    });
  });

  group('gate pr', () {
    testWidgets('abre a tela com cada ponto em ordem: texto, porquê, âncora, trecho e opções; sem free nem artifact', (
      tester,
    ) async {
      await _openPr(tester);
      final questions = _prQuestions();

      expect(_key('gate-unavailable'), findsNothing);
      expect(tester.widget<Text>(_key('gate-title')).data, '2 pontos antes do PR');
      for (var i = 0; i < 2; i++) {
        final keys = [
          'gate-point-$i-text',
          'gate-point-$i-why',
          'gate-point-$i-anchor',
          'gate-point-$i-excerpt',
          for (var o = 0; o < questions[i].options.length; o++) 'gate-option-$i-$o',
        ];
        final tops = [for (final k in keys) tester.getTopLeft(_key(k)).dy];
        for (var k = 1; k < tops.length; k++) {
          expect(tops[k], greaterThan(tops[k - 1]), reason: '${keys[k]} abaixo de ${keys[k - 1]}');
        }
        for (final (o, option) in questions[i].options.indexed) {
          expect(find.descendant(of: _key('gate-option-$i-$o'), matching: find.text(option.label)), findsOneWidget);
        }
      }
      expect(tester.widget<Text>(_key('gate-point-0-text')).data, questions[0].question);
      expect(tester.widget<Text>(_key('gate-point-0-why')).data, 'O acesso direto acopla a view à camada de dados.');
      expect(
        find.descendant(of: _key('gate-point-0-anchor'), matching: find.text('lib/delta/view.dart:13-13')),
        findsOneWidget,
      );
      expect(_lines('gate-point-0-excerpt'), findsNWidgets(7));
      expect(_lines('gate-point-1-excerpt'), findsNWidgets(5));
      expect(_keyPrefix('gate-free-'), findsNothing);
      expect(_key('gate-artifact'), findsNothing);
      expect(_keyPrefix('gate-change-'), findsNothing);
    });

    testWidgets('a opção Pedir ajuste abre o campo; o envio exige texto na mudança e habilita com ok nos dois', (
      tester,
    ) async {
      await _openPr(tester);

      await _tap(tester, 'gate-option-0-1');
      expect(_key('gate-change-0'), findsOneWidget);
      await _tap(tester, 'gate-option-1-0');
      expect(_key('gate-change-1'), findsNothing);
      expect(_send(tester).onPressed, isNull);
      expect(find.text('1 de 2 decididas'), findsOneWidget);

      await tester.enterText(_key('gate-change-0'), 'injetar pelo construtor');
      await tester.pumpAndSettle();
      expect(_send(tester).onPressed, isNotNull);

      await tester.enterText(_key('gate-change-0'), '   ');
      await tester.pumpAndSettle();
      expect(_send(tester).onPressed, isNull);

      await _tap(tester, 'gate-option-0-0');
      expect(_key('gate-change-0'), findsNothing);
      expect(_send(tester).onPressed, isNotNull);
      expect(find.text('2 de 2 decididas'), findsOneWidget);
    });

    testWidgets('envia uma vez o rótulo do ok e o texto da mudança; enviado não mostra o diff completo', (
      tester,
    ) async {
      final (_, sessions, _) = await _openPr(tester);
      final questions = _prQuestions();

      await _tap(tester, 'gate-option-0-0');
      await _tap(tester, 'gate-option-1-1');
      await tester.enterText(_key('gate-change-1'), '  cobrir o legado com teste  ');
      await tester.pumpAndSettle();
      await _tap(tester, 'gate-send');

      expect(sessions.answerCalls, hasLength(1));
      final (id, requestId, decision, answers) = sessions.answerCalls.single;
      expect((id, requestId, decision), ('s-complete', 'rq-pr', PermissionDecision.answer));
      expect(answers, {questions[0].question: 'Aprovar', questions[1].question: 'cobrir o legado com teste'});
      expect(find.text('registrando suas respostas'), findsOneWidget);
      expect(_key('gate-diff-full'), findsNothing);
    });

    testWidgets('trocar de mudança para ok depois de digitar envia o rótulo, não o texto', (tester) async {
      final (_, sessions, _) = await _openPr(tester);
      final questions = _prQuestions();

      await _tap(tester, 'gate-option-0-0');
      await _tap(tester, 'gate-option-1-1');
      await tester.enterText(_key('gate-change-1'), 'cobrir o legado');
      await tester.pumpAndSettle();
      await _tap(tester, 'gate-option-1-0');
      await _tap(tester, 'gate-send');

      expect(sessions.answerCalls.single.$4, {questions[0].question: 'Aprovar', questions[1].question: 'Aprovar'});
    });

    testWidgets('sem perguntas: Abrir o PR?, Ajustar sem texto não envia e Aprovar envia o rótulo', (tester) async {
      const question = 'Abrir o PR?';
      final (_, sessions, _) = await _openPr(
        tester,
        report: _deltaReport(gate: (gate) => gate['questions'] = <Object>[]),
        events: {
          's-complete': [
            _request(const [
              Question(
                question: question,
                header: 'pr',
                options: [
                  QuestionOption('Aprovar (Recommended)', 'abre o PR'),
                  QuestionOption('Ajustar', 'descreva o ajuste'),
                  QuestionOption('Rejeitar', 'encerra a etapa'),
                ],
              ),
            ], id: 'rq-pr'),
          ],
        },
      );
      expect(tester.widget<Text>(_key('gate-title')).data, question);
      expect(_key('gate-diff-full'), findsOneWidget);

      await _tap(tester, 'gate-option-0-1');
      expect(_send(tester).onPressed, isNull);

      await _tap(tester, 'gate-option-0-0');
      await _tap(tester, 'gate-send');
      expect(sessions.answerCalls.single.$4, {question: 'Aprovar (Recommended)'});
    });

    for (final (name, docs) in [
      ('erro', MockDocsRepository.empty),
      ('tooLarge', () => _docs('x' * (2 * 1024 * 1024 + 1))),
    ]) {
      testWidgets('diff indisponível ($name): trechos avisam, sem diff completo, e o envio funciona', (tester) async {
        await _openPr(tester, docs: docs());

        expect(_key('gate-diff-full'), findsNothing);
        for (var i = 0; i < 2; i++) {
          expect(
            find.descendant(of: _key('gate-point-$i-excerpt'), matching: find.text('diff indisponível')),
            findsOneWidget,
          );
        }
        await _tap(tester, 'gate-option-0-0');
        await _tap(tester, 'gate-option-1-0');
        expect(_send(tester).onPressed, isNotNull);
      });
    }

    testWidgets('âncora de caminho ausente do diff mostra trecho fora do diff e mantém o rótulo', (tester) async {
      await _openPr(
        tester,
        report: _deltaReport(
          gate: (gate) => ((gate['questions'] as List).first as Map<String, dynamic>)['anchor'] = {
            'path': 'lib/delta/missing.dart',
            'start': 4,
            'end': 9,
          },
        ),
      );

      expect(
        find.descendant(of: _key('gate-point-0-excerpt'), matching: find.text('trecho fora do diff')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _key('gate-point-0-anchor'), matching: find.text('lib/delta/missing.dart:4-9')),
        findsOneWidget,
      );
      expect(_lines('gate-point-1-excerpt'), findsNWidgets(5));
    });

    testWidgets('diff completo começa recolhido com a contagem e abre arquivo por arquivo', (tester) async {
      await _openPr(tester);
      final full = _key('gate-diff-full');

      expect(find.descendant(of: full, matching: find.text('3 arquivos, +8 −4')), findsOneWidget);
      expect(find.descendant(of: full, matching: find.byType(DiffLineView)), findsNothing);
      expect(_key('gate-diff-file-0'), findsNothing);

      await _tap(tester, 'gate-diff-full-toggle');
      expect(_keyPrefix('gate-diff-file-'), findsNWidgets(3));
      expect(find.descendant(of: full, matching: find.byType(DiffLineView)), findsNothing);

      await _tap(tester, 'gate-diff-file-1');
      expect(find.descendant(of: full, matching: find.byType(DiffLineView)), findsNWidgets(5));
    });

    testWidgets('diff de 33 arquivos e mais de 3 400 linhas: recolhido não desenha linhas e aberto para em 400', (
      tester,
    ) async {
      final text = _bigDiff();
      expect(text.length, lessThan(kIsolateParseThreshold));
      expect('\n'.allMatches(text).length, greaterThan(3400));
      await _openPr(tester, docs: _docs(text));
      final enabled = _send(tester).onPressed != null;

      expect(find.descendant(of: _key('gate-diff-full'), matching: find.text('33 arquivos, +3700 −0')), findsOneWidget);
      expect(find.byType(DiffLineView), findsNothing);

      await _tap(tester, 'gate-diff-full-toggle');
      expect(find.byType(DiffLineView), findsNothing);
      await _tap(tester, 'gate-diff-file-0');
      expect(find.byType(DiffLineView), findsNWidgets(400));
      expect(find.text('mais 100 linhas neste arquivo'), findsOneWidget);
      expect(_send(tester).onPressed != null, enabled);
    });

    testWidgets('o pr.diff é lido uma vez por rodada', (tester) async {
      final (flow, _, docs) = await _openPr(tester);

      await _tap(tester, 'gate-option-0-0');
      await _tap(tester, 'gate-option-1-1');
      await _tap(tester, 'gate-diff-full-toggle');
      await _tap(tester, 'gate-diff-file-0');
      expect(docs.reads['pr.diff'], 1);

      flow.current = [_deltaProject(_deltaReport(gate: (gate) => gate['round'] = 2))];
      await tester.pumpAndSettle();
      expect(docs.reads['pr.diff'], 2);
    });

    testWidgets('gate plan não lê o pr.diff', (tester) async {
      final (_, _, docs) = await _openPr(
        tester,
        projects: [_gamma(_report())],
        project: _project,
        gate: 'plan',
        sessions: [_session('s-plan')],
        events: {
          's-plan': [_request(_showQuestions())],
        },
      );
      expect(_key('gate-questions'), findsOneWidget);
      expect(docs.reads['pr.diff'] ?? 0, 0);
    });

    testWidgets('pr aberto com a sessão esperando outra pergunta: aguardando, pontos sem opções e diff completo', (
      tester,
    ) async {
      await _openPr(
        tester,
        events: {
          's-complete': [
            _request(const [
              Question(
                question: 'Encerrar o ciclo agora?',
                header: 'fim',
                options: [QuestionOption('Sim', ''), QuestionOption('Não', '')],
              ),
            ], id: 'rq-end'),
          ],
        },
      );

      expect(find.text('a sessão espera outra resposta'), findsOneWidget);
      expect(_key('gate-open-session'), findsOneWidget);
      expect(_key('gate-send'), findsNothing);
      expect(_keyPrefix('gate-option-'), findsNothing);
      expect(_key('gate-point-1-why'), findsOneWidget);
      expect(_lines('gate-point-0-excerpt'), findsNWidgets(7));
      expect(_key('gate-diff-full'), findsOneWidget);
    });
  });

  group('gate pr depois do envio', () {
    void answerBoth(Map<String, dynamic> gate, {required bool optionForm, required String status}) {
      gate['status'] = status;
      final questions = (gate['questions'] as List).cast<Map<String, dynamic>>();
      for (final (i, q) in questions.indexed) {
        if (optionForm) {
          q['answer'] = 'change';
          q['answer_text'] = 'ajuste ${i + 1}';
        } else {
          q['answer'] = {'text': 'ajuste ${i + 1}'};
        }
      }
    }

    for (final optionForm in [false, true]) {
      final form = optionForm ? 'change + answer_text' : 'answer {text}';
      for (final (tasks, line) in [
        (2, '2 pontos viraram tasks; o gate reabre depois do verify'),
        (1, '1 ponto virou task; o gate reabre depois do verify'),
        (0, null),
      ]) {
        testWidgets('revisando ($form, $tasks tasks): voltou à implementação, os pedidos e a contagem', (tester) async {
          await _openPr(
            tester,
            report: _deltaReport(
              gate: (gate) => answerBoth(gate, optionForm: optionForm, status: 'revising'),
            ),
            sessions: [_completeSession(status: SessionStatus.done, pending: 0)],
            events: const {},
            plan: [_task('T1'), for (var i = 1; i <= tasks; i++) _task('P1.$i'), _task('P2.1')],
          );

          expect(find.text('voltou à implementação'), findsOneWidget);
          final asked = _key('gate-asked');
          expect(find.descendant(of: asked, matching: find.text('ajuste 1')), findsOneWidget);
          expect(find.descendant(of: asked, matching: find.text('ajuste 2')), findsOneWidget);
          if (line == null) {
            expect(_key('gate-task-count'), findsNothing);
          } else {
            expect(find.text(line), findsOneWidget);
          }
          expect(_key('gate-diff-full'), findsNothing);
          expect(_key('flow-pr'), findsNothing);
        });
      }
    }

    testWidgets('revisando sem perguntas: ajuste pedido, o texto e /fix, sem contagem', (tester) async {
      await _openPr(
        tester,
        report: _deltaReport(
          gate: (gate) {
            gate['status'] = 'revising';
            gate['questions'] = <Object>[];
            gate['answer'] = {'text': 'Renomear o repositório.'};
          },
        ),
        sessions: [_completeSession(status: SessionStatus.done, pending: 0)],
        events: const {},
        plan: [_task('P1.1')],
      );

      expect(find.text('ajuste pedido'), findsOneWidget);
      expect(find.text('Renomear o repositório.'), findsOneWidget);
      expect(find.text('aplique com /fix na sessão'), findsOneWidget);
      expect(_key('gate-task-count'), findsNothing);
      expect(find.text('voltou à implementação'), findsNothing);
      expect(_key('gate-diff-full'), findsNothing);
    });

    for (final status in ['approved', 'passed', 'revising']) {
      testWidgets('com PR no relatório, $status mostra o link aberto pelo opener', (tester) async {
        final (_, _, docs) = await _openPr(
          tester,
          report: _deltaReport(
            gate: (gate) => answerBoth(gate, optionForm: false, status: status),
            doc: (doc) => doc['pr'] = {'url': 'https://github.com/acme/delta/pull/7', 'number': 7},
          ),
          sessions: [_completeSession(status: SessionStatus.done, pending: 0)],
          events: const {},
        );

        expect(_key('flow-pr'), findsOneWidget);
        expect(find.text('voltou à implementação'), findsNothing);
        expect(_key('gate-diff-full'), status == 'revising' ? findsNothing : findsOneWidget);
        if (status != 'revising') {
          expect(find.descendant(of: _key('gate-point-0-answer'), matching: find.text('ajuste 1')), findsOneWidget);
          expect(_keyPrefix('gate-option-'), findsNothing);
          expect(_lines('gate-point-0-excerpt'), findsNWidgets(7));
        }
        await _tap(tester, 'flow-pr-link');
        expect(docs.opened, [Uri.parse('https://github.com/acme/delta/pull/7')]);
      });
    }

    testWidgets('rodada 2: Você escolheu mostra o texto pedido e O que mudou lista as mudanças', (tester) async {
      await _openPr(
        tester,
        report: _deltaReport(
          gate: (gate) {
            final questions = (gate['questions'] as List).cast<Map<String, dynamic>>();
            gate['round'] = 2;
            gate['history'] = [
              {
                'round': 1,
                'questions': [
                  {...questions[0], 'answer': 'change', 'answer_text': 'Injetar o repositório pelo construtor.'},
                  {...questions[1], 'answer': 'ok'},
                ],
              },
            ];
            gate['changes'] = ['Repositório injetado pelo construtor.'];
          },
        ),
      );

      final history = _key('gate-history');
      expect(
        find.descendant(of: history, matching: find.text('Injetar o repositório pelo construtor.')),
        findsOneWidget,
      );
      expect(find.descendant(of: history, matching: find.text('Aprovar')), findsOneWidget);
      expect(
        find.descendant(of: _key('gate-changes'), matching: find.text('· Repositório injetado pelo construtor.')),
        findsOneWidget,
      );
      expect(_key('gate-point-0-text'), findsOneWidget);
    });
  });
}
