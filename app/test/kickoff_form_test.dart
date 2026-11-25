import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:claude_flow/data/kickoff.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:claude_flow/features/flow/last_cycle_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _demoPath = '~/development/demo-app';
const _engineError = 'engine indisponível';

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

const _kick = SessionSummary(
  id: 's-kick',
  project: 'web-console',
  command: '/kickoff --manual\n\nalgo',
  title: 'kickoff',
  status: SessionStatus.running,
  createdAt: '2026-03-10T10:00:00Z',
);

/// The engine's order: the list shows the new session while `create` is still waiting for its answer.
class _RacingSessions extends MockSessionsRepository {
  final list = StreamController<List<SessionSummary>>();
  final created = Completer<SessionSummary>();

  @override
  Stream<List<SessionSummary>> watchSessions() => list.stream;

  @override
  Stream<SessionDetail> watchSession(String id) => Stream.value(const SessionDetail(summary: _kick));

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
    createCalls.add((project, command, cwd, githubAccount, permissionMode));
    return created.future;
  }
}

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

final _idField = find.byKey(const ValueKey('kickoff-id'));
final _descriptionField = find.byKey(const ValueKey('kickoff-description'));
final _start = find.widgetWithText(FilledButton, 'Iniciar');

final _cycleStart = find.byKey(const ValueKey('cycle-start'));
final _cycleInput = find.byKey(const ValueKey('cycle-start-input'));
final _cycleSubmit = find.byKey(const ValueKey('cycle-start-submit'));
final _cycleMore = find.byKey(const ValueKey('cycle-start-more'));
final _cycleError = find.byKey(const ValueKey('cycle-start-error'));

Finder _form(String project) => find.text('Novo kickoff em $project');

Finder _button(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first;

Finder _segment(String label) =>
    find.descendant(of: find.byType(SegmentedButton<KickoffType>), matching: find.text(label));

Finder _paletteItem(String label) => find.descendant(
  of: find.ancestor(of: find.textContaining('Nova conversa'), matching: find.byType(ListView)).first,
  matching: find.text(label),
);

const _ado = {'kind': 'ado', 'org': 'o', 'project': 'p'};
const _jira = {'kind': 'jira', 'site': 'x.atlassian.net', 'project': 'LC', 'email': 'me@x.com'};

Future<void> _meta(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

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
    Map<String, dynamic>? config,
    Map<String, String>? tracker = _ado,
    bool settle = true,
  }) async {
    final repo = sessions ?? MockSessionsRepository();
    config ??= MockFlowRepository.defaultConfig(MockFlowRepository().data);
    final org = (config['orgs'] as List).first as Map<String, dynamic>;
    if (tracker == null) {
      org.remove('tracker');
    } else {
      org['tracker'] = tracker;
    }
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(
          data: [
            ...MockFlowRepository().data,
            const Project(name: 'loose'),
          ],
          config: config,
        ),
        sessions: repo,
        engine: const MockEngineController(),
      ),
    );
    await tester.pumpAndSettle();
    _router(tester).go(location);
    // A running session's typing indicator never settles.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    return repo;
  }

  Future<void> openFromTopBar(WidgetTester tester) async {
    await tester.tap(_button('Kickoff'));
    await tester.pumpAndSettle();
  }

  group('submit', () {
    testWidgets('the session runs with the gh account of the project org', (tester) async {
      final config = MockFlowRepository.defaultConfig(MockFlowRepository().data);
      (config['orgs'] as List).first['github'] = {
        'account': 'acct-a',
        'owners': ['org-x'],
      };
      final sessions = await pump(tester, '/p/demo-app/flow', config: config);
      await openFromTopBar(tester);

      await tester.enterText(_idField, '123');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, [('demo-app', '/kickoff 123', _demoPath, 'acct-a', PermissionMode.acceptEdits)]);
    });

    testWidgets('a card ID starts the tracker kickoff in the project folder', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_idField, '#123');
      await tester.pump();
      expect(tester.widget<TextField>(_descriptionField).enabled, isFalse);
      expect(find.text('ignorado com ID'), findsWidgets);

      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, [('demo-app', '/kickoff 123', _demoPath, null, PermissionMode.acceptEdits)]);
      expect(_location(tester), '/p/demo-app/sessions/mock-1');
      expect(_form('demo-app'), findsNothing);
    });

    testWidgets('enter in the ID field submits the normalized key', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow', tracker: _jira);
      await openFromTopBar(tester);

      await tester.enterText(_idField, 'lc-101');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, [('demo-app', '/kickoff LC-101', _demoPath, null, PermissionMode.acceptEdits)]);
    });

    testWidgets('a Jira number gets the project key and the field names the tracker', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow', tracker: _jira);
      await openFromTopBar(tester);

      expect(find.text('ID do card no Jira'), findsOneWidget);
      expect(find.text('opcional · LC-101'), findsOneWidget);
      await tester.enterText(_idField, '77');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$2, '/kickoff LC-77');
    });

    testWidgets('an org without tracker only offers the manual kickoff', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow', tracker: null);
      await openFromTopBar(tester);

      expect(_idField, findsNothing);
      expect(find.byKey(const ValueKey('kickoff-no-tracker')), findsOneWidget);
      await tester.enterText(_descriptionField, 'algo');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$2, '/kickoff --manual\n\nalgo');
    });

    testWidgets('manual bug sends the description verbatim and opens the session', (tester) async {
      const description = 'linha 1 com "aspas"\nlinha 2 com \\ barra e `crase`\nlinha 3 com \$(date)';
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_descriptionField, description);
      await tester.tap(_segment('Bug'));
      await tester.pump();
      await tester.tap(_start);
      await tester.pumpAndSettle();

      expect(sessions.createCalls, hasLength(1));
      final (project, command, cwd, _, _) = sessions.createCalls.single;
      expect(project, 'demo-app');
      expect(cwd, _demoPath);
      expect(command.codeUnits, '/kickoff --manual --bug\n\n$description'.codeUnits);
      expect(_location(tester), '/p/demo-app/sessions/mock-1');
    });

    testWidgets('automatic type sends no type flag', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_descriptionField, 'algo');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$2, '/kickoff --manual\n\nalgo');
    });

    testWidgets('engine error stays inline and keeps the form open', (tester) async {
      await pump(tester, '/p/demo-app/flow', sessions: _FailingSessions());
      await openFromTopBar(tester);

      await tester.enterText(_idField, '123');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(find.text(_engineError), findsOneWidget);
      expect(_form('demo-app'), findsOneWidget);
    });
  });

  group('permission mode', () {
    final kickoffMode = find.byKey(const ValueKey('kickoff-permission-mode'));
    final paletteMode = find.byKey(const ValueKey('palette-permission-mode'));

    Map<String, dynamic> orgMode(String mode) {
      final config = MockFlowRepository.defaultConfig(MockFlowRepository().data);
      config['permissionMode'] = 'bypassPermissions';
      (config['orgs'] as List).first['permissionMode'] = mode;
      return config;
    }

    Future<void> choose(WidgetTester tester, Finder menu, String label) async {
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      if (label == 'bypass') {
        expect(find.text('Usar bypass?'), findsOneWidget);
        await tester.tap(find.text('Usar bypass'));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('the form shows the org mode and a change applies to this session only', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow', config: orgMode('acceptEdits'));
      await openFromTopBar(tester);
      expect(find.descendant(of: kickoffMode, matching: find.text('aceitar edições')), findsOneWidget);

      await choose(tester, kickoffMode, 'padrão');
      expect(find.descendant(of: kickoffMode, matching: find.text('padrão')), findsOneWidget);
      await tester.enterText(_idField, '123');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, [('demo-app', '/kickoff 123', _demoPath, null, PermissionMode.defaultMode)]);

      _router(tester).go('/p/demo-app/flow');
      await tester.pumpAndSettle();
      await openFromTopBar(tester);
      expect(find.descendant(of: kickoffMode, matching: find.text('aceitar edições')), findsOneWidget);
    });

    testWidgets('without an org mode the form sends the global one', (tester) async {
      final config = MockFlowRepository.defaultConfig(MockFlowRepository().data);
      config['permissionMode'] = 'auto';
      final sessions = await pump(tester, '/p/demo-app/flow', config: config);
      await openFromTopBar(tester);
      expect(find.descendant(of: kickoffMode, matching: find.text('auto (classificador)')), findsOneWidget);

      await tester.enterText(_idField, '123');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls.single.$5, PermissionMode.auto);
    });

    testWidgets('the palette shows the effective mode and sends the one chosen for the session', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow', config: orgMode('acceptEdits'));
      await _meta(tester, LogicalKeyboardKey.keyK);
      expect(find.descendant(of: paletteMode, matching: find.text('aceitar edições')), findsOneWidget);

      await choose(tester, paletteMode, 'bypass');
      await tester.tap(_paletteItem('Nova conversa em demo-app'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'resuma');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, [('demo-app', 'resuma', _demoPath, null, PermissionMode.bypassPermissions)]);
    });

    testWidgets('the palette on a project without a folder shows the error and creates nothing', (tester) async {
      final sessions = await pump(tester, '/p/loose/flow');
      await _meta(tester, LogicalKeyboardKey.keyK);
      await tester.tap(_paletteItem('Nova conversa em loose'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'algo');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('sem pasta para loose: adicione a pasta em Configurações'), findsOneWidget);
      expect(sessions.createCalls, isEmpty);
    });
  });

  group('nothing is created', () {
    testWidgets('empty description without ID', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(find.text('descreva o card ou informe um ID'), findsOneWidget);
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('invalid ID', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_idField, 'LC-101');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(find.text('não é um ID do Azure DevOps'), findsOneWidget);
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('description over the limit', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_descriptionField, 'a' * (kKickoffMaxChars + 1));
      await tester.pump();
      expect(find.text('20001/20000'), findsOneWidget);
      expect(find.text('descrição acima de 20000 caracteres'), findsOneWidget);

      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, isEmpty);
      expect(_form('demo-app'), findsOneWidget);
    });

    testWidgets('enter in the description, while cmd+enter creates', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_descriptionField, 'algo');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, isEmpty);
      expect(_form('demo-app'), findsOneWidget);

      await _meta(tester, LogicalKeyboardKey.enter);
      expect(sessions.createCalls, [
        ('demo-app', '/kickoff --manual\n\nalgo', _demoPath, null, PermissionMode.acceptEdits),
      ]);
    });

    testWidgets('project without a folder shows the same error as the palette', (tester) async {
      final sessions = await pump(tester, '/p/loose/flow');
      await openFromTopBar(tester);

      await tester.enterText(_descriptionField, 'algo');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(find.text('sem pasta para loose: adicione a pasta em Configurações'), findsOneWidget);
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('escape closes and discards', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_descriptionField, 'algo');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_form('demo-app'), findsNothing);
      expect(sessions.createCalls, isEmpty);
    });
  });

  group('in flight', () {
    testWidgets('escape and the barrier do not close the form while creating', (tester) async {
      final sessions = _SlowSessions();
      await pump(tester, '/p/demo-app/flow', sessions: sessions);
      await openFromTopBar(tester);

      await tester.enterText(_idField, '7');
      await tester.tap(_start);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      expect(_form('demo-app'), findsOneWidget);

      sessions.gate.complete();
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/demo-app/sessions/mock-1');
    });
  });

  group('entries', () {
    testWidgets('flow empty state opens the form', (tester) async {
      await pump(tester, '/p/web-console/flow');
      await tester.tap(_cycleMore);
      await tester.pumpAndSettle();
      expect(_form('web-console'), findsOneWidget);
      expect(tester.widget<TextField>(_descriptionField).controller!.text, isEmpty);
    });

    testWidgets('top bar opens the form on a project with a cycle', (tester) async {
      await pump(tester, '/p/demo-app/flow');
      expect(find.text('Favoritos offline'), findsWidgets);
      await openFromTopBar(tester);
      expect(_form('demo-app'), findsOneWidget);
    });

    testWidgets('palette keeps "Novo kickoff" under any filter and opens the form', (tester) async {
      await pump(tester, '/p/demo-app/flow');
      await _meta(tester, LogicalKeyboardKey.keyK);
      await tester.enterText(find.byType(TextField).last, 'xyz');
      await tester.pump();

      await tester.tap(_paletteItem('Novo kickoff'));
      await tester.pumpAndSettle();
      expect(find.text('Nova conversa em demo-app'), findsNothing);
      expect(_form('demo-app'), findsOneWidget);
    });

    testWidgets('the kickoff skill is listed once, as Novo kickoff, and opens the form', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await _meta(tester, LogicalKeyboardKey.keyK);
      await tester.enterText(find.byType(TextField).last, 'kick');
      await tester.pump();
      expect(_paletteItem('/kickoff'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('argumentos (opcional)'), findsNothing);
      expect(_form('demo-app'), findsOneWidget);
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('without a project every entry is disabled', (tester) async {
      await pump(tester, '/p/nope/flow');

      expect(tester.widget<ButtonStyleButton>(_button('Kickoff')).enabled, isFalse);
      expect(tester.widget<ButtonStyleButton>(_cycleSubmit).enabled, isFalse);
      expect(tester.widget<ButtonStyleButton>(_cycleMore).enabled, isFalse);

      await _meta(tester, LogicalKeyboardKey.keyK);
      await tester.tap(_paletteItem('Novo kickoff'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('ID do card'), findsNothing);
    });
  });

  group('cycle-start', () {
    const webPath = '~/development/web-console';
    const support = 'Não precisa estar completo: o que faltar vira pergunta.';

    bool enabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(_cycleSubmit).enabled;

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(_cycleInput, text);
      await tester.pump();
    }

    testWidgets('a project without a cycle asks what to do, with the last cycle line below', (tester) async {
      await pump(tester, '/p/web-console/flow');

      expect(
        find.descendant(of: _cycleStart, matching: find.text('O que você quer fazer em web-console?')),
        findsOneWidget,
      );
      expect(find.text('Descreva com suas palavras ou cole o número de um card. $support'), findsOneWidget);
      expect(find.textContaining('Você é chamado para confirmar o que vai ser entregue'), findsOneWidget);
      expect(find.descendant(of: _cycleSubmit, matching: find.text('⌘↵')), findsOneWidget);
      expect(find.descendant(of: _cycleStart, matching: find.byType(LastCycleLine)), findsOneWidget);
      expect(find.textContaining('Nenhum ciclo ativo'), findsNothing);
      expect(find.text('Novo kickoff'), findsNothing);
      expect(tester.getSize(_cycleStart).width, 640);
      final input = tester.widget<TextField>(_cycleInput);
      expect((input.minLines, input.maxLines), (4, 8));
      final editable = find.descendant(of: _cycleInput, matching: find.byType(EditableText));
      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    });

    testWidgets('an org without tracker does not offer the card number', (tester) async {
      await pump(tester, '/p/web-console/flow', tracker: null);

      expect(find.text('Descreva com suas palavras. $support'), findsOneWidget);
    });

    testWidgets('the button is off for empty, blank and too long text, and without a project', (tester) async {
      await pump(tester, '/p/web-console/flow');
      expect(enabled(tester), isFalse);

      await type(tester, '  \n ');
      expect(enabled(tester), isFalse);

      await type(tester, 'a' * 18000);
      expect(enabled(tester), isTrue);
      expect(find.text('18000/$kKickoffMaxChars'), findsNothing);

      await type(tester, 'a' * 18001);
      expect(find.text('18001/$kKickoffMaxChars'), findsOneWidget);

      await type(tester, 'a' * (kKickoffMaxChars + 1));
      expect(enabled(tester), isFalse);

      await type(tester, 'algo');
      expect(enabled(tester), isTrue);

      _router(tester).go('/p/nope/flow');
      await tester.pumpAndSettle();
      expect(find.text('O que você quer fazer em nope?'), findsOneWidget);
      await type(tester, 'algo');
      expect(enabled(tester), isFalse);
    });

    testWidgets('a tap creates the session with the org account and mode, and opens it', (tester) async {
      final config = MockFlowRepository.defaultConfig(MockFlowRepository().data);
      final org = (config['orgs'] as List).first as Map<String, dynamic>;
      org['github'] = {
        'account': 'acct-a',
        'owners': ['org-x'],
      };
      org['permissionMode'] = 'auto';
      final sessions = await pump(tester, '/p/web-console/flow', config: config);

      await type(tester, '  trocar o tema do console  ');
      await tester.tap(_cycleSubmit);
      await tester.pumpAndSettle();

      final command = startCommand('  trocar o tema do console  ', OrgTracker.fromRaw(_ado));
      expect(command, '/kickoff --manual\n\ntrocar o tema do console');
      expect(sessions.createCalls, [('web-console', command, webPath, 'acct-a', PermissionMode.auto)]);
      expect(_location(tester), '/p/web-console/sessions/mock-1');
    });

    testWidgets('cmd+enter sends a card number by the tracker, while enter alone only breaks the line', (tester) async {
      final sessions = await pump(tester, '/p/web-console/flow');

      await type(tester, '#4821');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, isEmpty);

      await _meta(tester, LogicalKeyboardKey.enter);
      expect(sessions.createCalls, [('web-console', '/kickoff 4821', webPath, null, PermissionMode.acceptEdits)]);
      expect(_location(tester), '/p/web-console/sessions/mock-1');
    });

    testWidgets('cmd+enter of the numeric keypad sends', (tester) async {
      final sessions = await pump(tester, '/p/web-console/flow', tracker: null);

      await type(tester, '4821');
      await _meta(tester, LogicalKeyboardKey.numpadEnter);
      expect(sessions.createCalls.single.$2, '/kickoff --manual\n\n4821');
    });

    testWidgets('project without a folder shows the error and creates nothing', (tester) async {
      final sessions = await pump(tester, '/p/loose/flow');

      await type(tester, 'algo');
      await tester.tap(_cycleSubmit);
      await tester.pumpAndSettle();
      expect(find.descendant(of: _cycleStart, matching: _cycleError), findsOneWidget);
      expect(tester.widget<Text>(_cycleError).data, 'sem pasta para loose: adicione a pasta em Configurações');
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('a failed create shows the message and keeps the text', (tester) async {
      await pump(tester, '/p/web-console/flow', sessions: _FailingSessions());

      await type(tester, 'algo que falha');
      await tester.tap(_cycleSubmit);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_cycleError).data, contains(_engineError));
      expect(tester.widget<TextField>(_cycleInput).controller!.text, 'algo que falha');
      expect(enabled(tester), isTrue);
      expect(_location(tester), '/p/web-console/flow');
    });

    testWidgets('a kickoff running without a cycle takes the place of the box', (tester) async {
      final sessions = _RacingSessions()..list.add(const [_kick]);
      addTearDown(sessions.list.close);
      await pump(tester, '/p/web-console/flow', sessions: sessions, settle: false);

      expect(find.byKey(const ValueKey('flow-kickoff-running')), findsOneWidget);
      expect(_cycleStart, findsNothing);
    });

    testWidgets('the session opens even when its kickoff replaces the box before create answers', (tester) async {
      final sessions = _RacingSessions()..list.add(const []);
      addTearDown(sessions.list.close);
      await pump(tester, '/p/web-console/flow', sessions: sessions);

      await type(tester, 'algo');
      await tester.tap(_cycleSubmit);
      await tester.pump();
      expect(sessions.createCalls, hasLength(1));
      expect(enabled(tester), isFalse);

      sessions.list.add(const [_kick]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('flow-kickoff-running')), findsOneWidget);
      expect(_cycleStart, findsNothing);
      expect(_location(tester), '/p/web-console/flow');

      sessions.created.complete(_kick);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_location(tester), '/p/web-console/sessions/s-kick');
      expect(tester.takeException(), isNull);
    });

    testWidgets('leaving for another route before create answers keeps that route', (tester) async {
      final sessions = _RacingSessions()..list.add(const []);
      addTearDown(sessions.list.close);
      await pump(tester, '/p/web-console/flow', sessions: sessions);

      await type(tester, 'algo');
      await tester.tap(_cycleSubmit);
      await tester.pump();
      expect(sessions.createCalls, hasLength(1));

      _router(tester).go('/settings');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_location(tester), '/settings');

      sessions.created.complete(_kick);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_location(tester), '/settings');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a project with an active cycle warns that the kickoff will ask about resetting it', (tester) async {
    await pump(tester, '/p/demo-app/flow');
    await openFromTopBar(tester);
    expect(find.byKey(const ValueKey('kickoff-active-cycle')), findsOneWidget);
    expect(find.textContaining('«Favoritos offline» em implement'), findsOneWidget);
  });
}
