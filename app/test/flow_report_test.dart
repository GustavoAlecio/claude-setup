import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/theme/app_colors.dart';
import 'package:claude_flow/core/widgets/primitives.dart';
import 'package:claude_flow/data/file_flow_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _fixtures = 'test/fixtures/workflow';
final _stacksDir = Directory('test/fixtures/stacks').absolute.path;
const _names = ['alpha', 'beta', 'broken', 'gamma', 'legacy'];

Future<List<Project>> _loadFixtures(WidgetTester tester) async {
  final projects = await tester.runAsync(() async {
    final repo = FileFlowRepository(Directory(_fixtures).absolute.path, stacksDir: _stacksDir);
    try {
      return await repo
          .watchProjects()
          .firstWhere((l) => _names.every((n) => l.any((p) => p.name == n)))
          .timeout(const Duration(seconds: 10));
    } finally {
      await repo.dispose();
    }
  });
  return projects!;
}

class _Sessions extends MockSessionsRepository {
  _Sessions(this.list);

  final List<SessionSummary> list;

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.value(list);
}

Future<void> _open(
  WidgetTester tester,
  List<Project> data,
  String location, {
  SessionsRepository? sessions,
  bool settle = true,
  Size size = const Size(1600, 3200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: data),
      sessions: sessions ?? _Sessions(const []),
      engine: const MockEngineController(),
    ),
  );
  await tester.pump();
  _router(tester).go(location);
  // The Fluxo side panel shows a running session, whose typing indicator never settles.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.toString();

Finder _stage(Stage s) => find.byKey(ValueKey('timeline-stage-${s.name}'));

Finder _inStage(Stage s, Finder matching) => find.descendant(of: _stage(s), matching: matching);

Finder _inPanel(String key, Finder matching) => find.descendant(of: find.byKey(ValueKey(key)), matching: matching);

Future<void> _expand(WidgetTester tester, Stage s) async {
  final chevron = find.byKey(ValueKey('timeline-chevron-${s.name}'));
  await tester.tap(chevron.evaluate().isNotEmpty ? chevron : _inStage(s, find.text(s.label)));
  await tester.pumpAndSettle();
}

AppColors _colors(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).first)).extension<AppColors>()!;

SessionSummary _session(
  String id, {
  String project = 'web-console',
  String command = '/kickoff',
  SessionStatus status = SessionStatus.running,
  String createdAt = '2026-03-10T10:00:00Z',
  String? org,
}) => SessionSummary(
  id: id,
  project: project,
  command: command,
  title: 'sessão $id',
  status: status,
  createdAt: createdAt,
  org: org,
);

void main() {
  group('linha do tempo com relatório (gamma, gen.sh)', () {
    testWidgets('as 8 etapas na ordem do enum, com status do relatório', (tester) async {
      final data = await _loadFixtures(tester);
      await _open(tester, data, '/p/gamma/flow');

      final tops = [for (final s in Stage.values) tester.getTopLeft(_stage(s)).dy];
      expect(tops, [...tops]..sort());
      expect(tops.toSet(), hasLength(Stage.values.length));
      expect(_inStage(Stage.verify, find.text('em andamento')), findsOneWidget);
      expect(_inStage(Stage.complete, find.text('sem relatório desta etapa')), findsOneWidget);
      expect(find.text('sem relatório desta etapa'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('abrir uma etapa mostra resumo, achados, decisões e tentativas; fechar esconde', (tester) async {
      final data = await _loadFixtures(tester);
      await _open(tester, data, '/p/gamma/flow');
      final report = find.byKey(const ValueKey('timeline-report-challenge'));
      expect(report, findsNothing);

      await _expand(tester, Stage.challenge);

      expect(report, findsOneWidget);
      Finder inReport(String text) =>
          find.descendant(of: report, matching: find.textContaining(text, findRichText: true));
      expect(inReport('1 achado aceito e 1 rejeitado.'), findsOneWidget);
      expect(inReport('Achados · spec-challenger'), findsOneWidget);
      expect(inReport('C1'), findsWidgets);
      expect(inReport('motivo: Fora do escopo da fase.'), findsOneWidget);
      expect(inReport('Critério C1 reescrito como verificável.'), findsOneWidget);
      expect(find.descendant(of: report, matching: find.text('challenger')), findsOneWidget);
      expect(find.descendant(of: report, matching: find.text('user')), findsOneWidget);
      expect(inReport('1 tentativa(s)'), findsOneWidget);

      await _expand(tester, Stage.challenge);
      expect(report, findsNothing);
    });

    testWidgets('mistake aparece com a cor fail e a decisão comum não', (tester) async {
      final data = await _loadFixtures(tester);
      await _open(tester, data, '/p/gamma/flow');
      await _expand(tester, Stage.plan);
      final fail = _colors(tester).fail;
      final report = find.byKey(const ValueKey('timeline-report-plan'));

      Finder tileOf(String text) => find
          .ancestor(
            of: find.descendant(of: report, matching: find.textContaining(text, findRichText: true)),
            matching: find.byWidgetPredicate((w) => w is Container && w.key is ValueKey<String>),
          )
          .first;
      bool hasFailText(Finder tile) => tester
          .widgetList<RichText>(find.descendant(of: tile, matching: find.byType(RichText)))
          .any((t) => _spans(t.text).any((s) => s.style?.color == fail && (s.text ?? '').contains('Plano inicial')));

      final mistake = tileOf('Plano inicial pedia leitura em widget');
      expect(hasFailText(mistake), isTrue);
      expect(
        find.descendant(
          of: mistake,
          matching: find.byWidgetPredicate((w) => w is Pill && w.label == 'erro' && w.color == fail),
        ),
        findsOneWidget,
      );

      final normal = tileOf('Estado em um único cubit.');
      expect(
        find.descendant(of: normal, matching: find.byWidgetPredicate((w) => w is Pill && w.color == fail)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: normal,
          matching: find.textContaining('alternativa: Um cubit por seção.', findRichText: true),
        ),
        findsOneWidget,
      );
    });

    testWidgets('artefato leva à aba Artefatos com o doc', (tester) async {
      final data = await _loadFixtures(tester);
      await _open(tester, data, '/p/gamma/flow');
      await _expand(tester, Stage.specify);

      await tester.tap(find.widgetWithText(TextButton, 'spec.md'));
      await tester.pumpAndSettle();

      expect(_location(tester), '/p/gamma/artifacts?doc=spec.md');
    });

    testWidgets('Decisões junta todas as etapas e filtra por autor', (tester) async {
      final data = await _loadFixtures(tester);
      await _open(tester, data, '/p/gamma/flow');
      Finder panelText(String t) => _inPanel('flow-decisions', find.textContaining(t, findRichText: true));

      for (final t in [
        'Uma tela, sem fluxo de edição.',
        'Critério C1 reescrito como verificável.',
        'Manter o escopo sem cache offline.',
        'Estado em um único cubit.',
        'View sem estado próprio.',
        'Modelo imutável escrito à mão.',
      ]) {
        expect(panelText(t), findsOneWidget, reason: t);
      }
      final order = [
        for (final t in ['Uma tela', 'Critério C1', 'Estado em um único', 'View sem estado'])
          tester.getTopLeft(panelText(t)).dy,
      ];
      expect(order, [...order]..sort());

      await tester.tap(find.byKey(const ValueKey('decision-filter-challenger')));
      await tester.pumpAndSettle();
      expect(panelText('Critério C1 reescrito como verificável.'), findsOneWidget);
      expect(panelText('Uma tela, sem fluxo de edição.'), findsNothing);
      expect(panelText('View sem estado próprio.'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('decision-filter-agent:T2')));
      await tester.pumpAndSettle();
      expect(panelText('Modelo imutável escrito à mão.'), findsOneWidget);
      expect(panelText('View sem estado próprio.'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('decision-filter-*')));
      await tester.pumpAndSettle();
      expect(panelText('View sem estado próprio.'), findsOneWidget);
      expect(panelText('Uma tela, sem fluxo de edição.'), findsOneWidget);
    });

    testWidgets('painéis Tasks e Verify vêm do plano e dos runs', (tester) async {
      final data = await _loadFixtures(tester);
      await _open(tester, data, '/p/gamma/flow');

      final t1 = find.byKey(const ValueKey('flow-task-T1'));
      expect(find.descendant(of: t1, matching: find.text('View gamma')), findsOneWidget);
      expect(
        find.descendant(of: t1, matching: find.byWidgetPredicate((w) => w is TierChip && w.tier == Tier.sonnet)),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('flow-task-T2')), matching: find.text('Modelo gamma')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('flow-task-V1')), findsNothing);

      final first = find.byKey(const ValueKey('flow-verify-verify-20260310T110000Z'));
      final second = find.byKey(const ValueKey('flow-verify-verify-20260310T113000Z'));
      expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
      expect(find.descendant(of: first, matching: find.text('inconclusivo')), findsWidgets);
      expect(find.descendant(of: first, matching: find.text('qa_inconclusive')), findsOneWidget);
      expect(find.descendant(of: second, matching: find.text('V1')), findsOneWidget);
      expect(find.descendant(of: second, matching: find.text('Correcao transversal.')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('fallback', () {
    testWidgets('sem report.json cada etapa avisa e Tasks/Verify continuam', (tester) async {
      final data = await _loadFixtures(tester);
      await _open(tester, data, '/p/beta/flow');

      expect(data.firstWhere((p) => p.name == 'beta').cycle!.report, isNull);
      expect(find.text('sem relatório desta etapa'), findsNWidgets(Stage.values.length));
      expect(find.byKey(const ValueKey('flow-tasks')), findsOneWidget);
      expect(find.byKey(const ValueKey('flow-verify')), findsOneWidget);
      expect(_inPanel('flow-decisions', find.text('sem relatório deste ciclo')), findsOneWidget);
      expect(_inStage(Stage.implement, find.text('em andamento')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('report.json com version 2 é tratado como sem relatório', (tester) async {
      final report = parseReport(
        '{"version": 2, "cycle": {"feature": "X"}, "stages": [{"stage": "kickoff", "status": "done", "summary_md": "nova versão"}]}',
      );
      expect(report, isNull);
      final data = [
        Project(
          name: 'versao',
          path: '/synthetic/versao',
          cycle: Cycle(stage: Stage.plan, autoMode: false, stageMinutes: const {}, runs: const [], report: report),
        ),
      ];
      await _open(tester, data, '/p/versao/flow');

      expect(find.text('sem relatório desta etapa'), findsNWidgets(Stage.values.length));
      expect(find.text('nova versão'), findsNothing);
      expect(_inStage(Stage.plan, find.text('em andamento')), findsOneWidget);
      expect(_inStage(Stage.specify, find.text('concluída')), findsOneWidget);
    });
  });

  group('banner Etapa em andamento', () {
    testWidgets('com cycle == null e sessão /kickoff rodando, acima do kickoff em andamento, e abre a sessão', (
      tester,
    ) async {
      await _open(
        tester,
        MockFlowRepository().data,
        '/p/web-console/flow',
        sessions: _Sessions([
          _session('s-old', createdAt: '2026-03-10T09:00:00Z', command: '/specify'),
          _session('s-kick', command: '/kickoff --manual'),
        ]),
        settle: false,
        // In the split the same session is already in the side panel and the banner drops the link.
        size: const Size(1300, 3200),
      );

      final banner = find.text('Etapa em andamento: /kickoff --manual (rodando)');
      expect(banner, findsOneWidget);
      final empty = find.text('Kickoff em andamento');
      expect(empty, findsOneWidget);
      expect(tester.getTopLeft(banner).dy, lessThan(tester.getTopLeft(empty).dy));

      await tester.tap(find.text('abrir sessão'));
      // The session page keeps animating while the session runs, so pumpAndSettle never returns.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_location(tester), '/p/web-console/sessions/s-kick');
    });

    testWidgets('sessão de org, de outro projeto, encerrada ou fora do pipeline não contam', (tester) async {
      await _open(
        tester,
        MockFlowRepository().data,
        '/p/web-console/flow',
        sessions: _Sessions([
          _session('s-org', project: '', org: 'demo'),
          _session('s-other', project: 'demo-app'),
          _session('s-done', status: SessionStatus.done),
          _session('s-free', command: 'explique o build'),
        ]),
      );

      expect(find.byKey(const ValueKey('stage-banner')), findsNothing);
      expect(find.text('Nenhum ciclo ativo. Comece com /kickoff ou /specify.'), findsOneWidget);
    });

    testWidgets('aparece no topo também com ciclo ativo', (tester) async {
      await _open(
        tester,
        MockFlowRepository().data,
        '/p/notifications-api/flow',
        sessions: _Sessions([
          _session(
            's-verify',
            project: 'notifications-api',
            command: '/verify',
            status: SessionStatus.waitingPermission,
          ),
        ]),
      );

      final banner = find.byKey(const ValueKey('stage-banner'));
      expect(find.text('Etapa em andamento: /verify (aguardando permissão)'), findsOneWidget);
      expect(tester.getTopLeft(banner).dy, lessThan(tester.getTopLeft(_stage(Stage.kickoff)).dy));
    });
  });

  group('painéis de fechamento (QA, dados reais, PR)', () {
    Project withClosing(Map<String, Object?> extra) => Project(
      name: 'closing-app',
      path: '/synthetic/closing-app',
      cycle: Cycle(
        stage: Stage.complete,
        autoMode: false,
        stageMinutes: const {},
        runs: const [],
        report: parseReport(
          jsonEncode({
            'version': 1,
            'cycle': {'feature': 'F'},
            'stages': [],
            ...extra,
          }),
        ),
      ),
    );

    Future<MockDocsRepository> openClosing(WidgetTester tester, Project project) async {
      tester.view.physicalSize = const Size(1600, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final docs = MockDocsRepository.empty();
      await tester.pumpWidget(
        ClaudeFlowApp(
          repository: MockFlowRepository(data: [project]),
          sessions: _Sessions(const []),
          engine: const MockEngineController(),
          docs: docs,
        ),
      );
      await tester.pump();
      _router(tester).go('/p/closing-app/flow');
      await tester.pumpAndSettle();
      return docs;
    }

    testWidgets('os três painéis renderizam e o link do PR passa pelo opener', (tester) async {
      final docs = await openClosing(
        tester,
        withClosing({
          'qa': ['Abrir a tela.', 'Conferir o tema.'],
          'real_data_md': 'Rodado **ok** com `alpha`.',
          'pr': {'url': 'https://github.com/acme/app/pull/12', 'number': 12},
        }),
      );

      expect(_inPanel('flow-qa', find.text('Roteiro de QA')), findsOneWidget);
      expect(_inPanel('flow-qa', find.textContaining('Abrir a tela.', findRichText: true)), findsOneWidget);
      expect(_inPanel('flow-qa', find.textContaining('Conferir o tema.', findRichText: true)), findsOneWidget);
      expect(_inPanel('flow-real-data', find.text('Teste com dados reais')), findsOneWidget);
      expect(_inPanel('flow-real-data', find.textContaining('Rodado', findRichText: true)), findsOneWidget);
      expect(_inPanel('flow-pr', find.text('PR #12')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('flow-pr-link')));
      await tester.tap(find.byKey(const ValueKey('flow-pr-link')));
      await tester.pump();
      expect(docs.opened, [Uri.parse('https://github.com/acme/app/pull/12')]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('não executado aparece no painel de dados reais', (tester) async {
      await openClosing(tester, withClosing({'real_data_md': null, 'real_data_status': 'não executado'}));

      expect(_inPanel('flow-real-data', find.text('não executado')), findsOneWidget);
      expect(find.byKey(const ValueKey('flow-qa')), findsNothing);
      expect(find.byKey(const ValueKey('flow-pr')), findsNothing);
    });

    testWidgets('sem dados nenhum painel aparece', (tester) async {
      await openClosing(tester, withClosing({}));

      expect(find.byKey(const ValueKey('flow-qa')), findsNothing);
      expect(find.byKey(const ValueKey('flow-real-data')), findsNothing);
      expect(find.byKey(const ValueKey('flow-pr')), findsNothing);
    });

    testWidgets('PR com URL que não abre fora do app não vira link', (tester) async {
      final docs = await openClosing(
        tester,
        withClosing({
          'pr': {'url': 'file:///etc/passwd', 'number': 1},
        }),
      );

      expect(find.byKey(const ValueKey('flow-pr')), findsOneWidget);
      expect(find.byKey(const ValueKey('flow-pr-link')), findsNothing);
      expect(docs.opened, isEmpty);
    });
  });
}

Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}
