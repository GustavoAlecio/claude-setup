import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _noCwd = 'sem diretório para demo-app: defina cwds.demo-app em ~/.claude/workflow/.dashboard.json';

class _RecordingSessions extends MockSessionsRepository {
  final created = <(String, String)>[];
  final cwds = <String?>[];

  @override
  Future<SessionSummary> create(String project, String command, {String? cwd, String? githubAccount}) {
    created.add((project, command));
    cwds.add(cwd);
    return super.create(project, command, cwd: cwd, githubAccount: githubAccount);
  }
}

class _NoCwdSessions extends MockSessionsRepository {
  @override
  Future<SessionSummary> create(String project, String command, {String? cwd, String? githubAccount}) async =>
      throw const SessionsException(_noCwd, statusCode: 400);
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
    await tester.tap(find.text('2 aguardando você'));
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
    expect(find.text('1 aguardando você'), findsOneWidget);
    expect(find.text('2 aguardando você'), findsNothing);
  });

  testWidgets('an org session stays out of the project list and badges but counts for the org', (tester) async {
    await openSessions(tester, sessions: _OrgActivitySessions());

    expect(find.text('Atividade na org demo'), findsNothing);
    expect(find.text('2 aguardando você'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('org-pending')), matching: find.text('5')), findsOneWidget);
  });

  testWidgets('denying a permission resolves the card and decrements the badge', (tester) async {
    await openSessions(tester);

    await tester.ensureVisible(find.text('Negar'));
    await tester.tap(find.text('Negar'));
    await tester.pumpAndSettle();
    expect(find.text('negado'), findsOneWidget);
    expect(find.text('Permitir'), findsNothing);
    expect(find.text('1 aguardando você'), findsOneWidget);
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
    expect(find.text('1 aguardando você'), findsOneWidget);
  });

  testWidgets('detached session resumes and then accepts a message with cmd+enter', (tester) async {
    await openSessions(tester);
    await tester.tap(find.text('Status do fluxo'));
    await tester.pumpAndSettle();
    expect(find.text('desanexada'), findsOneWidget);

    await tester.tap(find.text('Retomar'));
    await tester.pumpAndSettle();
    expect(find.text('desanexada'), findsNothing);
    expect(find.text('Retomar'), findsNothing);
    expect(find.text('aguardando resposta'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'e agora?');
    await _cmdEnter(tester);
    expect(find.text('e agora?'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
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

  group('command palette', () {
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

      expect(sessions.createCalls.single, ('demo-app', 'resuma o plano', '~/development/demo-app', 'acct-a'));
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
}
