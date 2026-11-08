import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/attention.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _s(String id, SessionStatus status, {int pending = 0, String? org}) => SessionSummary(
  id: id,
  project: org == null ? 'demo-app' : '',
  command: 'c',
  title: 'título $id',
  status: status,
  createdAt: '2026-10-07T10:00:00Z',
  pendingPermissions: pending,
  org: org,
);

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  test('pending sessions and stopped cycles want attention, with routes to resolve them', () {
    final items = pendingAttention([
      _s('a', SessionStatus.waitingPermission, pending: 2),
      _s('b', SessionStatus.running),
      _s('c', SessionStatus.waitingPermission, pending: 1, org: 'demo'),
    ], MockFlowRepository().projects);

    expect(items.map((i) => i.key), ['pending:a:2', 'pending:c:1', 'blocked:demo-app:impl-20261001T141210Z:T4']);
    expect(items.first.route, '/p/demo-app/sessions/a');
    expect(items[1].route, startsWith('/o/demo/sessions'));
    expect(items.last.route, '/p/demo-app/runs/impl-20261001T141210Z/T4');
  });

  test('a turn finishes when a running session becomes idle or done', () {
    final items = finishedTurns(
      {'a': SessionStatus.running, 'b': SessionStatus.running, 'c': SessionStatus.idle},
      [_s('a', SessionStatus.idle), _s('b', SessionStatus.running), _s('c', SessionStatus.idle)],
    );
    expect(items.map((i) => i.title), ['Turno concluído · demo-app']);
  });

  testWidgets('the Dock badge follows the total; what waited at launch is not announced', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('claude_flow/attention'), (
      call,
    ) async {
      calls.add(call);
      return call.method == 'isActive' ? false : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('claude_flow/attention'),
        null,
      ),
    );
    final repo = MockFlowRepository();
    final sessions = MockSessionsRepository();
    await tester.pumpWidget(ClaudeFlowApp(repository: repo, sessions: sessions, engine: const MockEngineController()));
    await tester.pumpAndSettle();

    final badges = calls.where((c) => c.method == 'badge').map((c) => (c.arguments as Map)['count'] as int);
    // Two pending sessions in the mock plus the stopped demo-app cycle.
    expect(badges.last, 3);
    expect(calls.where((c) => c.method == 'notify'), isEmpty);
  });

  testWidgets('Minha fila lists what waits, what runs and the cycles of the whole org', (tester) async {
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(),
        sessions: MockSessionsRepository(),
        engine: const MockEngineController(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-queue')));
    await tester.pumpAndSettle();

    Finder inColumn(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);
    expect(inColumn('queue-waiting', find.textContaining('ciclo parado')), findsOneWidget);
    expect(inColumn('queue-waiting', find.textContaining('decisão sua')), findsWidgets);
    expect(inColumn('queue-cycles', find.text('Retry com backoff')), findsOneWidget);

    await tester.tap(inColumn('queue-waiting', find.textContaining('ciclo parado')));
    await tester.pumpAndSettle();
    expect(find.textContaining('diagnóstico', findRichText: true), findsWidgets);
  });

  testWidgets('Minha fila also lists PRs with review comments waiting, and opens the project PRs', (tester) async {
    final github = MockGitHubRepository.sample();
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(),
        sessions: MockSessionsRepository(),
        engine: const MockEngineController(),
        github: github,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-queue')));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('queue-pr-demo-app-12'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('1 comentário esperando')), findsOneWidget);
    expect(github.prsCalls.map((c) => c.$1), contains('demo-app'));

    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('Adiciona filtro de partidas'), findsOneWidget);
  });

  test('nextAttentionRoute cycles from the item on screen and starts at the first', () {
    const a = AttentionItem(key: 'a', title: '', body: '', route: '/p/x/sessions/1');
    const b = AttentionItem(key: 'b', title: '', body: '', route: '/p/x/flow?stage=implement');
    expect(nextAttentionRoute(const [], '/'), isNull);
    expect(nextAttentionRoute(const [a, b], '/o/demo/fila'), a.route);
    expect(nextAttentionRoute(const [a, b], '/p/x/sessions/1'), b.route);
    expect(nextAttentionRoute(const [a, b], '/p/x/flow?stage=plan'), a.route);
  });
}
