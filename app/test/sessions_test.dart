import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/session_reducer.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/data/sse.dart';
import 'package:claude_flow/core/widgets/image_attachments.dart';
import 'package:claude_flow/core/widgets/markdown_view.dart';
import 'package:claude_flow/features/sessions/session_artifacts.dart';
import 'package:claude_flow/features/sessions/session_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _noCwd = 'sem diretório para demo-app: defina cwds.demo-app em ~/.claude/workflow/.dashboard.json';

class _RecordingSessions extends MockSessionsRepository {
  final created = <(String, String)>[];
  final cwds = <String?>[];

  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  }) {
    created.add((project, command));
    cwds.add(cwd);
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

class _NoCwdSessions extends MockSessionsRepository {
  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  }) async => throw const SessionsException(_noCwd, statusCode: 400);
}

const _longCommand =
    '/implement --tier opus --task T3 sessões com cwd, filtro por org, troca e atalhos em qualquer rota do app';

class _LongCommandSessions extends MockSessionsRepository {
  @override
  Stream<List<SessionSummary>> watchSessions() => super.watchSessions().map(
    (list) => [
      const SessionSummary(
        id: 'long',
        project: 'demo-app',
        command: _longCommand,
        title: 'Uma sessão com um título bem longo que também precisa caber em uma linha só',
        status: SessionStatus.done,
        createdAt: '2026-03-10T14:41:00Z',
      ),
      ...list,
    ],
  );
}

/// A pending org session in `demo`: counts for the org, never for a project.
class _OrgActivitySessions extends MockSessionsRepository {
  @override
  Stream<List<SessionSummary>> watchSessions() => super.watchSessions().map(
    (list) => [
      const SessionSummary(
        id: 'org-1',
        project: '',
        command: 'analise os repos',
        title: 'Atividade na org demo',
        status: SessionStatus.waitingPermission,
        createdAt: '2026-03-10T14:41:00Z',
        pendingPermissions: 3,
        org: 'demo',
        cwd: '/nowhere',
      ),
      ...list,
    ],
  );
}

/// Every session runs on Antigravity, which has no skills.
class _AgySessions extends MockSessionsRepository {
  static SessionSummary _agy(SessionSummary s) => SessionSummary(
    id: s.id,
    project: s.project,
    command: s.command,
    title: s.title,
    status: s.status,
    createdAt: s.createdAt,
    cost: s.cost,
    pendingPermissions: s.pendingPermissions,
    resumable: s.resumable,
    model: s.model,
    cwd: s.cwd,
    permissionMode: s.permissionMode,
    interrupted: s.interrupted,
    provider: AgentProvider.antigravity,
    account: 'default',
  );

  @override
  Stream<List<SessionSummary>> watchSessions() => super.watchSessions().map((list) => list.map(_agy).toList());

  @override
  Stream<SessionDetail> watchSession(String id) =>
      super.watchSession(id).map((d) => d.copyWith(summary: _agy(d.summary)));
}

class _RefusingModeSessions extends MockSessionsRepository {
  @override
  Future<void> setPermissionMode(String id, PermissionMode mode) async {
    setPermissionModeCalls.add((id, mode));
    throw const SessionsException('bypass_disabled', statusCode: 409);
  }
}

/// A detached session in bypass, known only from the list (its detail stream never emits).
class _DetachedBypassSessions extends MockSessionsRepository {
  @override
  Stream<List<SessionSummary>> watchSessions() => super.watchSessions().map(
    (list) => [
      const SessionSummary(
        id: 'detached-bypass',
        project: 'demo-app',
        command: '/status',
        title: 'Sessão antiga em bypass',
        status: SessionStatus.detached,
        createdAt: '2026-03-10T14:41:00Z',
        permissionMode: PermissionMode.bypassPermissions,
      ),
      ...list,
    ],
  );
}

/// A done session with 200 messages whose stream the test appends to.
class _FeedSessions extends MockSessionsRepository {
  static const _summary = SessionSummary(
    id: 'feed',
    project: 'demo-app',
    command: '/status',
    title: 'Feed longo',
    status: SessionStatus.done,
    createdAt: '2026-03-08T10:00:00Z',
  );

  final _updates = StreamController<SessionDetail>.broadcast();
  var _detail = SessionDetail(
    summary: _summary,
    events: [for (var i = 0; i < 200; i++) AssistantText('', 'mensagem $i')],
    lastSeq: 200,
  );

  void push(String text) {
    _detail = _detail.copyWith(events: [..._detail.events, AssistantText('', text)], lastSeq: _detail.lastSeq + 1);
    _updates.add(_detail);
  }

  @override
  Stream<List<SessionSummary>> watchSessions() => super.watchSessions().map((list) => [...list, _summary]);

  @override
  Stream<SessionDetail> watchSession(String id) {
    if (id != _summary.id) return super.watchSession(id);
    return Stream.multi((controller) {
      controller.add(_detail);
      final sub = _updates.stream.listen(controller.add);
      controller.onCancel = sub.cancel;
    });
  }
}

/// An idle session whose log ends in `reattached`: the engine restarted under it.
class _ReattachedSessions extends MockSessionsRepository {
  static const _summary = SessionSummary(
    id: 'reattached',
    project: 'demo-app',
    command: '/plan',
    title: 'Sessão reanexada',
    status: SessionStatus.idle,
    createdAt: '2026-03-08T10:00:00Z',
  );

  @override
  Stream<List<SessionSummary>> watchSessions() => super.watchSessions().map((list) => [...list, _summary]);

  @override
  Stream<SessionDetail> watchSession(String id) {
    if (id != _summary.id) return super.watchSession(id);
    final frames = [
      SseFrame('event', jsonEncode({'seq': 1, 'at': '', 'kind': 'user_text', 'text': '/plan'})),
      SseFrame('event', jsonEncode({'seq': 2, 'at': '', 'kind': 'reattached'})),
    ];
    return Stream.value(frames.fold(const SessionDetail(summary: _summary), applyFrame));
  }
}

Finder _headerStatus(String label) =>
    find.descendant(of: find.byKey(const ValueKey('session-status')), matching: find.text(label));

final _newMessages = find.byKey(const ValueKey('session-new-messages'));

Finder _message(int i) => find.text('mensagem $i', findRichText: true);

ScrollPosition _feedPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: find.byKey(const ValueKey('session-feed')), matching: find.byType(Scrollable)).first,
    )
    .position;

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

final _headerMode = find.byKey(const ValueKey('session-permission-mode'));

Finder _headerModeText(String label) => find.descendant(of: _headerMode, matching: find.text(label));

Future<void> _chooseHeaderMode(WidgetTester tester, String label) async {
  await tester.tap(_headerMode);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
  if (label == 'bypass') {
    await tester.tap(find.text('Usar bypass'));
    await tester.pumpAndSettle();
  }
}

Finder _paletteField() => find.byType(TextField).last;

Finder _paletteList() =>
    find.ancestor(of: find.text('Nova conversa em demo-app'), matching: find.byType(ListView)).first;

Finder _inPalette(String label) => find.descendant(of: _paletteList(), matching: find.text(label));

Finder _selected(String label) => find.descendant(
  of: find.ancestor(of: _inPalette(label), matching: find.byType(Row)).first,
  matching: find.text('↵'),
);

Future<void> _cmdEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

/// An idle session whose last turn failed on the Antigravity quota.
MockSessionsRepository _failedTurnSessions() => MockSessionsRepository()
  ..addSession(
    const SessionSummary(
      id: 'failed',
      project: 'demo-app',
      command: 'refatore o cache',
      title: 'Turno com erro',
      status: SessionStatus.idle,
      createdAt: '2026-03-10T14:41:00Z',
    ),
    [
      {'kind': 'user_text', 'text': 'refatore o cache'},
      {
        'kind': 'result',
        'isError': true,
        'text': 'RESOURCE_EXHAUSTED (code 429): Individual quota reached. Resets in 30h0m0s.',
        'cost': 0,
        'durationMs': 3000,
        'numTurns': 1,
      },
    ],
  );

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  Future<void> openSessions(WidgetTester tester, {SessionsRepository? sessions, MockFlowRepository? repository}) async {
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: repository ?? MockFlowRepository(),
        sessions: sessions ?? MockSessionsRepository(),
        engine: const MockEngineController(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 aguardando você'));
    await tester.pumpAndSettle();
  }

  Future<void> openPalette(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('pending badge opens the session waiting for permission and allowing resolves it', (tester) async {
    await openSessions(tester);

    expect(find.text('aguardando permissão'), findsOneWidget);
    expect(find.text('lib/features/favorites/data/favorites_sync.dart'), findsOneWidget);

    await tester.ensureVisible(find.text('Permitir'));
    await tester.tap(find.text('Permitir'));
    await tester.pumpAndSettle();
    expect(find.text('permitido'), findsOneWidget);
    expect(find.text('Permitir'), findsNothing);
    expect(find.text('2 aguardando você'), findsOneWidget);
    expect(find.text('3 aguardando você'), findsNothing);
  });

  testWidgets('an org session stays out of the project list and badges but counts for the org', (tester) async {
    await openSessions(tester, sessions: _OrgActivitySessions());

    expect(find.text('Atividade na org demo'), findsNothing);
    expect(find.text('3 aguardando você'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('org-pending')), matching: find.text('6')), findsOneWidget);
  });

  testWidgets('denying a permission resolves the card and decrements the badge', (tester) async {
    await openSessions(tester);

    await tester.ensureVisible(find.text('Negar'));
    await tester.tap(find.text('Negar'));
    await tester.pumpAndSettle();
    expect(find.text('negado'), findsOneWidget);
    expect(find.text('Permitir'), findsNothing);
    expect(find.text('2 aguardando você'), findsOneWidget);
  });

  testWidgets('question card answers with the selected options', (tester) async {
    await openSessions(tester);
    await tester.tap(find.text('Desafio da spec Favoritos offline'));
    await tester.pumpAndSettle();

    final respond = find.widgetWithText(FilledButton, 'Responder');
    expect(tester.widget<FilledButton>(respond).onPressed, isNull);

    await tester.tap(find.text('B1'));
    await tester.tap(find.text('A2'));
    await tester.pumpAndSettle();
    await tester.tap(respond);
    await tester.pumpAndSettle();
    expect(find.text('respondido: B1, A2'), findsOneWidget);
    expect(find.text('2 aguardando você'), findsOneWidget);
  });

  testWidgets('detached session resumes and then accepts a message with cmd+enter', (tester) async {
    await openSessions(tester);
    await tester.tap(find.text('Status do fluxo'));
    await tester.pumpAndSettle();
    expect(find.text('desanexada'), findsOneWidget);
    // Outside the feed, so it stays visible with the feed scrolled to the end.
    expect(
      find.descendant(of: find.byKey(const ValueKey('session-feed')), matching: find.text('Retomar')),
      findsNothing,
    );

    await tester.tap(find.text('Retomar'));
    await tester.pumpAndSettle();
    expect(find.text('desanexada'), findsNothing);
    expect(find.text('Retomar'), findsNothing);
    expect(_headerStatus(kInterruptedLabel), findsOneWidget);
    expect(find.byKey(const ValueKey('session-interrupted-s-status')), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'e agora?');
    await _cmdEnter(tester);
    expect(find.text('e agora?'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, isEmpty);
    expect(_headerStatus('aguardando resposta'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-interrupted-s-status')), findsNothing);
  });

  testWidgets('a /skill in an Antigravity session is held in the composer with the reason', (tester) async {
    final sessions = _AgySessions();
    await openSessions(tester, sessions: sessions);
    await tester.tap(find.text('Status do fluxo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retomar'));
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('composer-input'));
    await tester.enterText(input, '/kickoff --manual idioma');
    await _cmdEnter(tester);
    expect(find.textContaining('Sessões Antigravity não rodam skills'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, '/kickoff --manual idioma');
    expect(sessions.sendCalls, isEmpty);

    await tester.enterText(input, 'sem skill');
    await tester.pump();
    expect(find.textContaining('Sessões Antigravity não rodam skills'), findsNothing);
    await _cmdEnter(tester);
    expect(sessions.sendCalls.single.$2, 'sem skill');
  });

  testWidgets('a terminal session of the project opens in the app with its history and leaves the list', (tester) async {
    final sessions = MockSessionsRepository();
    sessions.terminal['~/development/demo-app'] = [
      TerminalSession(
        sdkSessionId: 'aaa',
        cwd: '~/development/demo-app/packages/core',
        title: 'Greet com idioma',
        firstPrompt: 'como funciona o greet?',
        updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        live: 'busy',
      ),
    ];
    await tester.pumpWidget(
      ClaudeFlowApp(repository: MockFlowRepository(), sessions: sessions, engine: const MockEngineController()),
    );
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/demo-app/sessions');
    await tester.pumpAndSettle();

    expect(find.text('No terminal'), findsOneWidget);
    expect(find.textContaining('packages/core · aberta no terminal'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-session-aaa')));
    await tester.pumpAndSettle();

    expect(sessions.importCalls.single.$1, 'aaa');
    expect(sessions.importCalls.single.$2, '~/development/demo-app/packages/core');
    expect(sessions.importCalls.single.$3, 'demo-app');
    expect(find.text('trazida do terminal'), findsOneWidget);
    expect(find.textContaining('Sessão trazida do terminal. Retomar continua'), findsOneWidget);
    expect(find.text('No terminal'), findsNothing);
  });

  testWidgets('the terminal /app imports the session into its project and opens it; outside projects it explains', (
    tester,
  ) async {
    final sessions = MockSessionsRepository();
    sessions.terminal['~/development/demo-app/packages/core'] = [
      TerminalSession(
        sdkSessionId: 'aaa',
        cwd: '~/development/demo-app/packages/core',
        title: 'Greet com idioma',
        firstPrompt: 'como funciona o greet?',
        updatedAt: DateTime.now(),
        live: 'busy',
      ),
    ];
    await tester.pumpWidget(
      ClaudeFlowApp(repository: MockFlowRepository(), sessions: sessions, engine: const MockEngineController()),
    );
    await tester.pumpAndSettle();

    sessions.requestHandoff('aaa', '~/development/demo-app/packages/core');
    await tester.pumpAndSettle();
    expect(sessions.importCalls.single.$3, 'demo-app');
    expect(find.text('trazida do terminal'), findsOneWidget);
    expect(find.text('como funciona o greet?'), findsWidgets);

    sessions.requestHandoff('bbb', '/tmp/solto');
    await tester.pumpAndSettle();
    expect(sessions.importCalls, hasLength(1));
    expect(find.textContaining('/tmp/solto não está em nenhum projeto do app'), findsOneWidget);
  });

  testWidgets('asking aside opens a read-only fork marked in the list, with the way back to the original', (tester) async {
    final sessions = MockSessionsRepository();
    await openSessions(tester, sessions: sessions);
    await tester.tap(find.text('Status do fluxo'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('session-aside')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('aside-text')), 'por que o spec mudou?');
    await tester.tap(find.byKey(const ValueKey('aside-send')));
    await tester.pumpAndSettle();

    final parent = sessions.asideCalls.single.$1;
    expect(sessions.asideCalls.single.$2, 'por que o spec mudou?');
    expect(find.byKey(const ValueKey('aside-banner')), findsOneWidget);
    expect(find.textContaining('Pergunta à parte de “Status do fluxo”'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-aside')), findsNothing, reason: 'no aside of an aside');
    expect(find.textContaining('· à parte · '), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('aside-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('aside-banner')), findsNothing);
    expect(GoRouter.of(tester.element(find.byType(Scaffold).first)).state.uri.path, endsWith('/sessions/$parent'));
  });

  testWidgets('a snapshot ending in reattached shows interrupted in the header and the tile', (tester) async {
    await openSessions(tester, sessions: _ReattachedSessions());
    await tester.tap(find.text('Sessão reanexada'));
    await tester.pumpAndSettle();

    expect(_headerStatus(kInterruptedLabel), findsOneWidget);
    expect(find.byKey(const ValueKey('session-interrupted-reattached')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-interrupted-s-challenge')), findsNothing);
  });

  group('conversation scroll', () {
    Future<_FeedSessions> openFeed(WidgetTester tester) async {
      final sessions = _FeedSessions();
      await openSessions(tester, sessions: sessions);
      _router(tester).go('/p/demo-app/sessions/feed');
      await tester.pumpAndSettle();
      return sessions;
    }

    testWidgets('opening a session with 200 events leaves the list at the end', (tester) async {
      await openFeed(tester);

      final p = _feedPosition(tester);
      expect(p.maxScrollExtent, greaterThan(0));
      expect(p.pixels, p.maxScrollExtent);
      expect(_message(199), findsOneWidget);
      expect(_message(0), findsNothing);
    });

    testWidgets('switching sessions goes to the end of the new one', (tester) async {
      await openFeed(tester);
      _feedPosition(tester).jumpTo(0);
      await tester.pump();

      await tester.tap(find.text('Desafio da spec Favoritos offline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feed longo'));
      await tester.pumpAndSettle();

      final p = _feedPosition(tester);
      expect(p.pixels, p.maxScrollExtent);
    });

    testWidgets('near the end a new event follows it without the button', (tester) async {
      final sessions = await openFeed(tester);

      sessions.push('mensagem nova');
      await tester.pumpAndSettle();

      final p = _feedPosition(tester);
      expect(p.pixels, p.maxScrollExtent);
      expect(find.text('mensagem nova', findRichText: true), findsOneWidget);
      expect(_newMessages, findsNothing);
    });

    testWidgets('scrolled to the top a new event does not scroll and the button goes to the end', (tester) async {
      final sessions = await openFeed(tester);
      _feedPosition(tester).jumpTo(0);
      await tester.pumpAndSettle();

      sessions.push('mensagem nova');
      await tester.pumpAndSettle();

      expect(_feedPosition(tester).pixels, 0);
      expect(_newMessages, findsOneWidget);

      await tester.tap(_newMessages);
      await tester.pumpAndSettle();

      final p = _feedPosition(tester);
      expect(p.pixels, p.maxScrollExtent);
      expect(find.text('mensagem nova', findRichText: true), findsOneWidget);
      expect(_newMessages, findsNothing);
    });

    testWidgets('scrolling back near the end hides the button', (tester) async {
      final sessions = await openFeed(tester);
      _feedPosition(tester).jumpTo(0);
      await tester.pumpAndSettle();
      sessions.push('mensagem nova');
      await tester.pumpAndSettle();
      expect(_newMessages, findsOneWidget);

      final p = _feedPosition(tester);
      p.jumpTo(p.maxScrollExtent - 40);
      await tester.pumpAndSettle();

      expect(_newMessages, findsNothing);
    });
  });

  testWidgets('interrupting a session waiting for permission leaves it awaiting a reply', (tester) async {
    await openSessions(tester);
    expect(find.text('aguardando permissão'), findsOneWidget);

    await tester.tap(find.text('Interromper'));
    await tester.pumpAndSettle();
    expect(find.text('aguardando resposta'), findsOneWidget);
    expect(find.text('Interromper'), findsNothing);
  });

  testWidgets('opening a session from another project moves the sidebar selection', (tester) async {
    await openSessions(tester);
    await tester.tap(find.text('Review PR #412 retry com backoff'));
    await tester.pumpAndSettle();
    expect(find.text('Retry com backoff'), findsWidgets);
    expect(find.text('concluída'), findsOneWidget);
  });

  testWidgets('switching sessions swaps the panel without a page transition', (tester) async {
    await openSessions(tester);
    expect(find.text('aguardando permissão'), findsOneWidget);

    await tester.tap(find.text('Desafio da spec Favoritos offline'));
    await tester.pump();
    expect(find.text('aguardando resposta'), findsOneWidget);
    expect(find.text('aguardando permissão'), findsNothing);
  });

  testWidgets('a long command stays on one ellipsized line with the full text in a tooltip', (tester) async {
    await openSessions(tester, sessions: _LongCommandSessions());

    expect(tester.takeException(), isNull);
    final command = find.text(_longCommand).first;
    final text = tester.widget<Text>(command);
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(find.byTooltip(_longCommand), findsOneWidget);
    final list = find.ancestor(of: command, matching: find.byType(ListView)).first;
    expect(tester.getRect(command).right, lessThanOrEqualTo(tester.getRect(list).right));
    expect(tester.getSize(command).height, lessThan(20));
  });

  testWidgets('a failed turn shows a card with the reset and "Tentar de novo" sends a continue', (tester) async {
    final sessions = _failedTurnSessions();
    await openSessions(tester, sessions: sessions);
    await tester.tap(find.text('Turno com erro'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('failure-card')), findsOneWidget);
    expect(find.text('Cota do modelo esgotada'), findsOneWidget);
    expect(find.text('renova em 1d 6h'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('failure-retry')));
    await tester.pumpAndSettle();
    expect(sessions.sendCalls.single.$2, 'Continue de onde parou.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the session search filters by title or command, case-insensitive', (tester) async {
    await openSessions(tester, sessions: _failedTurnSessions());

    final list = find.ancestor(of: find.byKey(const ValueKey('sessions-search')), matching: find.byType(ListView));
    expect(find.descendant(of: list, matching: find.text('Status do fluxo')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('sessions-search')), 'turno com ERRO');
    await tester.pumpAndSettle();
    expect(find.descendant(of: list, matching: find.text('Turno com erro')), findsOneWidget);
    expect(find.descendant(of: list, matching: find.text('Status do fluxo')), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('sessions-search')), 'nada assim');
    await tester.pumpAndSettle();
    expect(find.text('nada encontrado'), findsOneWidget);
  });

  group('permission mode in the session header', () {
    testWidgets('a bypass session shows the red badge; switching to padrão calls the engine and drops it', (
      tester,
    ) async {
      final sessions = MockSessionsRepository();
      final config = MockFlowRepository.defaultConfig(MockFlowRepository().data);
      config['permissionMode'] = 'bypassPermissions';
      await openSessions(
        tester,
        sessions: sessions,
        repository: MockFlowRepository(config: config),
      );
      await tester.tap(find.text('Nova conversa'));
      await tester.pumpAndSettle();
      await tester.enterText(_paletteField(), 'resuma o plano');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(sessions.createCalls.single.$5, PermissionMode.bypassPermissions);
      expect(_headerModeText('bypass'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-bypass-mock-1')), findsOneWidget);

      await _chooseHeaderMode(tester, 'padrão');

      expect(sessions.setPermissionModeCalls, [('mock-1', PermissionMode.defaultMode)]);
      expect(_headerModeText('bypass'), findsNothing);
      expect(_headerModeText('padrão'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-bypass-mock-1')), findsNothing);
    });

    testWidgets('a refused change goes back to the previous mode and shows the engine error', (tester) async {
      final sessions = _RefusingModeSessions();
      await openSessions(tester, sessions: sessions);
      expect(_headerModeText('padrão'), findsOneWidget);

      await _chooseHeaderMode(tester, 'bypass');

      expect(sessions.setPermissionModeCalls, [('s-fix-sync', PermissionMode.bypassPermissions)]);
      expect(_headerModeText('padrão'), findsOneWidget);
      expect(_headerModeText('bypass'), findsNothing);
      expect(find.text('bypass_disabled'), findsOneWidget);
    });

    testWidgets('a detached session in bypass keeps the badge in the header and the tile', (tester) async {
      await openSessions(tester, sessions: _DetachedBypassSessions());
      expect(find.byKey(const ValueKey('session-bypass-detached-bypass')), findsOneWidget);
      expect(find.byKey(const ValueKey('session-bypass-s-fix-sync')), findsNothing);

      await tester.tap(find.text('Sessão antiga em bypass'));
      await tester.pumpAndSettle();
      expect(find.text('desanexada'), findsOneWidget);
      expect(_headerModeText('bypass'), findsOneWidget);
    });
  });

  group('command palette', () {
    testWidgets('typing two or more characters searches sessions; a result opens it', (tester) async {
      await openSessions(tester);
      await openPalette(tester);

      await tester.enterText(find.byType(TextField).last, 'status do');
      await tester.pumpAndSettle();
      final jump = find.byKey(const ValueKey('palette-jump-/p/demo-app/sessions/s-status'));
      expect(jump, findsOneWidget);
      expect(find.text('Ir para'), findsOneWidget);

      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(find.text('Ir para'), findsNothing);
      expect(
        GoRouter.of(tester.element(find.byType(Scaffold).first)).routerDelegate.currentConfiguration.uri.path,
        '/p/demo-app/sessions/s-status',
      );

      await openPalette(tester);
      await tester.enterText(find.byType(TextField).last, 'x');
      await tester.pumpAndSettle();
      expect(find.text('Ir para'), findsNothing);
    });

    testWidgets('arrows move the selection, enter picks the skill and runs it with arguments', (tester) async {
      final sessions = _RecordingSessions();
      await openSessions(tester, sessions: sessions);
      await openPalette(tester);

      expect(_inPalette('/fix'), findsOneWidget);
      expect(_inPalette('/status'), findsOneWidget);
      expect(_inPalette('/review'), findsOneWidget);
      expect(_selected('/fix'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_selected('/status'), findsOneWidget);
      expect(_selected('/fix'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_selected('Nova conversa em demo-app'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(_selected('/status'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('argumentos (opcional)'), findsOneWidget);
      expect(find.descendant(of: _paletteField(), matching: find.text('/status')), findsOneWidget);

      await tester.enterText(_paletteField(), 'agora');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(sessions.created, [('demo-app', '/status agora')]);
      expect(sessions.cwds, ['~/development/demo-app']);
      expect(find.text('Nova conversa em demo-app'), findsNothing);
      expect(find.text('/status agora'), findsWidgets);
      expect(find.text('aguardando resposta'), findsOneWidget);
    });

    testWidgets('a project session runs with the gh account of the project org', (tester) async {
      final sessions = MockSessionsRepository();
      final config = MockFlowRepository.defaultConfig(MockFlowRepository().data);
      (config['orgs'] as List).first['github'] = {'account': 'acct-a', 'owners': <String>[]};
      await openSessions(
        tester,
        sessions: sessions,
        repository: MockFlowRepository(config: config),
      );

      await tester.tap(find.text('Nova conversa'));
      await tester.pumpAndSettle();
      await tester.enterText(_paletteField(), 'resuma o plano');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(sessions.createCalls.single, (
        'demo-app',
        'resuma o plano',
        '~/development/demo-app',
        'acct-a',
        PermissionMode.acceptEdits,
      ));
    });

    testWidgets('escape closes the palette', (tester) async {
      await openSessions(tester);
      await openPalette(tester);
      expect(find.text('Nova conversa em demo-app'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Nova conversa em demo-app'), findsNothing);
    });

    testWidgets('escape in the arguments step goes back to the list', (tester) async {
      await openSessions(tester);
      await openPalette(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('argumentos (opcional)'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Nova conversa em demo-app'), findsOneWidget);
      expect(_selected('/fix'), findsOneWidget);
    });

    testWidgets('typing filters the skills and keeps the new conversation entry', (tester) async {
      await openSessions(tester);
      await openPalette(tester);
      await tester.enterText(_paletteField(), 'rev');
      await tester.pump();
      expect(_inPalette('/review'), findsOneWidget);
      expect(_inPalette('/fix'), findsNothing);
      expect(find.text('Nova conversa em demo-app'), findsOneWidget);
      expect(_selected('/review'), findsOneWidget);
    });

    testWidgets('new conversation entry sends the free prompt as the command', (tester) async {
      final sessions = _RecordingSessions();
      await openSessions(tester, sessions: sessions);
      await openPalette(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Nova conversa em demo-app: escreva o prompt'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.created, isEmpty, reason: 'empty prompt does not start a session');

      await tester.enterText(_paletteField(), 'responda ok');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.created, [('demo-app', 'responda ok')]);
      expect(find.text('responda ok'), findsWidgets);
    });

    testWidgets('sessions tab button opens the palette on the free prompt', (tester) async {
      final sessions = _RecordingSessions();
      await openSessions(tester, sessions: sessions);

      await tester.tap(find.text('Nova conversa'));
      await tester.pumpAndSettle();
      expect(find.text('Nova conversa em demo-app: escreva o prompt'), findsOneWidget);

      await tester.enterText(_paletteField(), 'resuma o plano');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.created, [('demo-app', 'resuma o plano')]);
    });

    testWidgets('missing cwd shows the engine error inline and keeps the palette open', (tester) async {
      await openSessions(tester, sessions: _NoCwdSessions());
      await openPalette(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text(_noCwd), findsOneWidget);
      expect(find.text('argumentos (opcional)'), findsOneWidget);
    });
  });

  group('Antigravity session', () {
    MockSessionsRepository agySessions() {
      final sessions = MockSessionsRepository();
      sessions.addSession(
        const SessionSummary(
          id: 's-agy',
          project: 'demo-app',
          command: 'analise o fluxo',
          title: 'analise o fluxo',
          status: SessionStatus.idle,
          createdAt: '2026-10-06T10:00:00Z',
          provider: AgentProvider.antigravity,
          account: 'likin.do',
        ),
        [
          {'kind': 'user_text', 'text': 'analise o fluxo'},
          {'kind': 'assistant_text', 'text': 'Artefato de Sessão: [analise.md](analise.md)'},
          {'kind': 'result', 'isError': false, 'cost': 0, 'durationMs': 1000, 'numTurns': 1},
        ],
      );
      sessions.artifacts['s-agy'] = {'analise.md': '# Análise do fluxo\n\nTrês decisões.'};
      return sessions;
    }

    Future<void> open(WidgetTester tester, MockSessionsRepository sessions) async {
      await tester.pumpWidget(
        ClaudeFlowApp(repository: MockFlowRepository(), sessions: sessions, engine: const MockEngineController()),
      );
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/demo-app/sessions/s-agy');
      await tester.pumpAndSettle();
    }

    testWidgets('shows provider and the artifacts strip; a chip opens the artifact', (tester) async {
      await open(tester, agySessions());

      expect(find.text('Antigravity · likin.do'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-artifact-analise.md')));
      await tester.pumpAndSettle();
      expect(find.text('Análise do fluxo'), findsOneWidget);
    });

    testWidgets('the model chip in the header switches the model of the session', (tester) async {
      final sessions = agySessions()..loggedInAccounts.add('likin.do');
      await sessions.setModel('s-agy', 'gemini-3.8-flash-high');
      sessions.setModelCalls.clear();
      await open(tester, sessions);

      await tester.tap(find.byKey(const ValueKey('session-model-s-agy')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Opus 4.6 (Thinking)').last);
      await tester.pumpAndSettle();

      expect(sessions.setModelCalls, [('s-agy', 'claude-opus-4-6-thinking')]);
    });

    testWidgets('⌘V attaches the pasteboard image, sending carries it and the feed shows it', (tester) async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('claude_flow/clipboard'),
        (call) async => call.method == 'image' ? png : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('claude_flow/clipboard'),
          null,
        ),
      );
      final sessions = agySessions();
      await open(tester, sessions);

      await tester.tap(find.byType(TextField).last);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-image-0')), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'o que tem aqui?');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      final (id, text, images) = sessions.sendCalls.single;
      expect((id, text, images.single.mediaType), ('s-agy', 'o que tem aqui?', 'image/png'));
      expect(find.byKey(const ValueKey('composer-image-0')), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget, reason: 'the mock has no engine to load it from');
    });

    testWidgets('dropping an image file on the composer attaches it', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('drop-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/shot.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
          ),
        );
      final sessions = agySessions();
      await open(tester, sessions);

      Future<void> platform(String method, Object? args) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'desktop_drop',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
      final at = tester.getCenter(find.byType(TextField).last);
      await tester.runAsync(() async {
        await platform('entered', [at.dx, at.dy]);
        await platform('performOperation_macos', [
          {'path': file.path},
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-image-0')), findsOneWidget);
    });

    testWidgets('⌘V in the palette prompt attaches the image to the first message', (tester) async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('claude_flow/clipboard'),
        (call) async => call.method == 'image' ? png : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('claude_flow/clipboard'),
          null,
        ),
      );
      final sessions = agySessions();
      await open(tester, sessions);
      await tester.tap(find.text('Nova conversa'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('palette-image-0')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.createImages.single.single.mediaType, 'image/png');
      expect(sessions.createCalls.single.$2, kImagesOnlyText);
    });

    testWidgets('a multi-line command shows its first line and opens whole on tap', (tester) async {
      final sessions = agySessions();
      sessions.addSession(
        const SessionSummary(
          id: 's-cmd',
          project: 'demo-app',
          command: 'versoes',
          title: 'versoes',
          status: SessionStatus.idle,
          createdAt: '2026-10-06T11:00:00Z',
        ),
        [
          {
            'kind': 'tool_use',
            'id': 't1',
            'name': 'Bash',
            'input': {'command': 'python3 -c "\nimport json\nprint(1)\n"'},
          },
          {'kind': 'tool_result', 'id': 't1', 'isError': false, 'text': '1'},
        ],
      );
      await tester.pumpWidget(
        ClaudeFlowApp(repository: MockFlowRepository(), sessions: sessions, engine: const MockEngineController()),
      );
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/p/demo-app/sessions/s-cmd');
      await tester.pumpAndSettle();

      expect(find.text('python3 -c "  (+3 linhas)'), findsOneWidget);
      expect(find.textContaining('import json'), findsNothing);

      await tester.tap(find.text('python3 -c "  (+3 linhas)'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: find.byKey(const ValueKey('tool-command')), matching: find.textContaining('import json')),
        findsOneWidget,
      );
    });

    testWidgets('the artifact dialog copies the content and shows it in Finder', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final sessions = agySessions();
      await open(tester, sessions);

      await tester.tap(find.byKey(const ValueKey('session-artifact-analise.md')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('artifact-copy')));
      await tester.pumpAndSettle();
      expect(copied, ['# Análise do fluxo\n\nTrês decisões.']);

      await tester.tap(find.byKey(const ValueKey('artifact-reveal')));
      await tester.pumpAndSettle();
      expect(sessions.revealCalls, [('s-agy', 'analise.md')]);
    });

    testWidgets('a link to the artifact in the reply opens it in the app', (tester) async {
      await open(tester, agySessions());

      final markdown = find.byWidgetPredicate((w) => w is MarkdownView && w.source.contains('analise.md'));
      tester.widget<MarkdownView>(markdown).onLink(Uri.parse('analise.md'));
      await tester.pumpAndSettle();
      expect(find.text('Três decisões.'), findsOneWidget);
    });
  });

  group('artifactLinkName', () {
    test('relative names and file URIs inside brain/ are artifacts; web links and nested paths are not', () {
      expect(artifactLinkName(Uri.parse('analise.md')), 'analise.md');
      expect(artifactLinkName(Uri.parse('./analise.md')), 'analise.md');
      expect(artifactLinkName(Uri.parse('file:///Users/x/.gemini/antigravity-cli/brain/c1/analise.md')), 'analise.md');
      expect(artifactLinkName(Uri.parse('file:///Users/x/repo/docs/a.md')), isNull);
      expect(artifactLinkName(Uri.parse('docs/a.md')), isNull);
      expect(artifactLinkName(Uri.parse('https://example.com/a.md')), isNull);
      expect(artifactLinkName(Uri.parse('.hidden')), isNull);
    });
  });
}
