import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _path = '/dev/trava';
const _engineError = 'engine indisponível';
const _oldRun = 'impl-20260310T100000Z';
const _newRun = 'impl-20260311T100000Z';
const _commands = {
  'replan': '/plan',
  'fix_spec': '/challenge-spec',
  'fix_environment': '/implement',
  'split_task': '/tasks',
};

class _FailingSessions extends MockSessionsRepository {
  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  }) async => throw const SessionsException(_engineError, statusCode: 500);
}

class _SlowSessions extends MockSessionsRepository {
  final gate = Completer<void>();

  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  }) async {
    await gate.future;
    return super.create(
      project,
      command,
      cwd: cwd,
      githubAccount: githubAccount,
      permissionMode: permissionMode,
      agent: agent,
    );
  }
}

/// A fixed list, as the engine would report it, with no seed session.
class _FixedSessions extends MockSessionsRepository {
  _FixedSessions(this.list);

  final List<SessionSummary> list;

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.value(list);

  @override
  Stream<SessionDetail> watchSession(String id) =>
      Stream.value(SessionDetail(summary: list.firstWhere((s) => s.id == id)));
}

SessionSummary _session(String id, String command, {int pending = 0}) => SessionSummary(
  id: id,
  project: 'trava',
  command: command,
  title: command,
  status: pending > 0 ? SessionStatus.waitingPermission : SessionStatus.idle,
  createdAt: '2026-03-11T10:05:00Z',
  pendingPermissions: pending,
);

Hypothesis _hypothesis(String action, double confidence) =>
    Hypothesis(lens: 'x', hypothesis: 'hipótese $action', confidence: confidence, evidence: const [], action: action);

TaskRun _task(String id, Verdict status, {List<Hypothesis> diagnosis = const []}) => TaskRun(
  id: id,
  title: 'Titulo $id',
  complexity: Complexity.m,
  tier0: Tier.haiku,
  status: status,
  // Without attempts the Execuções would show the plan's status, not the run's.
  attempts: [
    if (status != Verdict.pending) Attempt(number: 1, ordinal: 1, tier: Tier.haiku, gates: [GateResult('g0', status)]),
  ],
  blockedReason: status == Verdict.blocked ? 'max_attempts' : null,
  diagnosis: diagnosis,
);

Run _run(String id, List<TaskRun> tasks) =>
    Run(id: id, kind: 'implement', status: Verdict.blocked, startedAt: '10/03 10:00', tasks: tasks);

final _all = [
  _hypothesis('replan', 0.9),
  _hypothesis('fix_spec', 0.7),
  _hypothesis('fix_environment', 0.5),
  _hypothesis('split_task', 0.3),
  _hypothesis('human_takeover', 0.1),
];

/// `Cycle.runs` is newest first: T3 of the newer run holds the decision, T2 of the older one is history.
List<Project> _data({String? path = _path}) => [
  Project(
    name: 'trava',
    path: path,
    cycle: Cycle(
      stage: Stage.implement,
      stageMinutes: const {},
      runs: [
        _run(_newRun, [_task('T3', Verdict.blocked, diagnosis: _all)]),
        _run(_oldRun, [_task('T1', Verdict.pass), _task('T2', Verdict.blocked, diagnosis: _all)]),
      ],
      plan: [
        for (final id in ['T1', 'T2', 'T3']) _task(id, Verdict.pending),
      ],
    ),
  ),
  // Keeps the org with a root when `trava` has no folder.
  const Project(name: 'vizinho', path: '/dev/vizinho'),
];

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

Finder _action(String action, {String? run}) =>
    find.byKey(ValueKey(run == null ? 'diagnosis-action-$action' : 'diagnosis-action-$run-$action'));

bool _enabled(WidgetTester tester, Finder button) => tester.widget<ButtonStyleButton>(button).enabled;

final _note = find.descendant(of: find.byKey(const ValueKey('diagnosis-note')), matching: find.byType(Text));
final _error = find.byKey(const ValueKey('diagnosis-error'));
final _palette = find.textContaining('Nova conversa');

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  Future<MockSessionsRepository> pump(
    WidgetTester tester,
    String location, {
    MockSessionsRepository? sessions,
    List<Project>? data,
  }) async {
    final repo = sessions ?? MockSessionsRepository();
    data ??= _data();
    final config = MockFlowRepository.defaultConfig(data);
    ((config['orgs'] as List).first as Map<String, dynamic>)
      ..['github'] = {
        'account': 'acct-a',
        'owners': ['org-x'],
      }
      ..['permissionMode'] = 'auto';
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(data: data, config: config),
        sessions: repo,
        engine: const MockEngineController(),
      ),
    );
    await tester.pumpAndSettle();
    _router(tester).go(location);
    await tester.pumpAndSettle();
    return repo;
  }

  group('diagnóstico na tela da task', () {
    const blocked = '/p/trava/runs/$_newRun/T3';

    for (final MapEntry(key: action, value: command) in _commands.entries) {
      testWidgets('launch: $action creates a $command session and opens it', (tester) async {
        final sessions = await pump(tester, blocked);

        await tester.tap(_action(action));
        await tester.pumpAndSettle();

        expect(sessions.createCalls, [('trava', command, _path, 'acct-a', PermissionMode.auto)]);
        expect(_location(tester), '/p/trava/sessions/mock-1');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('launch: human_takeover opens the project palette and creates nothing', (tester) async {
      final sessions = await pump(tester, blocked);
      expect(find.byKey(const ValueKey('diagnosis-note')), findsNothing);
      expect(_palette, findsNothing);

      await tester.tap(_action('human_takeover'));
      await tester.pumpAndSettle();

      expect(_palette, findsWidgets);
      expect(sessions.createCalls, isEmpty);
      expect(_location(tester), blocked);
    });

    testWidgets('launch: a project without a folder shows the error and creates nothing', (tester) async {
      final sessions = await pump(tester, blocked, data: _data(path: null));

      await tester.tap(_action('replan'));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(_error).data, 'sem pasta para trava: adicione a pasta em Configurações');
      expect(sessions.createCalls, isEmpty);
      expect(_location(tester), blocked);
    });

    testWidgets('answer: the buttons go to the conversation that is asking, without creating', (tester) async {
      final sessions = await pump(
        tester,
        blocked,
        sessions: _FixedSessions([_session('s-plan', '/plan', pending: 1), _session('s-livre', 'me explica')]),
      );

      expect(tester.widget<Text>(_note).data, 'A conversa da etapa já está perguntando isto: responda lá.');
      for (final action in [..._commands.keys, 'human_takeover']) {
        expect(_enabled(tester, _action(action)), isTrue, reason: action);
      }

      await tester.tap(_action('replan'));
      await tester.pumpAndSettle();

      expect(sessions.createCalls, isEmpty);
      expect(_location(tester), '/p/trava/sessions/s-plan');
    });

    testWidgets('busy: the command buttons are off and the palette still opens', (tester) async {
      final sessions = await pump(tester, blocked, sessions: _FixedSessions([_session('s-impl', '/implement')]));

      expect(tester.widget<Text>(_note).data, 'Já há uma conversa do pipeline rodando neste projeto.');
      for (final action in _commands.keys) {
        expect(_enabled(tester, _action(action)), isFalse, reason: action);
      }

      await tester.tap(_action('human_takeover'));
      await tester.pumpAndSettle();
      expect(_palette, findsWidgets);
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('inert: the blocked task of an old run has every button off', (tester) async {
      await pump(tester, '/p/trava/runs/$_oldRun/T2');

      for (final action in [..._commands.keys, 'human_takeover']) {
        expect(_enabled(tester, _action(action)), isFalse, reason: action);
      }
      expect(find.byKey(const ValueKey('diagnosis-note')), findsNothing);
    });

    testWidgets('a create in flight turns every button off', (tester) async {
      final sessions = _SlowSessions();
      await pump(tester, blocked, sessions: sessions);

      await tester.tap(_action('replan'));
      await tester.pump();
      for (final action in [..._commands.keys, 'human_takeover']) {
        expect(_enabled(tester, _action(action)), isFalse, reason: action);
      }
      expect(sessions.createCalls, isEmpty);

      sessions.gate.complete();
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$2, '/plan');
      expect(_location(tester), '/p/trava/sessions/mock-1');
    });

    testWidgets('a failed create shows the message and turns the buttons back on', (tester) async {
      await pump(tester, blocked, sessions: _FailingSessions());
      expect(_error, findsNothing);

      await tester.tap(_action('split_task'));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(_error).data, contains(_engineError));
      for (final action in [..._commands.keys, 'human_takeover']) {
        expect(_enabled(tester, _action(action)), isTrue, reason: action);
      }
      expect(_location(tester), blocked);
    });
  });

  group('diagnóstico nas Execuções', () {
    testWidgets('two blocked runs render one panel each, with keys of their own run', (tester) async {
      final sessions = await pump(tester, '/p/trava/runs');

      expect(find.byKey(const ValueKey('diagnosis-$_oldRun')), findsOneWidget);
      expect(find.byKey(const ValueKey('diagnosis-$_newRun')), findsOneWidget);
      expect(_action('replan', run: _oldRun), findsOneWidget);
      expect(_action('replan', run: _newRun), findsOneWidget);
      expect(_action('replan'), findsNothing);
      expect(_enabled(tester, _action('replan', run: _oldRun)), isFalse);
      expect(_enabled(tester, _action('replan', run: _newRun)), isTrue);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(_action('replan', run: _newRun));
      await tester.pumpAndSettle();
      await tester.tap(_action('replan', run: _newRun));
      await tester.pumpAndSettle();
      expect(sessions.createCalls, [('trava', '/plan', _path, 'acct-a', PermissionMode.auto)]);
      expect(_location(tester), '/p/trava/sessions/mock-1');
    });
  });
}
