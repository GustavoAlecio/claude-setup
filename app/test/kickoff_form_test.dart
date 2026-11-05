import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/kickoff.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/sessions_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _demoPath = '~/development/demo-app';
const _engineError = 'engine indisponível';

class _FailingSessions extends MockSessionsRepository {
  @override
  Future<SessionSummary> create(String project, String command, {String? cwd, String? githubAccount}) async =>
      throw const SessionsException(_engineError, statusCode: 500);
}

class _SlowSessions extends MockSessionsRepository {
  final gate = Completer<void>();

  @override
  Future<SessionSummary> create(String project, String command, {String? cwd, String? githubAccount}) async {
    await gate.future;
    return super.create(project, command, cwd: cwd, githubAccount: githubAccount);
  }
}

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

final _idField = find.byKey(const ValueKey('kickoff-id'));
final _descriptionField = find.byKey(const ValueKey('kickoff-description'));
final _start = find.widgetWithText(FilledButton, 'Iniciar');

Finder _form(String project) => find.text('Novo kickoff em $project');

Finder _button(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first;

Finder _segment(String label) =>
    find.descendant(of: find.byType(SegmentedButton<KickoffType>), matching: find.text(label));

Finder _paletteItem(String label) => find.descendant(
  of: find.ancestor(of: find.textContaining('Nova conversa'), matching: find.byType(ListView)).first,
  matching: find.text(label),
);

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
  }) async {
    final repo = sessions ?? MockSessionsRepository();
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
    await tester.pumpAndSettle();
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
      expect(sessions.createCalls, [('demo-app', '/kickoff 123', _demoPath, 'acct-a')]);
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
      expect(sessions.createCalls, [('demo-app', '/kickoff 123', _demoPath, null)]);
      expect(_location(tester), '/p/demo-app/sessions/mock-1');
      expect(_form('demo-app'), findsNothing);
    });

    testWidgets('enter in the ID field submits the normalized key', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await openFromTopBar(tester);

      await tester.enterText(_idField, 'lc-101');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sessions.createCalls, [('demo-app', '/kickoff LC-101', _demoPath, null)]);
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
      final (project, command, cwd, _) = sessions.createCalls.single;
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

      await tester.enterText(_idField, 'abc');
      await tester.tap(_start);
      await tester.pumpAndSettle();
      expect(find.text('ID inválido'), findsOneWidget);
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
      expect(sessions.createCalls, [('demo-app', '/kickoff --manual\n\nalgo', _demoPath, null)]);
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
      await tester.tap(_button('Novo kickoff'));
      await tester.pumpAndSettle();
      expect(_form('web-console'), findsOneWidget);
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

    testWidgets('choosing the kickoff skill in the palette opens the form', (tester) async {
      final sessions = await pump(tester, '/p/demo-app/flow');
      await _meta(tester, LogicalKeyboardKey.keyK);
      await tester.enterText(find.byType(TextField).last, 'kick');
      await tester.pump();
      expect(_paletteItem('/kickoff'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('argumentos (opcional)'), findsNothing);
      expect(_form('demo-app'), findsOneWidget);
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('without a project every entry is disabled', (tester) async {
      await pump(tester, '/p/nope/flow');

      expect(tester.widget<ButtonStyleButton>(_button('Kickoff')).enabled, isFalse);
      expect(tester.widget<ButtonStyleButton>(_button('Novo kickoff')).enabled, isFalse);

      await _meta(tester, LogicalKeyboardKey.keyK);
      await tester.tap(_paletteItem('Novo kickoff'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('ID do card'), findsNothing);
    });
  });
}
