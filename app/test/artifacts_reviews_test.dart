import 'dart:async';
import 'dart:convert';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/widgets/markdown_view.dart';
import 'package:claude_flow/data/docs_repository.dart';
import 'package:claude_flow/data/docs_models.dart';
import 'package:claude_flow/data/flow_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/features/reference/reference_nav.dart';
import 'package:claude_flow/features/reviews/reviews_diff.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _StalledDocs extends MockDocsRepository {
  _StalledDocs() : super();

  bool stall = false;
  final pending = Completer<DocsListing>();

  @override
  Future<DocsListing> list(String project) => stall ? pending.future : super.list(project);
}

class _CountingDocs extends MockDocsRepository {
  _CountingDocs() : super();

  int opens = 0;
  int listCalls = 0;

  @override
  Future<DocsListing> list(String project) {
    listCalls++;
    return super.list(project);
  }

  @override
  Future<void> open(Uri uri) {
    opens++;
    return super.open(uri);
  }
}

/// Reemite a lista de projetos sob demanda, como o watcher faria a cada mudança no workflow.
class _EmittingFlow extends MockFlowRepository {
  _EmittingFlow({super.data});

  final _emissions = StreamController<List<Project>>.broadcast();

  @override
  Stream<List<Project>> watchProjects() async* {
    yield projects;
    yield* _emissions.stream;
  }

  void emit() => _emissions.add(List.of(projects));
}

Future<GoRouter> _open(
  WidgetTester tester,
  String location, {
  DocsRepository? docs,
  FlowRepository? flow,
  MockSessionsRepository? sessions,
}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: flow ?? MockFlowRepository(),
      sessions: sessions ?? MockSessionsRepository(),
      engine: const MockEngineController(),
      docs: docs ?? MockDocsRepository(),
    ),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
  router.go(location);
  await tester.pumpAndSettle();
  return router;
}

String _at(GoRouter router) => router.routerDelegate.currentConfiguration.uri.toString();

Finder _line(bool Function(DiffLineView) test) =>
    find.byWidgetPredicate((w) => w is DiffLineView && test(w), description: 'diff line');

Finder _markdown(String source) =>
    find.byWidgetPredicate((w) => w is MarkdownView && w.source == source, description: 'markdown $source');

Finder _item(String id) => find.byKey(ValueKey('ref-item-$id'));

Text _itemText(WidgetTester tester, String id) =>
    tester.widget<Text>(find.descendant(of: _item(id), matching: find.byType(Text)));

String? _keyed(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data;

Project _demo({ReportDoc? report}) => Project(
  name: 'demo-app',
  path: '/dev/demo-app',
  cycle: Cycle(stage: Stage.plan, runs: const [], stageMinutes: const {}, report: report, reportIsCurrent: true),
);

const _planApprovedTwice = ReportDoc(
  feature: null,
  startedAt: null,
  stages: [
    StageReport(
      stage: Stage.plan,
      status: ReportStatus.done,
      gate: ReportGate(name: 'plan', status: GateStatus.approved, round: 2),
    ),
  ],
);

Finder get _subTabs => find.byWidgetPredicate((w) => w is SegmentedButton);

bool _diffEnabled(WidgetTester tester) => (tester.widget(_subTabs) as SegmentedButton).segments.first.enabled;

String _file(String path, int added) => [
  'diff --git a/$path b/$path',
  'new file mode 100644',
  '--- /dev/null',
  '+++ b/$path',
  '@@ -0,0 +1,$added @@',
  for (var j = 1; j <= added; j++) '+$path:$j',
].join('\n');

void main() {
  setUp(() {
    clearReferenceListingCache();
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  group('Artefatos', () {
    testWidgets('switching to ADRs keeps the last document list in the first frame', (tester) async {
      final docs = _StalledDocs();
      await _open(tester, '/p/demo-app/artifacts', docs: docs);
      expect(_item('spec.md'), findsOneWidget);

      docs.stall = true;
      await tester.tap(_item('adrs'));
      await tester.pump();
      expect(_item('spec.md'), findsOneWidget);
    });

    testWidgets('the nav lists in reading order, opens the spec by default and the selection lives in ?doc=', (
      tester,
    ) async {
      final router = await _open(tester, '/p/demo-app/artifacts');

      expect(_at(router), '/p/demo-app/artifacts?doc=spec.md');
      expect(find.text('Deste ciclo'), findsOneWidget);
      expect(find.text('Detalhamentos'), findsOneWidget);
      expect(find.text('Do projeto'), findsOneWidget);
      final order = [
        'spec.md',
        'plan.md',
        'tasks.md',
        'details/2026-03-12-login.md',
        'details/2026-03-10-cache.md',
        'adrs',
        'metrics',
      ];
      final ys = [for (final id in order) tester.getTopLeft(_item(id)).dy];
      expect(ys, [...ys]..sort());
      expect(_itemText(tester, 'spec.md').data, 'O que vai ser entregue');
      expect(_itemText(tester, 'plan.md').data, 'Como vai ser construído');
      expect(_itemText(tester, 'details/2026-03-12-login.md').data, '2026-03-12-login');
      expect(find.byWidgetPredicate((w) => w is Tooltip && w.message == '2026-03-12-login'), findsOneWidget);
      expect(_itemText(tester, 'spec.md').style!.fontWeight, FontWeight.w600);
      expect(_itemText(tester, 'plan.md').style!.fontWeight, FontWeight.w400);

      expect(_keyed(tester, 'artifact-title'), 'O que vai ser entregue');
      expect(find.byKey(const ValueKey('artifact-gate')), findsNothing);
      expect(find.byKey(const ValueKey('artifact-copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('artifact-reveal')), findsOneWidget);
      expect(find.text('Spec: Exemplo'), findsOneWidget);

      await tester.tap(_item('plan.md'));
      await tester.pumpAndSettle();
      expect(_at(router), '/p/demo-app/artifacts?doc=plan.md');
      expect(_itemText(tester, 'plan.md').style!.fontWeight, FontWeight.w600);
      expect(_itemText(tester, 'spec.md').style!.fontWeight, FontWeight.w400);
      expect(_keyed(tester, 'artifact-title'), 'Como vai ser construído');
      expect(find.text('Plano'), findsOneWidget);

      await tester.tap(_item('details/2026-03-12-login.md'));
      await tester.pumpAndSettle();
      expect(_at(router), '/p/demo-app/artifacts?doc=details%2F2026-03-12-login.md');
      expect(_keyed(tester, 'artifact-title'), '2026-03-12-login');
      expect(find.text('Detalhamento: login'), findsOneWidget);
    });

    testWidgets('the gate line follows the report of the cycle, without re-reading the document', (tester) async {
      final data = [_demo()];
      final flow = _EmittingFlow(data: data);
      final docs = _CountingDocs();
      await _open(tester, '/p/demo-app/artifacts?doc=plan.md', docs: docs, flow: flow);

      expect(_keyed(tester, 'artifact-title'), 'Como vai ser construído');
      expect(find.byKey(const ValueKey('artifact-gate')), findsNothing);
      expect(docs.reads['plan.md'], 1);

      data[0] = _demo(report: _planApprovedTwice);
      final lists = docs.listCalls;
      flow.emit();
      await tester.pumpAndSettle();
      expect(_keyed(tester, 'artifact-gate'), 'Plano técnico · aprovado, na 2ª rodada');
      expect(docs.reads['plan.md'], 1);
      expect(docs.listCalls, lists + 1, reason: 'the fed nav reads nothing on its own');
      expect(find.byKey(const ValueKey('artifact-copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('artifact-reveal')), findsOneWidget);

      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
      router.go('/p/demo-app/artifacts?doc=details%2F2026-03-10-cache.md');
      await tester.pumpAndSettle();
      expect(_keyed(tester, 'artifact-title'), '2026-03-10-cache');
      expect(find.byKey(const ValueKey('artifact-gate')), findsNothing);
    });

    testWidgets('twelve documents with long titles at 1100x700 render without overflow', (tester) async {
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final long = 'documento-com-um-nome-bem-comprido-' * 4;
      final docs = MockDocsRepository.empty();
      for (var i = 0; i < 6; i++) {
        docs
          ..write('$long$i.md', '# Raiz $i')
          ..write('details/$long$i.md', '# Detalhe $i');
      }
      final router = await _open(tester, '/p/demo-app/artifacts', docs: docs);

      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['doc'], '${long}0.md');
      expect(
        find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('ref-item-'),
        ),
        findsNWidgets(14),
      );
      expect(_keyed(tester, 'artifact-title'), '${long}0');
      expect(find.text('Raiz 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Mostrar no Finder" asks the repository to reveal the open document', (tester) async {
      final docs = MockDocsRepository();
      await _open(tester, '/p/demo-app/artifacts?doc=spec.md', docs: docs);

      await tester.tap(find.byKey(const ValueKey('artifact-reveal')));
      await tester.pumpAndSettle();
      expect(docs.revealed, [('demo-app', 'spec.md')]);
    });

    testWidgets('unknown ?doc= falls back to the first item', (tester) async {
      final router = await _open(tester, '/p/demo-app/artifacts?doc=nope.md');
      expect(_at(router), '/p/demo-app/artifacts?doc=spec.md');
    });

    testWidgets('empty project shows "nenhum documento" next to the nav', (tester) async {
      await _open(tester, '/p/demo-app/artifacts', docs: MockDocsRepository.empty());
      final empty = find.text('nenhum documento');
      expect(empty, findsOneWidget);
      expect(_item('adrs'), findsOneWidget);
      expect(find.text('Deste ciclo'), findsNothing);
      expect(tester.getTopLeft(empty).dx, greaterThan(tester.getTopRight(_item('adrs')).dx));
    });

    testWidgets('large document shows the warning in place of the content', (tester) async {
      final docs = MockDocsRepository()..write('spec.md', 'x' * (kDocSizeLimit + 1));
      await _open(tester, '/p/demo-app/artifacts', docs: docs);
      expect(find.text('arquivo grande demais'), findsOneWidget);
    });

    testWidgets('links: web schemes go to the opener, project .md to ?doc=, the rest is ignored', (tester) async {
      final docs = _CountingDocs()..write('details/a.md', '# A');
      final router = await _open(tester, '/p/demo-app/artifacts?doc=spec.md', docs: docs);
      void tap(String link) => tester.widget<MarkdownView>(find.byType(MarkdownView)).onLink(Uri.parse(link));

      tap('https://x');
      expect(docs.opens, 1);
      for (final link in ['file:///x', '/Applications/X.app', 'javascript:x', '#a', 'missing.md']) {
        tap(link);
      }
      await tester.pumpAndSettle();
      expect(docs.opens, 1);
      expect(_at(router), '/p/demo-app/artifacts?doc=spec.md');

      tap('details/a.md');
      await tester.pumpAndSettle();
      expect(_at(router), '/p/demo-app/artifacts?doc=details%2Fa.md');
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['doc'], 'details/a.md');

      tap('../plan.md');
      await tester.pumpAndSettle();
      expect(_at(router), '/p/demo-app/artifacts?doc=plan.md');
    });

    testWidgets('links with encoded spaces or accents open the doc', (tester) async {
      final docs = MockDocsRepository()
        ..write('my doc.md', '# Com espaço')
        ..write('sessão.md', '# Com acento');
      final router = await _open(tester, '/p/demo-app/artifacts?doc=spec.md', docs: docs);
      void tap(String link) => tester.widget<MarkdownView>(find.byType(MarkdownView)).onLink(Uri.parse(link));

      tap('my%20doc.md');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['doc'], 'my doc.md');
      expect(find.text('Com espaço'), findsOneWidget);

      tap('sessão.md');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['doc'], 'sessão.md');
      expect(find.text('Com acento'), findsOneWidget);
    });

    testWidgets('front-matter is stripped from the document body', (tester) async {
      await _open(tester, '/p/demo-app/artifacts?doc=spec.md');
      expect(find.textContaining('status: draft'), findsNothing);
    });

    testWidgets('re-emissions with the same stamp do not re-read; a new stamp re-reads in place', (tester) async {
      final flow = _EmittingFlow();
      final docs = MockDocsRepository();
      await _open(tester, '/p/demo-app/artifacts?doc=spec.md', docs: docs, flow: flow);
      expect(docs.reads['spec.md'], 1);

      for (var i = 0; i < 5; i++) {
        flow.emit();
        await tester.pumpAndSettle();
      }
      expect(docs.reads['spec.md'], 1);

      docs.write('spec.md', '# Spec revisada\n');
      flow.emit();
      await tester.pumpAndSettle();
      expect(docs.reads['spec.md'], 2);
      expect(find.text('Spec revisada'), findsOneWidget);
    });
  });

  group('Reviews', () {
    testWidgets('descending list, header from meta and diff, comment right after its line', (tester) async {
      final router = await _open(tester, '/p/demo-app/reviews');

      expect(_at(router), '/p/demo-app/reviews?pr=157');
      expect(tester.getTopLeft(find.text('PR-157').first).dy, lessThan(tester.getTopLeft(find.text('PR-9')).dy));
      expect(find.text('feat: cache de partidas'), findsOneWidget);
      expect(find.text('@dev-a'), findsOneWidget);
      expect(find.text('feat/cache → main'), findsOneWidget);
      expect(find.text('2 arquivos'), findsOneWidget);
      expect(find.text('+4'), findsOneWidget);
      expect(find.text('−1'), findsWidgets);
      expect(find.text('1 critical'), findsOneWidget);
      expect(find.text('1 major'), findsOneWidget);
      expect(find.text('1 nit'), findsOneWidget);
      expect(find.text('0 minor'), findsNothing);

      expect(_diffEnabled(tester), isTrue);
      final line3 = _line((w) => w.line.newNumber == 3 && w.line.text == 'int c = 3;');
      final line4 = _line((w) => w.line.newNumber == 4);
      final card = _markdown('Use `final`.');
      expect(line3, findsOneWidget);
      expect(card, findsOneWidget);
      expect(tester.getTopLeft(card).dy, greaterThan(tester.getTopLeft(line3).dy));
      expect(tester.getTopLeft(card).dy, lessThan(tester.getTopLeft(line4).dy));

      expect(find.text('fora do diff (1)'), findsOneWidget);
      expect(find.text('outros comentários (1)'), findsOneWidget);
      final cards = [_markdown('Use `final`.'), _markdown('Nome genérico.'), _markdown('Fora do diff.')];
      for (final c in cards) {
        expect(c, findsOneWidget);
      }
      expect(
        tester.getTopLeft(_markdown('Nome genérico.')).dy,
        lessThan(tester.getTopLeft(_line((w) => w.line.newNumber == 1 && w.line.text.startsWith('import'))).dy),
      );

      await tester.tap(find.text('Relatório'));
      await tester.pumpAndSettle();
      expect(find.text('Review PR-157'), findsOneWidget);

      await tester.tap(find.text('PR-9'));
      await tester.pumpAndSettle();
      expect(_at(router), '/p/demo-app/reviews?pr=9');
      expect(_diffEnabled(tester), isFalse);
      expect(find.text('Sem diff salvo.'), findsOneWidget);
      expect(find.text('0 arquivos'), findsOneWidget);
    });

    testWidgets('unknown ?pr= falls back to the first review', (tester) async {
      final router = await _open(tester, '/p/demo-app/reviews?pr=42');
      expect(_at(router), '/p/demo-app/reviews?pr=157');
    });

    testWidgets('no reviews shows the empty state', (tester) async {
      await _open(tester, '/p/demo-app/reviews', docs: MockDocsRepository.empty());
      expect(find.text('nenhum review; rode /review em um PR'), findsOneWidget);
      expect(find.byKey(const ValueKey('reviews-back')), findsOneWidget);
    });

    testWidgets('a review comment with --- is rendered whole', (tester) async {
      const body = '---\nnota\n---\nresto';
      final docs = MockDocsRepository()
        ..write(
          'reviews/PR-157.comments.json',
          '[{"path": "lib/a.dart", "line": 3, "severity": "major", "agent": "x", "body": ${jsonEncode(body)}}]',
        );
      await _open(tester, '/p/demo-app/reviews?pr=157', docs: docs);
      expect(_markdown(body), findsOneWidget);
      expect(find.textContaining('nota'), findsWidgets);
    });

    testWidgets('invalid meta leaves a minimal header with a warning', (tester) async {
      final docs = MockDocsRepository()..write('reviews/PR-9.meta.json', '{not json');
      await _open(tester, '/p/demo-app/reviews?pr=9', docs: docs);
      expect(find.text('PR-9'), findsWidgets);
      expect(find.text('fix: login'), findsNothing);
      expect(find.text('@dev-b'), findsNothing);
      expect(find.textContaining('meta.json inválido'), findsOneWidget);
    });

    testWidgets('real meta shape with 100 files: the diff wins; without diff the total is partial', (tester) async {
      final metaFiles = [
        for (var i = 0; i < 100; i++) '{"path": "f$i.dart", "additions": 1, "deletions": 1, "changeType": "MODIFIED"}',
      ];
      final meta =
          '{"number": 300, "title": "feat: grande", "body": "", "author": {"login": "octo", "id": "X"},'
          ' "baseRefName": "main", "headRefName": "feat/big", "files": [${metaFiles.join(',')}]}';
      final diff = [for (var i = 0; i < 150; i++) _file('f$i.dart', 2)].join('\n');
      final docs = MockDocsRepository.empty()
        ..write('reviews/PR-300.md', '# r')
        ..write('reviews/PR-300.meta.json', meta)
        ..write('reviews/PR-300.diff', diff)
        ..write('reviews/PR-301.md', '# s')
        ..write('reviews/PR-301.meta.json', meta);
      final router = await _open(tester, '/p/demo-app/reviews?pr=300', docs: docs);

      expect(find.text('@octo'), findsOneWidget);
      expect(find.text('150 arquivos'), findsOneWidget);
      expect(find.text('+300'), findsOneWidget);
      expect(find.text('−0'), findsWidgets);

      router.go('/p/demo-app/reviews?pr=301');
      await tester.pumpAndSettle();
      expect(find.text('100 arquivos (parcial)'), findsOneWidget);
      expect(find.text('+100'), findsOneWidget);
    });

    testWidgets('file with 400+ changed lines and no comment starts collapsed', (tester) async {
      final docs = MockDocsRepository.empty()
        ..write('reviews/PR-5.md', '# r')
        ..write('reviews/PR-5.diff', '${_file('big.dart', 450)}\n${_file('small.dart', 3)}');
      await _open(tester, '/p/demo-app/reviews?pr=5', docs: docs);

      expect(find.text('big.dart'), findsOneWidget);
      expect(_line((w) => w.line.text.startsWith('big.dart')), findsNothing);
      expect(_line((w) => w.line.text.startsWith('small.dart')), findsNWidgets(3));

      await tester.tap(find.text('big.dart'));
      await tester.pumpAndSettle();
      expect(_line((w) => w.line.text == 'big.dart:1'), findsOneWidget);
    });

    testWidgets('diff above the limit keeps the tab enabled, warns and moves comments to "outros"', (tester) async {
      final docs = MockDocsRepository()..write('reviews/PR-157.diff', 'x' * (kDocSizeLimit + 1));
      await _open(tester, '/p/demo-app/reviews?pr=157', docs: docs);

      expect(_diffEnabled(tester), isTrue);
      expect(find.text('arquivo grande demais'), findsOneWidget);
      expect(find.text('outros comentários (3)'), findsOneWidget);
      expect(find.text('2 arquivos'), findsOneWidget);
      expect(find.text('+4'), findsOneWidget);
    });

    testWidgets('200 files and 20k lines build few line widgets and scroll to the last one', (tester) async {
      final diff = [for (var i = 0; i < 200; i++) _file('f$i', 100)].join('\n');
      expect(diff.length, lessThan(kIsolateParseThreshold));
      final docs = MockDocsRepository.empty()
        ..write('reviews/PR-1.md', '# r')
        ..write('reviews/PR-1.diff', diff);
      await _open(tester, '/p/demo-app/reviews?pr=1', docs: docs);

      expect(find.text('200 arquivos'), findsOneWidget);
      expect(tester.widgetList(_line((_) => true)).length, lessThan(300));

      final scrollable = find.descendant(of: find.byType(ReviewsDiff), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(
        _line((w) => w.line.text == 'f199:100'),
        8000,
        scrollable: scrollable.first,
        maxScrolls: 200,
      );
      expect(_line((w) => w.line.text == 'f199:100'), findsOneWidget);
      expect(tester.widgetList(_line((_) => true)).length, lessThan(300));
    });

    testWidgets('diff above 256 KB is parsed off the main isolate', (tester) async {
      final diff = [for (var i = 0; i < 100; i++) _file('g$i', 400)].join('\n');
      expect(diff.length, greaterThan(kIsolateParseThreshold));
      final docs = MockDocsRepository.empty()
        ..write('reviews/PR-2.md', '# r')
        ..write('reviews/PR-2.diff', diff);
      await tester.runAsync(() => _open(tester, '/p/demo-app/reviews?pr=2', docs: docs));
      for (var i = 0; i < 20 && find.text('100 arquivos').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(find.text('100 arquivos'), findsOneWidget);
    });

    testWidgets('re-emissions: same stamp reads once; new stamp re-reads keeping collapse and sub-tab', (tester) async {
      final flow = _EmittingFlow();
      final docs = MockDocsRepository();
      await _open(tester, '/p/demo-app/reviews?pr=157', docs: docs, flow: flow);
      expect(docs.reads['reviews/PR-157.diff'], 1);

      await tester.tap(find.text('lib/a.dart').first);
      await tester.pumpAndSettle();
      expect(_line((w) => w.line.text == 'int a = 2;'), findsNothing);

      for (var i = 0; i < 5; i++) {
        flow.emit();
        await tester.pumpAndSettle();
      }
      expect(docs.reads['reviews/PR-157.diff'], 1);
      expect(docs.reads['reviews/PR-157.md'], 1);

      final original = syntheticDocs['reviews/PR-157.diff']!;
      docs.write('reviews/PR-157.diff', original.replaceFirst('+// fim', '+// fim revisado'));
      flow.emit();
      await tester.pumpAndSettle();
      expect(docs.reads['reviews/PR-157.diff'], 2);
      expect(docs.reads['reviews/PR-157.md'], 1);
      expect(_line((w) => w.line.text == '// fim revisado'), findsOneWidget);
      expect(_line((w) => w.line.text == 'int a = 2;'), findsNothing);
      expect(_diffEnabled(tester), isTrue);

      await tester.tap(find.text('Relatório'));
      await tester.pumpAndSettle();
      docs.write('reviews/PR-157.md', '# Review revisado\n');
      flow.emit();
      await tester.pumpAndSettle();
      expect(docs.reads['reviews/PR-157.md'], 2);
      expect(find.text('Review revisado'), findsOneWidget);
    });
  });

  testWidgets('artifacts and reviews tabs exist only in a project, not in /o/', (tester) async {
    final router = await _open(tester, '/p/demo-app/flow');
    await tester.tap(find.byKey(const ValueKey('group-reference')));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/p/demo-app/artifacts');
    expect(find.byKey(const ValueKey('subtabs')), findsNothing);
    expect(_item('adrs'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('group-prs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-row-157')));
    await tester.pumpAndSettle();
    expect(_at(router), '/p/demo-app/reviews?pr=157');

    router.go('/o/demo/sessions');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-reference')), findsNothing);
    expect(find.byKey(const ValueKey('subtabs')), findsNothing);
    expect(find.text('Artefatos'), findsNothing);
    expect(find.text('Reviews'), findsNothing);
  });

  testWidgets('review actions: approve runs /approve-review; publish asks before /post-review', (tester) async {
    final sessions = MockSessionsRepository();
    await _open(tester, '/p/demo-app/reviews', sessions: sessions);

    await tester.tap(find.byKey(const ValueKey('review-approve')));
    await tester.pumpAndSettle();
    expect(sessions.createCalls.last.$2, '/approve-review 157');

    await _open(tester, '/p/demo-app/reviews', sessions: sessions);
    await tester.tap(find.byKey(const ValueKey('review-publish')));
    await tester.pumpAndSettle();
    expect(find.text('Publicar a revisão no PR #157?'), findsOneWidget);
    await tester.tap(find.text('Publicar'));
    await tester.pumpAndSettle();
    expect(sessions.createCalls.last.$2, '/post-review 157');
  });
}
