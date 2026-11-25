import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/platform/attention.dart';
import 'package:claude_flow/data/attention.dart';
import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/engine/engine_config.dart';
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

Project _gated(List<StageReport> stages, {bool current = true}) => Project(
  name: 'demo-app',
  cycle: Cycle(
    stage: Stage.plan,
    runs: const [],
    stageMinutes: const {},
    report: ReportDoc(feature: 'f', startedAt: null, stages: stages),
    reportIsCurrent: current,
  ),
);

StageReport _stage(Stage stage, String session, String gate, GateStatus status) => StageReport(
  stage: stage,
  status: ReportStatus.running,
  sessionId: session,
  gate: ReportGate(name: gate, status: status),
);

SessionSummary _new(String id) => SessionSummary(
  id: id,
  project: 'demo-app',
  command: 'c',
  title: 'título $id',
  status: SessionStatus.waitingPermission,
  createdAt: '2026-10-07T10:00:00Z',
);

/// The mock counts pending requests from the events, not from the summary.
List<Map<String, Object?>> _waiting(String id, int n) => [
  for (var i = 0; i < n; i++)
    {
      'kind': 'permission',
      'requestId': '$id-$i',
      'toolName': 'Bash',
      'input': {'command': 'ls'},
    },
];

class _NoConfigRepository extends MockFlowRepository {
  @override
  Stream<DashboardConfig> watchConfig() => const Stream.empty(broadcast: true).cast();
}

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

  testWidgets('Caixa de entrada lists what waits on the user across the org, one action per line', (tester) async {
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(),
        sessions: MockSessionsRepository(),
        engine: const MockEngineController(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-home')));
    await tester.pumpAndSettle();

    Finder inWaiting(Finder f) => find.descendant(of: find.byKey(const ValueKey('inbox-waiting')), matching: f);
    expect(inWaiting(find.text('A task T4 travou')), findsOneWidget);
    expect(inWaiting(find.text('Responder')), findsWidgets);
    expect(find.byKey(const ValueKey('inbox-row-0-action')), findsOneWidget);
    expect(find.text('1 ciclo em andamento'), findsOneWidget);

    await tester.tap(inWaiting(find.text('A task T4 travou')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-decide')), findsOneWidget);
  });

  testWidgets('Caixa de entrada also lists PRs with review comments waiting, and opens the project PRs', (
    tester,
  ) async {
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
    await tester.tap(find.byKey(const ValueKey('sidebar-home')));
    await tester.pumpAndSettle();

    final context = find.descendant(
      of: find.byKey(const ValueKey('inbox-waiting')),
      matching: find.text('demo-app · PR #12'),
    );
    expect(context, findsOneWidget);
    final row = find.ancestor(
      of: context,
      matching: find.byWidgetPredicate((w) => '${w.key}'.contains(RegExp(r"inbox-row-\d+'"))),
    );
    expect(find.descendant(of: row, matching: find.text('Comentários de revisão esperando resposta')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Resolver')), findsOneWidget);
    expect(github.prsCalls.map((c) => c.$1), contains('demo-app'));

    await tester.ensureVisible(context);
    await tester.tap(context);
    await tester.pumpAndSettle();
    expect(find.text('Adiciona filtro de partidas'), findsOneWidget);
  });

  test('nextAttentionRoute cycles from the item on screen and starts at the first', () {
    const a = AttentionItem(key: 'a', title: '', body: '', route: '/p/x/sessions/1', kind: AttentionKind.request);
    const b = AttentionItem(
      key: 'b',
      title: '',
      body: '',
      route: '/p/x/flow?stage=implement',
      kind: AttentionKind.blocked,
    );
    expect(nextAttentionRoute(const [], '/'), isNull);
    expect(nextAttentionRoute(const [a, b], '/o/demo/fila'), a.route);
    expect(nextAttentionRoute(const [a, b], '/p/x/sessions/1'), b.route);
    expect(nextAttentionRoute(const [a, b], '/p/x/flow?stage=plan'), a.route);
  });

  group('gate open aponta para a tela do gate', () {
    final waiting = [
      _s('s-plan', SessionStatus.waitingPermission, pending: 1),
      _s('s-spec', SessionStatus.waitingPermission, pending: 1),
      _s('s-pr', SessionStatus.waitingPermission, pending: 1),
      _s('s-none', SessionStatus.waitingPermission, pending: 1),
    ];
    final project = _gated([
      _stage(Stage.challenge, 's-spec', 'spec', GateStatus.open),
      _stage(Stage.plan, 's-plan', 'plan', GateStatus.open),
      _stage(Stage.tasks, 's-none', 'tasks', GateStatus.approved),
      _stage(Stage.complete, 's-pr', 'pr', GateStatus.open),
    ]);

    test('spec, plan, tasks e pr vão para a tela do gate; sessões sem gate aberto ficam', () {
      final items = pendingAttention(waiting, [project]);
      expect(items.map((i) => i.route), [
        '/p/demo-app/gate/plan',
        '/p/demo-app/gate/spec',
        '/p/demo-app/gate/pr',
        '/p/demo-app/sessions/s-none',
      ]);
      expect(items.map((i) => i.key), ['pending:s-plan:1', 'pending:s-spec:1', 'pending:s-pr:1', 'pending:s-none:1']);
    });

    test('the first stage of the session in pipeline order wins', () {
      final items = pendingAttention(
        [_s('s1', SessionStatus.waitingPermission, pending: 1)],
        [
          _gated([
            _stage(Stage.challenge, 's1', 'spec', GateStatus.approved),
            _stage(Stage.plan, 's1', 'plan', GateStatus.open),
            _stage(Stage.tasks, 's1', 'tasks', GateStatus.open),
          ]),
        ],
      );
      expect(items.single.route, '/p/demo-app/gate/plan');
    });

    test('a report of another cycle routes to the session', () {
      final items = pendingAttention(
        [waiting.first],
        [
          _gated([_stage(Stage.plan, 's-plan', 'plan', GateStatus.open)], current: false),
        ],
      );
      expect(items.single.route, '/p/demo-app/sessions/s-plan');
    });

    test('nextAttentionRoute from the gate screen goes to the next item', () {
      final items = pendingAttention(waiting, [project]);
      expect(nextAttentionRoute(items, '/p/demo-app/gate/plan'), '/p/demo-app/gate/spec');
      expect(nextAttentionRoute(items, '/p/demo-app/gate/spec'), '/p/demo-app/gate/pr');
    });
  });

  group('AttentionChannel.sound', () {
    const channel = MethodChannel('claude_flow/attention');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('without the native side it did not play', () async {
      expect(await const AttentionChannel().sound(), isFalse);
    });

    test('a PlatformException means it did not play', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'boom'));
      expect(await const AttentionChannel().sound(), isFalse);
    });

    test('the native answer comes back', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      expect(await const AttentionChannel().sound(), isTrue);
      expect(calls.single.method, 'sound');
    });

    test('notify carries silent only when it is given', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      const attention = AttentionChannel();
      await attention.notify(id: 'a', title: 't', body: 'b', route: '/', silent: true);
      await attention.notify(id: 'b', title: 't', body: 'b', route: '/');

      expect((calls.first.arguments as Map)['silent'], isTrue);
      expect((calls.last.arguments as Map).containsKey('silent'), isFalse);
    });
  });

  group('alerta sonoro', () {
    const channel = MethodChannel('claude_flow/attention');
    late List<MethodCall> calls;
    late bool active;
    late DateTime clock;
    late MockSessionsRepository sessions;

    Iterable<MethodCall> named(String method) => calls.where((c) => c.method == method);
    Iterable<Map<Object?, Object?>> notified(String prefix) =>
        named('notify').map((c) => c.arguments as Map).where((a) => (a['id'] as String).startsWith(prefix));

    Future<void> start(WidgetTester tester, MockFlowRepository repo, {bool settle = true}) async {
      calls = [];
      active = false;
      clock = DateTime(2026, 11, 24, 10);
      sessions = MockSessionsRepository();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isActive' => active,
          'sound' => true,
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        ClaudeFlowApp(repository: repo, sessions: sessions, engine: const MockEngineController(), now: () => clock),
      );
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
        await tester.pump();
      }
    }

    Future<void> add(WidgetTester tester, String id, int n, {bool settle = true}) async {
      sessions.addSession(_new(id), _waiting(id, n), status: 'waiting_permission');
      settle ? await tester.pumpAndSettle() : await tester.pump();
    }

    testWidgets('a new request plays in the foreground and in the background, not at the first load', (tester) async {
      await start(tester, MockFlowRepository());
      expect(named('sound'), isEmpty);

      active = true;
      await add(tester, 'x', 1);
      expect(named('sound'), hasLength(1));
      expect(named('notify'), isEmpty);

      clock = clock.add(const Duration(seconds: 3));
      active = false;
      await add(tester, 'y', 1);
      expect(named('sound'), hasLength(2));
      expect(notified('pending:y').single['silent'], isTrue);
    });

    testWidgets('a finished turn and an answered request do not play; the turn keeps the notification sound', (
      tester,
    ) async {
      await start(tester, MockFlowRepository());
      sessions.addSession(_new('r'), const [], status: 'running');
      await tester.pumpAndSettle();
      await add(tester, 'z', 2);
      expect(named('sound'), hasLength(1));

      clock = clock.add(const Duration(seconds: 10));
      await sessions.interrupt('r');
      await tester.pumpAndSettle();
      await sessions.answer('z', 'z-0', PermissionDecision.allow);
      await tester.pumpAndSettle();

      expect(named('sound'), hasLength(1));
      expect(notified('done:r').single.containsKey('silent'), isFalse);
    });

    testWidgets('inside the interval a new request is dropped, still with a silent notification', (tester) async {
      await start(tester, MockFlowRepository());
      await add(tester, 'a', 1);
      clock = clock.add(const Duration(seconds: 1));
      await add(tester, 'b', 1);
      expect(named('sound'), hasLength(1));
      expect(notified('pending:b').single['silent'], isTrue);

      clock = clock.add(const Duration(seconds: 2));
      await add(tester, 'c', 1);
      expect(named('sound'), hasLength(2));
    });

    testWidgets('gate sem conversa não toca nem notifica', (tester) async {
      final data = [...MockFlowRepository().data];
      final repo = MockFlowRepository(data: data);
      await start(tester, repo);
      int badge() => (named('badge').last.arguments as Map)['count'] as int;
      final before = badge();

      data.add(
        const Project(
          name: 'orfao',
          cycle: Cycle(
            stage: Stage.plan,
            runs: [],
            stageMinutes: {},
            reportIsCurrent: true,
            report: ReportDoc(
              feature: 'f',
              startedAt: null,
              stages: [
                StageReport(
                  stage: Stage.plan,
                  status: ReportStatus.running,
                  gate: ReportGate(name: 'plan', status: GateStatus.open),
                ),
              ],
            ),
          ),
        ),
      );
      // Any config write re-emits the projects, as the file watcher would.
      await repo.updateConfig(setAlertSound(true));
      await tester.pumpAndSettle();

      expect(badge(), before + 1);
      expect(named('sound'), isEmpty);
      expect(named('notify'), isEmpty);

      await add(tester, 'x', 1);
      expect(named('sound'), hasLength(1));
      expect(named('notify').map((c) => (c.arguments as Map)['id']), ['pending:x:1']);
      expect(badge(), before + 2);
    });

    testWidgets('turned off, nothing plays and the notification keeps its sound', (tester) async {
      final repo = MockFlowRepository();
      await repo.updateConfig(setAlertSound(false));
      await start(tester, repo);
      await add(tester, 'x', 1);

      expect(named('sound'), isEmpty);
      expect(notified('pending:x').single.containsKey('silent'), isFalse);
    });

    testWidgets('without a loaded config nothing plays', (tester) async {
      await start(tester, _NoConfigRepository(), settle: false);
      await add(tester, 'x', 1, settle: false);
      await tester.pump();

      expect(named('sound'), isEmpty);
      expect(notified('pending:x').single.containsKey('silent'), isFalse);
    });
  });
}
