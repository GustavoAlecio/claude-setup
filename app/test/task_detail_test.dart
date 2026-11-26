import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/features/runs/task_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _impl = 'impl-20260310T100000Z';
const _verify = 'verify-20260310T110000Z';
const _root = '/dev/tela';
const _planDescription = 'Descrição que só o plano traz.';

Finding _finding(String rule, String message, {String severity = 'major', String file = 'lib/a.dart', int? line}) =>
    Finding(gate: 'g1', severity: severity, file: file, ruleRef: rule, message: message, line: line);

Attempt _attempt(
  int n,
  Tier tier, {
  Verdict verdict = Verdict.fail,
  List<Finding> findings = const [],
  Tier? escalatedTo,
  int? tokensOut,
}) => Attempt(
  number: n,
  ordinal: n,
  tier: tier,
  gates: [GateResult('g1', verdict, findings)],
  escalatedTo: escalatedTo,
  tokensOut: tokensOut,
);

Hypothesis _hypothesis(String action, double confidence) =>
    Hypothesis(lens: 'x', hypothesis: 'hipótese $action', confidence: confidence, evidence: const [], action: action);

TaskRun _task(
  String id,
  Verdict status, {
  List<Attempt> attempts = const [],
  List<String> files = const [],
  String? description,
  List<Hypothesis> diagnosis = const [],
  LiveStage? stage,
}) => TaskRun(
  id: id,
  title: 'Titulo $id',
  complexity: Complexity.m,
  tier0: Tier.haiku,
  status: status,
  attempts: attempts,
  files: files,
  description: description,
  blockedReason: status == Verdict.blocked ? 'max_attempts' : null,
  diagnosis: diagnosis,
  stage: stage,
);

final _blocked = _task(
  'T2',
  Verdict.blocked,
  attempts: [
    _attempt(
      1,
      Tier.haiku,
      findings: [
        _finding('regra-a', 'primeira mensagem', file: '$_root/lib/a.dart', line: 12),
        _finding('regra-b', 'segunda mensagem', file: 'lib/b.dart'),
      ],
      escalatedTo: Tier.sonnet,
      tokensOut: 1000,
    ),
    _attempt(
      2,
      Tier.sonnet,
      findings: [_finding('regra-a', 'primeira mensagem', file: '$_root/lib/a.dart', line: 12)],
      tokensOut: 500,
    ),
  ],
  files: const ['lib/a.dart', 'lib/b.dart'],
  diagnosis: [_hypothesis('replan', 0.9), _hypothesis('fix_spec', 0.5), _hypothesis('split_task', 0.2)],
);

List<Project> _data({List<TaskRun>? tasks, List<Run> newer = const []}) => [
  Project(
    name: 'tela',
    path: _root,
    cycle: Cycle(
      stage: Stage.implement,
      stageMinutes: const {},
      // Newest first, like the file repository returns it.
      runs: [
        ...newer,
        Run(
          id: _impl,
          kind: 'implement',
          status: Verdict.blocked,
          startedAt: '10/03 10:00',
          tasks:
              tasks ??
              [
                _task('T1', Verdict.pass, attempts: [_attempt(1, Tier.haiku, verdict: Verdict.pass)]),
                _blocked,
              ],
        ),
      ],
      plan: [
        _task('T1', Verdict.pending),
        _task('T2', Verdict.pending, description: _planDescription),
        _task('T3', Verdict.pending),
      ],
    ),
  ),
];

Finder _key(String key) => find.byKey(ValueKey(key));

Finder _in(String key, Finder matching) => find.descendant(of: _key(key), matching: matching);

String _uri(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first)).routerDelegate.currentConfiguration.uri.toString();

Future<void> _pump(WidgetTester tester, List<Project> data, {String? location}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: data),
      sessions: MockSessionsRepository(),
      engine: const MockEngineController(),
    ),
  );
  await tester.pumpAndSettle();
  if (location == null) return;
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('the headline places the task in the cycle table', (tester) async {
    await _pump(tester, _data(), location: taskLocation('tela', _impl, 'T2'));

    expect(find.text('Titulo T2'), findsOneWidget);
    expect(
      tester.widget<Text>(_key('task-headline')).data,
      'Task 2 de 3 · travou após 2 tentativas · escalou de haiku para sonnet',
    );
    expect(tester.takeException(), isNull);
  });

  test('taskLocation with showOthers ends in others=1', () {
    expect(taskLocation('tela', _impl, 'T2', showOthers: true), '/p/tela/runs/$_impl/T2?others=1');
    expect(taskLocation('tela', _impl, 'T2', fromRuns: true, showOthers: true), endsWith('?from=runs&others=1'));
    expect(taskLocation('tela', _impl, 'T2', fromRuns: true), '/p/tela/runs/$_impl/T2?from=runs');
  });

  testWidgets('without others=1 the other hypotheses stay closed', (tester) async {
    await _pump(tester, _data(), location: taskLocation('tela', _impl, 'T2', fromRuns: true));

    expect(_key('task-decide'), findsOneWidget);
    expect(_key('task-hypothesis-1'), findsNothing);
  });

  testWidgets('others=1 opens the task with the other hypotheses showing, and they still fold', (tester) async {
    await _pump(tester, _data(), location: taskLocation('tela', _impl, 'T2', fromRuns: true, showOthers: true));

    expect(_key('task-hypothesis-1'), findsOneWidget);
    expect(_key('task-hypothesis-2'), findsOneWidget);
    expect(_in('task-back', find.text('Execuções')), findsOneWidget);

    await _tap(tester, _key('task-other-options'));
    expect(_key('task-hypothesis-1'), findsNothing);
  });

  testWidgets('a task outside the cycle table has no position in the headline', (tester) async {
    final verify = Run(
      id: _verify,
      kind: 'verify',
      status: Verdict.pass,
      startedAt: '10/03 11:00',
      tasks: [
        _task('V1', Verdict.pass, attempts: [_attempt(1, Tier.haiku, verdict: Verdict.pass)]),
      ],
    );
    await _pump(tester, _data(newer: [verify]), location: taskLocation('tela', _verify, 'V1'));

    expect(tester.widget<Text>(_key('task-headline')).data, 'pronta de primeira');
  });

  testWidgets('attempts run down the page and "e mais N" opens and closes the other findings', (tester) async {
    await _pump(tester, _data(), location: taskLocation('tela', _impl, 'T2'));

    final first = _key('task-attempt-1');
    final second = _key('task-attempt-2');
    expect(_in('task-attempts', find.text('O que aconteceu')), findsOneWidget);
    expect(tester.getTopLeft(second).dy, greaterThan(tester.getTopLeft(first).dy));
    expect(tester.getTopLeft(second).dx, tester.getTopLeft(first).dx);

    expect(_in('task-attempt-1', find.text('Tentativa 1')), findsOneWidget);
    expect(_in('task-attempt-1', find.text('haiku · reprovada em G1')), findsOneWidget);
    expect(_in('task-attempt-1', find.text('primeira mensagem')), findsOneWidget);
    expect(_in('task-attempt-1', find.text('lib/a.dart:12')), findsOneWidget, reason: 'relative to the project');
    expect(_in('task-attempt-1', find.text('regra-a')), findsOneWidget);
    expect(_in('task-attempt-1', find.textContaining('haiku → sonnet')), findsOneWidget);
    expect(_in('task-attempt-2', find.text('sonnet · mesma falha da tentativa 1')), findsOneWidget);
    expect(_in('task-attempt-2', find.text(blockedReasonText('max_attempts'))), findsOneWidget);
    expect(_key('task-attempt-2-more'), findsNothing);

    final more = _key('task-attempt-1-more');
    expect(find.descendant(of: more, matching: find.text('e mais 1')), findsOneWidget);
    expect(find.text('segunda mensagem'), findsNothing);
    await _tap(tester, more);
    expect(_in('task-attempt-1', find.text('segunda mensagem')), findsOneWidget);
    expect(_in('task-attempt-1', find.text('lib/b.dart')), findsOneWidget);
    expect(_in('task-attempt-1', find.text('regra-b')), findsOneWidget);
    await _tap(tester, more);
    expect(find.text('segunda mensagem'), findsNothing);

    expect(
      find.descendant(
        of: find.byType(TaskDetailPage),
        matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a task without attempts says so', (tester) async {
    await _pump(tester, _data(tasks: [_task('T1', Verdict.pending)]), location: taskLocation('tela', _impl, 'T1'));

    expect(_in('task-attempts', find.text('Ainda não houve tentativa.')), findsOneWidget);
    expect(tester.widget<Text>(_key('task-headline')).data, 'Task 1 de 3 · na fila');
  });

  testWidgets('description and files start collapsed; the description falls back to the plan', (tester) async {
    await _pump(tester, _data(), location: taskLocation('tela', _impl, 'T2'));

    final description = find.text(_planDescription, findRichText: true);
    expect(description, findsNothing);
    expect(find.text('lib/b.dart'), findsNothing);
    expect(find.descendant(of: _key('task-files-toggle'), matching: find.text('Arquivos tocados (2)')), findsOneWidget);

    await _tap(tester, _key('task-description-toggle'));
    expect(description, findsOneWidget);
    expect(find.ancestor(of: description, matching: find.byType(SelectionArea)), findsOneWidget);

    await _tap(tester, _key('task-files-toggle'));
    expect(_in('task-files', find.text('lib/a.dart')), findsOneWidget);
    expect(_in('task-files', find.text('lib/b.dart')), findsOneWidget);

    await _tap(tester, _key('task-description-toggle'));
    expect(description, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the description of the run wins and renders markdown without raw markers', (tester) async {
    const own = '**Contexto:** Passo 2 do plano.\n\n**O que fazer:**\n- Criar `lib/x.dart`';
    final tasks = [
      _task(
        'T2',
        Verdict.pass,
        attempts: [_attempt(1, Tier.haiku, verdict: Verdict.pass)],
        description: own,
      ),
    ];
    await _pump(tester, _data(tasks: tasks), location: taskLocation('tela', _impl, 'T2'));
    await _tap(tester, _key('task-description-toggle'));

    expect(find.text(_planDescription, findRichText: true), findsNothing);
    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('`', findRichText: true), findsNothing);
    expect(find.textContaining('•', findRichText: true), findsWidgets);
    expect(find.text('lib/x.dart', findRichText: true), findsOneWidget);
  });

  testWidgets('without description, files or tokens those items do not exist', (tester) async {
    await _pump(tester, _data(), location: taskLocation('tela', _impl, 'T1'));

    expect(_key('task-description-toggle'), findsNothing);
    expect(_key('task-files-toggle'), findsNothing);
    expect(_key('task-footer'), findsOneWidget);
    expect(_in('task-footer', find.textContaining('tokens out')), findsNothing);
    expect(_key('task-open-run'), findsOneWidget);
  });

  testWidgets('the footer shows the tokens when known and leads to the Execuções', (tester) async {
    await _pump(tester, _data(), location: taskLocation('tela', _impl, 'T2'));

    expect(_in('task-footer', find.text('1.5k tokens out')), findsOneWidget);
    await _tap(tester, _key('task-open-run'));
    expect(_uri(tester), '/p/tela/runs');
  });

  testWidgets('from the cycle card, back says Ciclo and returns to the Fluxo', (tester) async {
    await _pump(tester, _data(), location: '/p/tela/flow');
    await _tap(tester, _key('cycle-now-action'));
    expect(_uri(tester), '/p/tela/runs/$_impl/T2');

    final back = _key('task-back');
    expect(find.descendant(of: back, matching: find.text('Ciclo')), findsOneWidget);
    await _tap(tester, back);
    expect(_uri(tester), '/p/tela/flow');
  });

  testWidgets('from a row of the Execuções, back says Execuções and returns there', (tester) async {
    await _pump(tester, _data(), location: '/p/tela/runs');
    await _tap(tester, find.text('Titulo T1'));
    expect(_uri(tester), '/p/tela/runs/$_impl/T1?from=runs');

    final back = _key('task-back');
    expect(find.descendant(of: back, matching: find.text('Execuções')), findsOneWidget);
    await _tap(tester, back);
    expect(_uri(tester), '/p/tela/runs');
  });

  testWidgets('a running task keeps the live section and has no decision card', (tester) async {
    final tasks = [
      _task(
        'T1',
        Verdict.running,
        attempts: [_attempt(1, Tier.haiku, verdict: Verdict.running)],
        stage: LiveStage('implementando', DateTime.now()),
      ),
    ];
    await _pump(tester, _data(tasks: tasks), location: taskLocation('tela', _impl, 'T1'));

    expect(find.text('Em andamento'), findsOneWidget);
    expect(find.text('implementando'), findsOneWidget);
    expect(tester.widget<Text>(_key('task-headline')).data, 'Task 1 de 3 · rodando, tentativa 1');
    expect(_in('task-attempt-1', find.text('haiku · rodando')), findsOneWidget);
    expect(_key('task-decide'), findsNothing);
  });

  testWidgets('1100×700 with a 300-char message and a 120-char path does not overflow', (tester) async {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1100, 700);

    final message = 'm' * 300;
    final path = 'lib/${'d' * 106}/file.dart';
    expect(path.length, 120);
    Attempt failed(int n, Tier tier, String rule) => _attempt(
      n,
      tier,
      findings: [
        _finding(rule, message, file: path, line: 1234),
        _finding('$rule-outra', message, file: path),
      ],
    );
    final tasks = [
      TaskRun(
        id: 'T2',
        title: 'Titulo ${'longo ' * 30}',
        complexity: Complexity.m,
        tier0: Tier.haiku,
        status: Verdict.blocked,
        blockedReason: 'same_failure_across_tiers',
        attempts: [failed(1, Tier.haiku, 'a'), failed(2, Tier.sonnet, 'b'), failed(3, Tier.opus, 'a')],
        files: [path],
        diagnosis: [
          for (final (i, action) in ['replan', 'fix_spec', 'split_task'].indexed)
            Hypothesis(lens: 'x', hypothesis: 'h' * 300, confidence: 0.9 - i * 0.2, evidence: [path], action: action),
        ],
      ),
    ];
    await _pump(tester, _data(tasks: tasks), location: taskLocation('tela', _impl, 'T2'));

    expect(_key('task-decide'), findsOneWidget);
    expect(_key('task-attempt-3'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _tap(tester, _key('task-other-options'));
    for (final toggle in ['task-attempt-1-more', 'task-description-toggle', 'task-files-toggle']) {
      await _tap(tester, _key(toggle));
    }
    expect(_in('task-files', find.text(path)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
