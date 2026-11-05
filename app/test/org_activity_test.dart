import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _data = [
  Project(name: 'alpha', path: '/dev/a/alpha'),
  Project(name: 'gamma', path: '/dev/c/gamma'),
  Project(name: 'loose'),
];

Map<String, dynamic> _config({String? lastOrg = 'A'}) => {
  'engineDir': '/engine',
  'orgs': [
    {
      'name': 'A',
      'roots': ['/dev/a', '/dev/a2'],
    },
    {
      'name': 'B',
      'roots': ['/dev/b'],
    },
    {'name': 'C', 'roots': <String>[]},
  ],
  'projects': [
    {'name': 'gamma', 'path': '/dev/c/gamma', 'org': 'C'},
  ],
  'lastOrg': ?lastOrg,
};

SessionSummary _project(String id, String project, int pending) => SessionSummary(
  id: id,
  project: project,
  command: '/fix $project',
  title: 'Sessão $project',
  status: SessionStatus.waitingPermission,
  createdAt: '2026-03-10T14:41:00Z',
  pendingPermissions: pending,
);

SessionSummary _activity(
  String id,
  String org,
  String cwd, {
  List<String> additional = const [],
  int pending = 0,
  SessionStatus status = SessionStatus.idle,
}) => SessionSummary(
  id: id,
  project: '',
  command: 'analise $id',
  title: 'Atividade $id',
  status: status,
  createdAt: '2026-03-10T14:41:00Z',
  pendingPermissions: pending,
  org: org,
  cwd: cwd,
  additionalDirectories: additional,
);

final _fixed = [
  _project('s-alpha', 'alpha', 1),
  _activity('a1', 'A', '/dev/a', additional: ['/dev/a2'], pending: 2, status: SessionStatus.waitingPermission),
  _activity('a2', 'A', '/dev/a'),
  _activity('a3', 'A', '/dev/a', status: SessionStatus.done),
  _activity('b1', 'B', '/dev/b'),
];

class _Sessions extends MockSessionsRepository {
  /// Makes `createInOrg` fail, as the engine does for an invalid directory.
  Exception? orgError;

  @override
  Future<SessionSummary> createInOrg(
    String org,
    String command, {
    required String cwd,
    List<String> additionalDirectories = const [],
    String? githubAccount,
    required PermissionMode permissionMode,
  }) async {
    if (orgError case final error?) throw error;
    return super.createInOrg(
      org,
      command,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
      githubAccount: githubAccount,
      permissionMode: permissionMode,
    );
  }

  List<SessionSummary> list = _fixed;

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.value(list);

  @override
  Stream<SessionDetail> watchSession(String id) {
    final fixed = list.where((s) => s.id == id).firstOrNull;
    return fixed == null ? super.watchSession(id) : Stream.value(SessionDetail(summary: fixed));
  }
}

final _activityEntry = find.byKey(const ValueKey('org-activity'));

String _org(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('current-org'))).data!;

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

Future<void> _go(WidgetTester tester, String location) async {
  _router(tester).go(location);
  await tester.pumpAndSettle();
}

Future<void> _meta(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

Future<void> _metaShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

final _orgPalette = find.text('Atividade em A…', findRichText: true);

Finder _inEntry(String text) => find.descendant(of: _activityEntry, matching: find.text(text));

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  late _Sessions sessions;

  Future<MockFlowRepository> pump(WidgetTester tester, {Map<String, dynamic>? config}) async {
    final repo = MockFlowRepository(data: _data, config: config ?? _config());
    sessions = _Sessions();
    await tester.pumpWidget(ClaudeFlowApp(repository: repo, sessions: sessions, engine: const MockEngineController()));
    await tester.pumpAndSettle();
    return repo;
  }

  group('sidebar', () {
    testWidgets('counts every org session of the org and badges its pending ones', (tester) async {
      await pump(tester);

      expect(_location(tester), '/p/alpha/flow');
      expect(_inEntry('Atividades da org'), findsOneWidget);
      expect(_inEntry('3'), findsOneWidget, reason: 'a1, a2 and a3; b1 belongs to B, s-alpha to a project');
      expect(_inEntry('2'), findsOneWidget, reason: 'only a1 is pending');
      expect(
        find.descendant(of: find.byKey(const ValueKey('org-pending')), matching: find.text('3')),
        findsOneWidget,
        reason: 'the org header adds the project session',
      );

      await tester.tap(_activityEntry);
      await tester.pumpAndSettle();
      expect(_location(tester), '/o/A/sessions');
    });

    testWidgets('absent in Sem org', (tester) async {
      await pump(tester);

      await _go(tester, '/p/loose/flow');

      expect(_org(tester), kNoOrg);
      expect(_activityEntry, findsNothing);
    });

    testWidgets('removing the org keeps its pending activity reachable in Sem org, read-only', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      sessions = _Sessions()
        ..list = [..._fixed, _activity('o1', 'B', '/dev/b', pending: 1, status: SessionStatus.waitingPermission)];
      await tester.pumpWidget(
        ClaudeFlowApp(repository: repo, sessions: sessions, engine: const MockEngineController()),
      );
      await tester.pumpAndSettle();
      await repo.updateConfig(removeOrg('B'));
      await tester.pumpAndSettle();

      await _go(tester, '/p/loose/flow');

      expect(_org(tester), kNoOrg);
      expect(
        find.descendant(of: find.byKey(const ValueKey('org-pending')), matching: find.text('1')),
        findsOneWidget,
        reason: 'the pending permission of the removed org stays in the Sem org badge',
      );
      expect(_inEntry('2'), findsOneWidget, reason: 'b1 and o1 are orphans now');

      await tester.tap(_activityEntry);
      await tester.pumpAndSettle();

      expect(_location(tester), '/o/Sem%20org/sessions');
      expect(find.text('Atividades em $kNoOrg'), findsOneWidget);
      expect(find.text('Nova atividade  ⌘K'), findsNothing);
      expect(find.text('Nova atividade'), findsNothing);
      expect(find.text('Atividade o1'), findsOneWidget);

      await tester.tap(find.text('Atividade b1'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/o/Sem%20org/sessions/b1');
    });

    testWidgets('an org without roots shows it disabled with a tooltip', (tester) async {
      await pump(tester);
      await _go(tester, '/p/gamma/flow');
      expect(_org(tester), 'C');

      expect(find.byTooltip('org sem pastas'), findsOneWidget);
      await tester.tap(_activityEntry);
      await tester.pumpAndSettle();

      expect(_location(tester), '/p/gamma/flow');
    });
  });

  group('/o/ routes', () {
    testWidgets('list only the org sessions with the org meta and a header without project actions', (tester) async {
      final repo = await pump(tester);

      await _go(tester, '/o/A/sessions');

      expect(_org(tester), 'A');
      expect(find.text('Atividades em A'), findsOneWidget);
      expect(find.text('Nova atividade  ⌘K'), findsOneWidget);
      expect(find.text('2 aguardando você'), findsOneWidget);
      expect(find.text('Kickoff'), findsNothing);
      expect(find.text('Fluxo'), findsNothing, reason: 'only the Sessões tab');
      expect(find.text('Atividade a1'), findsOneWidget);
      expect(find.text('Atividade a2'), findsOneWidget);
      expect(find.text('Atividade a3'), findsOneWidget);
      expect(find.text('Atividade b1'), findsNothing);
      expect(find.text('Sessão alpha'), findsNothing);
      expect(find.textContaining('· A ·'), findsNWidgets(3));
      expect(repo.config.lastOrg, 'A');
    });

    testWidgets('auto-selects the pending session and its detail shows cwd and the additional roots', (tester) async {
      await pump(tester);

      await _go(tester, '/o/A/sessions');

      expect(find.byKey(const ValueKey('session-directories')), findsOneWidget);
      expect(find.text('/dev/a'), findsOneWidget);
      expect(find.text('/dev/a2'), findsOneWidget);
    });

    testWidgets('a tile opens /o/<org>/sessions/<id>', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');

      await tester.tap(find.text('Atividade a2'));
      await tester.pumpAndSettle();

      expect(_location(tester), '/o/A/sessions/a2');
      expect(find.text('/dev/a'), findsOneWidget);
      expect(find.text('/dev/a2'), findsNothing);
    });

    testWidgets('an id of another org falls back to the auto-select', (tester) async {
      await pump(tester);

      await _go(tester, '/o/A/sessions/b1');

      expect(find.text('/dev/a2'), findsOneWidget, reason: 'a1 is the pending one');
      expect(find.text('/dev/b'), findsNothing);
    });

    testWidgets('the project list leaves org sessions out', (tester) async {
      await pump(tester);

      await _go(tester, '/p/alpha/sessions');

      expect(find.text('Sessão alpha'), findsWidgets);
      expect(find.text('Atividade a1'), findsNothing);
      expect(find.byKey(const ValueKey('session-directories')), findsNothing);
    });

    testWidgets('an org missing from the config has no Nova atividade and never writes lastOrg', (tester) async {
      final repo = await pump(tester);

      await _go(tester, '/o/Z/sessions');

      expect(find.text('Atividades em Z'), findsOneWidget);
      expect(find.text('Nova atividade  ⌘K'), findsNothing);
      expect(find.text('Atividade a1'), findsNothing);
      expect(repo.config.lastOrg, 'A');
    });

    testWidgets('a route into another org writes lastOrg', (tester) async {
      final repo = await pump(tester);

      await _go(tester, '/o/B/sessions');

      expect(_org(tester), 'B');
      expect(repo.config.lastOrg, 'B');
      expect(find.text('Atividade b1'), findsOneWidget);
    });

    testWidgets('an org name with spaces and accents is encoded in the route', (tester) async {
      await pump(
        tester,
        config: {
          'orgs': [
            {
              'name': 'ABM Soluções',
              'roots': ['/dev/abm'],
            },
          ],
          'lastOrg': 'ABM Soluções',
        },
      );

      expect(_location(tester), '/o/ABM%20Solu%C3%A7%C3%B5es/sessions');
      expect(find.text('Atividades em ABM Soluções'), findsOneWidget);
      expect(_org(tester), 'ABM Soluções');
    });
  });

  group('switching org', () {
    Future<void> expectB(WidgetTester tester, MockFlowRepository repo) async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(_location(tester), '/o/B/sessions');
      expect(repo.config.lastOrg, 'B');
      expect(_org(tester), 'B');
    }

    testWidgets('⌘2 from a project route opens the activities of B, which has roots but no project', (tester) async {
      final repo = await pump(tester);

      await _meta(tester, LogicalKeyboardKey.digit2);

      await expectB(tester, repo);
    });

    testWidgets('⌘2 from /o/A/sessions goes to B', (tester) async {
      final repo = await pump(tester);
      await _go(tester, '/o/A/sessions');

      await _meta(tester, LogicalKeyboardKey.digit2);

      await expectB(tester, repo);
    });

    testWidgets('choosing B on the landing opens its activities', (tester) async {
      final repo = await pump(tester, config: _config(lastOrg: null));
      expect(_location(tester), '/');

      await tester.tap(find.widgetWithText(OutlinedButton, 'B'));
      await tester.pumpAndSettle();

      await expectB(tester, repo);
    });

    testWidgets('boot with lastOrg=B opens its activities', (tester) async {
      final repo = await pump(tester, config: _config(lastOrg: 'B'));

      await expectB(tester, repo);
    });

    testWidgets('⌘1 from /o/B/sessions opens the first project of A', (tester) async {
      final repo = await pump(tester, config: _config(lastOrg: 'B'));

      await _meta(tester, LogicalKeyboardKey.digit1);

      expect(_location(tester), '/p/alpha/flow');
      expect(repo.config.lastOrg, 'A');
    });

    testWidgets('Configurações → Voltar returns to /o/A/sessions', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');

      await _meta(tester, LogicalKeyboardKey.comma);
      expect(_location(tester), '/settings');
      await tester.tap(find.text('Voltar'));
      await tester.pumpAndSettle();

      expect(_location(tester), '/o/A/sessions');
    });
  });

  group('palette em modo org', () {
    String hint(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField).last).decoration!.hintText!;

    final palette = find.byWidgetPredicate((w) => w is Container && w.constraints?.maxWidth == 560);
    Finder inPalette(String text) => find.descendant(of: palette, matching: find.text(text));

    void expectOrgCall(String command) {
      final (org, cmd, cwd, additional, _, _) = sessions.orgCreateCalls.single;
      expect((org, cmd, cwd), ('A', command, '/dev/a'));
      expect(additional, ['/dev/a2']);
    }

    void expectOrgList(WidgetTester tester) {
      expect(hint(tester), 'Atividade em A…');
      expect(inPalette('/fix'), findsNothing);
      expect(inPalette('/status'), findsNothing);
      expect(inPalette('/kickoff'), findsNothing);
      expect(inPalette('/review'), findsOneWidget);
      expect(inPalette('Novo kickoff'), findsNothing);
      expect(inPalette('Nova conversa em A'), findsOneWidget);
    }

    Future<void> startAndSend(WidgetTester tester) async {
      await tester.tap(find.text('Nova conversa em A'));
      await tester.pumpAndSettle();
      expect(hint(tester), 'Nova conversa em A: escreva o prompt');
      await tester.enterText(find.byType(TextField).last, 'liste as pastas');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    testWidgets('⌘⇧K in a project route lists no pipeline skills and creates the activity in the org', (tester) async {
      await pump(tester);
      await _go(tester, '/p/alpha/flow');

      await _metaShift(tester, LogicalKeyboardKey.keyK);
      expectOrgList(tester);
      await startAndSend(tester);

      expectOrgCall('liste as pastas');
      expect(sessions.createCalls, isEmpty);
      expect(_location(tester), '/o/A/sessions/mock-1');
      expect(_orgPalette, findsNothing);
    });

    testWidgets('the activity runs with the gh account of the org', (tester) async {
      final config = _config();
      (config['orgs'] as List).first['github'] = {
        'account': 'acct-a',
        'owners': ['org-x'],
      };
      await pump(tester, config: config);
      await _go(tester, '/o/A/sessions');

      await _metaShift(tester, LogicalKeyboardKey.keyK);
      await startAndSend(tester);

      expectOrgCall('liste as pastas');
      expect(sessions.orgCreateCalls.single.$5, 'acct-a');
    });

    testWidgets('an org without github keeps the active account', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');

      await _metaShift(tester, LogicalKeyboardKey.keyK);
      await startAndSend(tester);

      expect(sessions.orgCreateCalls.single.$5, isNull);
    });

    testWidgets('the activity shows and runs with the org permission mode', (tester) async {
      final config = _config();
      config['permissionMode'] = 'default';
      (config['orgs'] as List).first['permissionMode'] = 'acceptEdits';
      await pump(tester, config: config);
      await _go(tester, '/o/A/sessions');

      await _metaShift(tester, LogicalKeyboardKey.keyK);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('palette-permission-mode')),
          matching: find.text('aceitar edições'),
        ),
        findsOneWidget,
      );
      await startAndSend(tester);

      expectOrgCall('liste as pastas');
      expect(sessions.orgCreateCalls.single.$6, PermissionMode.acceptEdits);
    });

    testWidgets('an org without a mode runs the activity with the global one', (tester) async {
      final config = _config();
      config['permissionMode'] = 'default';
      await pump(tester, config: config);
      await _go(tester, '/o/A/sessions');

      await _metaShift(tester, LogicalKeyboardKey.keyK);
      await startAndSend(tester);

      expect(sessions.orgCreateCalls.single.$6, PermissionMode.defaultMode);
    });

    testWidgets('⌘⇧K on / opens the org of lastOrg', (tester) async {
      await pump(tester);
      await _go(tester, '/');

      await _metaShift(tester, LogicalKeyboardKey.keyK);

      expectOrgList(tester);
    });

    testWidgets('a skill from the org list asks for arguments and runs in the org', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');
      await _metaShift(tester, LogicalKeyboardKey.keyK);

      await tester.tap(find.text('/review'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '12');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expectOrgCall('/review 12');
      expect(_location(tester), '/o/A/sessions/mock-1');
    });

    testWidgets('⌘K in the org activities opens the org palette', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');

      await _meta(tester, LogicalKeyboardKey.keyK);

      expectOrgList(tester);
    });

    testWidgets('the Nova atividade button of the org header opens the org palette', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');

      await tester.tap(find.text('Nova atividade  ⌘K'));
      await tester.pumpAndSettle();

      expectOrgList(tester);
    });

    testWidgets('⌘⇧K does nothing in settings and about', (tester) async {
      await pump(tester);
      for (final location in ['/settings', '/about']) {
        await _go(tester, location);
        await _metaShift(tester, LogicalKeyboardKey.keyK);
        expect(find.byType(TextField).evaluate().where((e) => (e.widget as TextField).autofocus), isEmpty);
        expect(find.text('Nova conversa em A'), findsNothing);
      }
    });

    testWidgets('⌘⇧K does nothing in Sem org and in an org without roots', (tester) async {
      await pump(tester);
      await _go(tester, '/p/loose/flow');
      await _metaShift(tester, LogicalKeyboardKey.keyK);
      expect(find.textContaining('Atividade em'), findsNothing);

      await _go(tester, '/p/gamma/flow');
      await _metaShift(tester, LogicalKeyboardKey.keyK);
      expect(find.textContaining('Atividade em'), findsNothing);
    });

    testWidgets('in /p/<unknown>/flow the menu item and ⌘⇧K agree', (tester) async {
      await pump(tester);
      await _go(tester, '/p/ghost/flow');

      await tester.tap(find.byKey(const ValueKey('current-org')));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Nova atividade na org'),
      );
      await tester.tap(find.text('Nova atividade na org'));
      await tester.pumpAndSettle();
      final viaMenu = find.byType(TextField).evaluate().isNotEmpty ? hint(tester) : null;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await _metaShift(tester, LogicalKeyboardKey.keyK);
      final viaShortcut = find.byType(TextField).evaluate().isNotEmpty ? hint(tester) : null;

      expect(item.enabled, isTrue, reason: 'the shell shows lastOrg, A, which has roots');
      expect(viaMenu, 'Atividade em A…');
      expect(viaShortcut, viaMenu);
    });

    testWidgets('⌘⇧K does nothing with the palette already open', (tester) async {
      await pump(tester);
      await _go(tester, '/p/alpha/flow');
      await _meta(tester, LogicalKeyboardKey.keyK);
      expect(find.byType(TextField), findsOneWidget);
      expect(hint(tester), 'Executar skill em alpha…');

      await _metaShift(tester, LogicalKeyboardKey.keyK);

      expect(find.textContaining('Atividade em'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(hint(tester), 'Executar skill em alpha…');
    });

    testWidgets('the org menu item opens the org palette', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');

      await tester.tap(find.byKey(const ValueKey('current-org')));
      await tester.pumpAndSettle();
      expect(find.text('⌘⇧K'), findsOneWidget);
      await tester.tap(find.text('Nova atividade na org'));
      await tester.pumpAndSettle();
      expectOrgList(tester);
    });

    testWidgets('the org menu item is disabled in an org without roots', (tester) async {
      await pump(tester, config: _config(lastOrg: 'C'));
      await _go(tester, '/p/gamma/flow');

      await tester.tap(find.byKey(const ValueKey('current-org')));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Nova atividade na org'),
      );

      expect(item.enabled, isFalse);
    });

    testWidgets('an engine error stays inline and keeps the palette open', (tester) async {
      await pump(tester);
      await _go(tester, '/o/A/sessions');
      sessions.orgError = Exception('diretorio invalido: /dev/a2');
      await _metaShift(tester, LogicalKeyboardKey.keyK);

      await startAndSend(tester);

      expect(find.textContaining('diretorio invalido: /dev/a2'), findsOneWidget);
      expect(hint(tester), 'Nova conversa em A: escreva o prompt');
      expect(_location(tester), '/o/A/sessions');
    });
  });
}
