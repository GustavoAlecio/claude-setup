import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/inventory_models.dart';
import 'package:claude_flow/data/inventory_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_inventory_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/features/adrs/adrs_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _dir = '/mock/demo-app/docs/adr';

const _adrs = [
  AdrEntry(
    id: '0001',
    title: 'Parser puro separado do IO',
    status: 'superseded',
    path: '$_dir/0001-parser-puro.md',
    date: '2026-03-01',
    supersededBy: ['0009'],
    tags: ['flutter', 'parsing'],
  ),
  AdrEntry(
    id: '0002',
    title: 'StreamCubit genérico',
    status: 'accepted',
    path: '$_dir/0002-stream-cubit.md',
    tags: ['state'],
  ),
  AdrEntry(
    id: '0003',
    title: 'Engine em Node',
    status: 'proposed',
    path: '$_dir/0003-engine-node.md',
    supersededBy: ['0042'],
    tags: ['engine'],
  ),
  AdrEntry(id: '0004', title: 'Sessões antigas', status: 'deprecated', path: '$_dir/0004-sessoes-antigas.md'),
  AdrEntry(
    id: '0009',
    title: 'Leitor próprio de frontmatter',
    status: 'accepted',
    path: '$_dir/0009-leitor-frontmatter.md',
    date: '2026-04-02',
    affects: ['app/lib/data/inventory_parser.dart'],
    supersedes: ['0001'],
    tags: ['parsing'],
  ),
  AdrEntry(id: '0010', title: 'Ideia em aberto', status: 'proposed', path: '$_dir/0010-ideia.md'),
  AdrEntry(
    id: '0011',
    title: '',
    status: '?',
    path: '$_dir/0011-quebrado.md',
    error: '0011-quebrado.md ilegível: frontmatter sem id, title ou status',
  ),
];

const _bodies = {
  '0001': '# Parser puro\n\nTexto antigo.\n',
  '0002': '# StreamCubit\n\nSem cadeia.\n',
  '0003': '# Engine\n',
  '0004': '# Sessões\n',
  '0009':
      '# Leitor\n\nVeja [[docs/adr/0002-stream-cubit.md|o cubit]] e [[9999-fantasma]].\n\n'
      'Literal: `[[0002-stream-cubit]]`. Fora: [site](https://example.com/adr).\n',
  '0010': '# Ideia\n',
  '0011': 'corpo bruto sem frontmatter **sem markdown**\n',
};

class _AdrInventory extends MockInventoryRepository {
  _AdrInventory([this.adrs = _adrs, this.submodule]);

  final List<AdrEntry> adrs;
  final GitSubmodule? submodule;

  @override
  Future<ProjectInventory> loadProject(Project project) async => ProjectInventory(adrs: adrs, adrSubmodule: submodule);

  @override
  Future<({AdrEntry entry, String body})?> loadAdr(Project project, String id) async {
    final entry = adrs.where((a) => a.id == id).firstOrNull;
    return entry == null ? null : (entry: entry, body: _bodies[id] ?? '');
  }
}

Future<GoRouter> _open(
  WidgetTester tester,
  String location, {
  InventoryRepository? inventory,
  MockDocsRepository? docs,
}) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(),
      sessions: MockSessionsRepository(),
      engine: const MockEngineController(),
      inventory: inventory ?? _AdrInventory(),
      docs: docs,
    ),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
  router.go(location);
  await tester.pumpAndSettle();
  return router;
}

String _location(GoRouter router) => router.routerDelegate.currentConfiguration.uri.toString();

Finder _detail(String id) => find.byKey(ValueKey('adr-detail-$id'));

Finder _item(String file) => find.byKey(ValueKey('adr-item-$_dir/$file'));

Iterable<TextSpan> _spans(WidgetTester tester) sync* {
  final roots = tester.widgetList<Text>(find.byType(Text)).map((t) => t.textSpan).whereType<TextSpan>();
  final stack = [...roots];
  while (stack.isNotEmpty) {
    final s = stack.removeLast();
    yield s;
    for (final child in s.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) stack.add(child);
    }
  }
}

void _tapLink(WidgetTester tester, String text) {
  final span = _spans(tester).firstWhere((s) => s.recognizer is TapGestureRecognizer && s.toPlainText() == text);
  (span.recognizer! as TapGestureRecognizer).onTap!();
}

void main() {
  testWidgets('submodule banner shows the path and the url without .git; absent without a submodule', (tester) async {
    await _open(
      tester,
      '/p/demo-app/adrs',
      inventory: _AdrInventory(_adrs, const GitSubmodule(path: 'docs', url: 'git@github.com:acme/org-docs.git')),
    );
    expect(find.text('ADRs da org — submódulo docs (git@github.com:acme/org-docs)'), findsOneWidget);

    await _open(tester, '/p/demo-app/adrs');
    expect(find.byKey(const ValueKey('adrs-submodule-banner')), findsNothing);
  });

  testWidgets('without ?adr= selects the highest accepted id and rewrites the URL', (tester) async {
    final router = await _open(tester, '/p/demo-app/adrs');

    expect(find.byType(AdrsPage), findsOneWidget);
    expect(_location(router), '/p/demo-app/adrs?adr=0009');
    expect(_detail('0009'), findsOneWidget);
    expect(find.descendant(of: _detail('0009'), matching: find.text('Leitor próprio de frontmatter')), findsOneWidget);
    expect(find.descendant(of: _detail('0009'), matching: find.text('2026-04-02')), findsOneWidget);
    expect(
      find.descendant(of: _detail('0009'), matching: find.text('app/lib/data/inventory_parser.dart')),
      findsOneWidget,
    );
  });

  testWidgets('unknown ?adr= falls back to the default', (tester) async {
    final router = await _open(tester, '/p/demo-app/adrs?adr=9999');

    expect(_location(router), '/p/demo-app/adrs?adr=0009');
    expect(_detail('0009'), findsOneWidget);
  });

  testWidgets('without accepted ADRs the default is the highest id', (tester) async {
    final router = await _open(
      tester,
      '/p/demo-app/adrs',
      inventory: _AdrInventory([
        for (final a in _adrs)
          if (a.status != 'accepted') a,
      ]),
    );

    expect(_location(router), '/p/demo-app/adrs?adr=0011');
  });

  testWidgets('list is in id order and selecting an item navigates', (tester) async {
    final router = await _open(tester, '/p/demo-app/adrs?adr=0009');

    final tops = [
      for (final f in ['0001-parser-puro.md', '0002-stream-cubit.md', '0009-leitor-frontmatter.md', '0011-quebrado.md'])
        tester.getTopLeft(_item(f)).dy,
    ];
    expect(tops, [...tops]..sort());

    await tester.tap(_item('0002-stream-cubit.md'));
    await tester.pumpAndSettle();
    expect(_location(router), '/p/demo-app/adrs?adr=0002');
    expect(_detail('0002'), findsOneWidget);
  });

  testWidgets('tile with duplicate or empty id has no onTap', (tester) async {
    const dup = AdrEntry(id: '0002', title: 'Cópia', status: 'accepted', path: '$_dir/0002-copia.md');
    final dupMarked = dup.withError('id duplicado: 0002 (0002-copia.md)');
    const empty = AdrEntry(id: '', title: '', status: '?', path: '$_dir/x-sem-id.md', error: 'ilegível');
    await _open(tester, '/p/demo-app/adrs?adr=0002', inventory: _AdrInventory([..._adrs, dupMarked, empty]));

    InkWell inkOf(String file) =>
        tester.widget<InkWell>(find.descendant(of: _item(file), matching: find.byType(InkWell)));
    expect(inkOf('0002-copia.md').onTap, isNull);
    expect(inkOf('x-sem-id.md').onTap, isNull);
    expect(inkOf('0002-stream-cubit.md').onTap, isNotNull);
  });

  testWidgets('"substituído por" chip navigates; a missing id is disabled', (tester) async {
    final router = await _open(tester, '/p/demo-app/adrs?adr=0001');

    expect(find.text('substituído por'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('adr-superseded-by-0009')));
    await tester.pumpAndSettle();
    expect(_location(router), '/p/demo-app/adrs?adr=0009');

    await tester.tap(find.byKey(const ValueKey('adr-supersedes-0001')));
    await tester.pumpAndSettle();
    expect(_location(router), '/p/demo-app/adrs?adr=0001');

    router.go('/p/demo-app/adrs?adr=0003');
    await tester.pumpAndSettle();
    final missing = tester.widget<ActionChip>(find.byKey(const ValueKey('adr-superseded-by-0042')));
    expect(missing.onPressed, isNull);
  });

  testWidgets('chain shows oldest to current from either end and hides without edges', (tester) async {
    final router = await _open(tester, '/p/demo-app/adrs?adr=0009');

    final chain = find.byKey(const ValueKey('adr-chain'));
    expect(chain, findsOneWidget);
    final first = tester.getTopLeft(find.byKey(const ValueKey('adr-chain-0001'))).dx;
    final second = tester.getTopLeft(find.byKey(const ValueKey('adr-chain-0009'))).dx;
    expect(first, lessThan(second));
    final selected = tester.widget<Text>(
      find.descendant(of: find.byKey(const ValueKey('adr-chain-0009')), matching: find.byType(Text)),
    );
    expect(selected.style?.fontWeight, FontWeight.w700);

    await tester.tap(find.byKey(const ValueKey('adr-chain-0001')));
    await tester.pumpAndSettle();
    expect(_location(router), '/p/demo-app/adrs?adr=0001');
    expect(find.byKey(const ValueKey('adr-chain-0009')), findsOneWidget);

    router.go('/p/demo-app/adrs?adr=0002');
    await tester.pumpAndSettle();
    expect(chain, findsNothing);
  });

  testWidgets('wikilink navigates, unresolved is plain text and code stays literal', (tester) async {
    final router = await _open(tester, '/p/demo-app/adrs?adr=0009');

    final plain = _spans(tester).map((s) => s.text ?? '').join();
    expect(plain, contains('9999-fantasma'));
    expect(plain, isNot(contains('[[9999-fantasma]]')));
    expect(plain, contains('[[0002-stream-cubit]]'));

    _tapLink(tester, 'o cubit');
    await tester.pumpAndSettle();
    expect(_location(router), '/p/demo-app/adrs?adr=0002');
  });

  testWidgets('external links go to the safe opener', (tester) async {
    final docs = MockDocsRepository.empty();
    final router = await _open(tester, '/p/demo-app/adrs?adr=0009', docs: docs);

    _tapLink(tester, 'site');
    await tester.pumpAndSettle();
    expect(docs.opened, [Uri.parse('https://example.com/adr')]);
    expect(_location(router), '/p/demo-app/adrs?adr=0009');
  });

  testWidgets('status filter narrows the list and keeps the selected detail', (tester) async {
    await _open(tester, '/p/demo-app/adrs?adr=0001');

    await tester.tap(find.byKey(const ValueKey('adrs-filter-accepted')));
    await tester.pumpAndSettle();
    expect(_item('0002-stream-cubit.md'), findsOneWidget);
    expect(_item('0009-leitor-frontmatter.md'), findsOneWidget);
    expect(_item('0001-parser-puro.md'), findsNothing);
    expect(_item('0011-quebrado.md'), findsNothing);
    expect(_detail('0001'), findsOneWidget, reason: 'hiding the selected item keeps its detail');

    await tester.tap(find.byKey(const ValueKey('adrs-filter-superseded')));
    await tester.pumpAndSettle();
    expect(_item('0001-parser-puro.md'), findsOneWidget);
    expect(_item('0004-sessoes-antigas.md'), findsOneWidget);
    expect(_item('0002-stream-cubit.md'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('adrs-filter-proposed')));
    await tester.pumpAndSettle();
    expect(_item('0003-engine-node.md'), findsOneWidget);
    expect(_item('0010-ideia.md'), findsOneWidget);
    expect(_item('0011-quebrado.md'), findsNothing, reason: 'unknown status only shows under "todos"');

    await tester.tap(find.byKey(const ValueKey('adrs-filter-all')));
    await tester.pumpAndSettle();
    expect(_item('0011-quebrado.md'), findsOneWidget);
  });

  testWidgets('search matches title and tags', (tester) async {
    await _open(tester, '/p/demo-app/adrs?adr=0009');

    await tester.enterText(find.byKey(const ValueKey('adrs-search')), 'streamcubit');
    await tester.pumpAndSettle();
    expect(_item('0002-stream-cubit.md'), findsOneWidget);
    expect(_item('0009-leitor-frontmatter.md'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('adrs-search')), 'parsing');
    await tester.pumpAndSettle();
    expect(_item('0001-parser-puro.md'), findsOneWidget);
    expect(_item('0009-leitor-frontmatter.md'), findsOneWidget);
    expect(_item('0002-stream-cubit.md'), findsNothing);
  });

  testWidgets('invalid ADR shows its error and the raw body', (tester) async {
    await _open(tester, '/p/demo-app/adrs?adr=0011');

    expect(find.descendant(of: _detail('0011'), matching: find.textContaining('frontmatter sem id')), findsOneWidget);
    expect(find.text('corpo bruto sem frontmatter **sem markdown**\n'), findsOneWidget);
  });

  testWidgets('project without ADRs shows the empty message', (tester) async {
    final router = await _open(tester, '/p/demo-app/adrs', inventory: const MockInventoryRepository.empty());

    expect(find.text('este projeto não tem ADRs'), findsOneWidget);
    expect(_location(router), '/p/demo-app/adrs');
  });

  testWidgets('/o/x/adrs does not render the AdrsPage', (tester) async {
    await _open(tester, '/o/x/adrs');

    expect(find.byType(AdrsPage), findsNothing);
  });
}
