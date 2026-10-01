import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _data = [
  Project(name: 'alpha', path: '/dev/a/alpha'),
  Project(name: 'beta', path: '/dev/b/beta'),
  Project(name: 'hid', path: '/dev/a/hid'),
  Project(name: 'loose'),
];

Map<String, dynamic> _config() => {
  'engineDir': '/engine',
  'orgs': [
    {
      'name': 'A',
      'roots': ['/dev/a'],
    },
    {
      'name': 'B',
      'roots': ['/dev/b'],
    },
  ],
  'projects': [
    {'name': 'gamma', 'path': '/dev/a/gamma'},
  ],
  'hidden': ['hid'],
  'lastOrg': 'A',
};

/// Counts only the writes that changed the config, like the file repository (no-op mutations never hit disk).
class _CountingRepository extends MockFlowRepository {
  _CountingRepository() : super(data: _data, config: _config());

  int writes = 0;

  @override
  Future<void> updateConfig(ConfigMutation mutation) async {
    final before = rawConfig;
    await super.updateConfig(mutation);
    if (!identical(before, rawConfig)) writes++;
  }
}

/// Config emissions reach the cubit late, like FSEvents plus debounce in the file repository.
class _SlowConfigRepository extends MockFlowRepository {
  _SlowConfigRepository(Map<String, dynamic> config) : super(data: _data, config: config);

  late final _slow = super
      .watchConfig()
      .asyncMap((c) => Future.delayed(const Duration(milliseconds: 300), () => c))
      .asBroadcastStream();

  @override
  Stream<DashboardConfig> watchConfig() => _slow;
}

/// Every config write fails, like a `.dashboard.json` that became invalid on disk.
class _FailingRepository extends MockFlowRepository {
  _FailingRepository(Map<String, dynamic> config) : super(data: _data, config: config);

  int attempts = 0;

  @override
  Future<void> updateConfig(ConfigMutation mutation) async {
    attempts++;
    throw const ConfigWriteException('falhou');
  }
}

SessionSummary _session(String id, String project, int pending) => SessionSummary(
  id: id,
  project: project,
  command: '/fix $project',
  title: 'Sessão $project',
  status: SessionStatus.waitingPermission,
  createdAt: '2026-03-10T14:41:00Z',
  pendingPermissions: pending,
);

final _fixed = [
  _session('s-alpha', 'alpha', 1),
  _session('s-beta', 'beta', 2),
  _session('s-hid', 'hid', 4),
  _session('s-ghost', 'ghost', 8),
];

class _Sessions extends MockSessionsRepository {
  final created = <(String, String, String?)>[];

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.value(_fixed);

  @override
  Stream<SessionDetail> watchSession(String id) {
    final fixed = _fixed.where((s) => s.id == id).firstOrNull;
    return fixed == null ? super.watchSession(id) : Stream.value(SessionDetail(summary: fixed));
  }

  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
  }) {
    created.add((project, command, cwd));
    return super.create(project, command, cwd: cwd, githubAccount: githubAccount, permissionMode: permissionMode);
  }
}

Finder _header() => find.byKey(const ValueKey('current-org'));

String _org(WidgetTester tester) => tester.widget<Text>(_header()).data!;

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.path;

Finder _sidebar(String text) => find.descendant(
  of: find.ancestor(of: _header(), matching: find.byType(Column)).first,
  matching: find.text(text),
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

  Future<(_CountingRepository, _Sessions)> pump(WidgetTester tester) async {
    final repo = _CountingRepository();
    final sessions = _Sessions();
    await tester.pumpWidget(ClaudeFlowApp(repository: repo, sessions: sessions, engine: const MockEngineController()));
    await tester.pumpAndSettle();
    return (repo, sessions);
  }

  group('orgs', () {
    testWidgets('sidebar lists only the current org and the registered project without a cycle', (tester) async {
      final (repo, _) = await pump(tester);

      expect(_location(tester), '/p/alpha/flow');
      expect(_org(tester), 'A');
      expect(_sidebar('alpha'), findsOneWidget);
      expect(_sidebar('gamma'), findsOneWidget);
      expect(_sidebar('beta'), findsNothing);
      expect(_sidebar('hid'), findsNothing, reason: 'hidden');
      expect(_sidebar('loose'), findsNothing, reason: 'no path → Sem org');
      expect(repo.writes, 0, reason: 'route org already equals lastOrg');
    });

    testWidgets('⌘2 switches to the second org and saves lastOrg', (tester) async {
      final (repo, _) = await pump(tester);

      await _meta(tester, LogicalKeyboardKey.digit2);

      expect(repo.config.lastOrg, 'B');
      expect(_org(tester), 'B');
      expect(_location(tester), '/p/beta/flow');
      expect(_sidebar('beta'), findsOneWidget);
      expect(_sidebar('alpha'), findsNothing);
      expect(repo.writes, 1);
    });

    testWidgets(
      '⌘ to an org without projects or roots from a project route lands on the landing even if config emits late',
      (tester) async {
        final config = _config();
        (config['orgs'] as List).add({'name': 'C', 'roots': <String>[]});
        final repo = _SlowConfigRepository(config);
        await tester.pumpWidget(
          ClaudeFlowApp(repository: repo, sessions: _Sessions(), engine: const MockEngineController()),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(_location(tester), '/p/alpha/flow');

        await _meta(tester, LogicalKeyboardKey.digit3);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(repo.config.lastOrg, 'C');
        expect(_location(tester), '/');
      },
    );

    testWidgets('a failed lastOrg write while the landing waits returns to / instead of a blank page', (tester) async {
      final config = _config();
      (config['orgs'] as List).add({'name': 'C', 'roots': <String>[]});
      await tester.pumpWidget(
        ClaudeFlowApp(
          repository: _FailingRepository(config),
          sessions: _Sessions(),
          engine: const MockEngineController(),
        ),
      );
      await tester.pumpAndSettle();

      await _meta(tester, LogicalKeyboardKey.digit3);

      final uri = _router(tester).routerDelegate.currentConfiguration.uri;
      expect(uri.queryParameters, isNot(contains('org')));
      expect(uri.path, '/p/alpha/flow', reason: 'landingFor reopens the unchanged lastOrg');
      expect(find.text('falhou'), findsOneWidget);
    });

    testWidgets('a lastOrg sync that keeps failing is attempted once, not on every rebuild', (tester) async {
      final repo = _FailingRepository(_config());
      await tester.pumpWidget(
        ClaudeFlowApp(repository: repo, sessions: _Sessions(), engine: const MockEngineController()),
      );
      await tester.pumpAndSettle();
      expect(repo.attempts, 0);

      _router(tester).go('/p/beta/flow');
      await tester.pumpAndSettle();
      _router(tester).go('/p/beta/runs');
      await tester.pumpAndSettle();
      _router(tester).go('/p/beta/sessions');
      await tester.pumpAndSettle();

      expect(_org(tester), 'B');
      expect(repo.attempts, 1);
    });

    testWidgets('⌘ digit beyond the configured orgs does nothing', (tester) async {
      final (repo, _) = await pump(tester);

      await _meta(tester, LogicalKeyboardKey.digit3);

      expect(_location(tester), '/p/alpha/flow');
      expect(repo.writes, 0);
    });

    testWidgets('a route into another org switches the header and writes lastOrg once', (tester) async {
      final (repo, _) = await pump(tester);

      _router(tester).go('/p/beta/flow');
      await tester.pumpAndSettle();

      expect(_org(tester), 'B');
      expect(repo.config.lastOrg, 'B');
      expect(repo.writes, 1);
    });

    testWidgets('an unknown project keeps the current org and never writes', (tester) async {
      final (repo, _) = await pump(tester);

      _router(tester).go('/p/nope/flow');
      await tester.pumpAndSettle();

      expect(_org(tester), 'A');
      expect(repo.writes, 0);
    });

    testWidgets('org menu switches org and opens Configurações', (tester) async {
      final (repo, _) = await pump(tester);

      await tester.tap(_header());
      await tester.pumpAndSettle();
      expect(find.text('⌘1'), findsOneWidget);
      expect(find.text('⌘2'), findsOneWidget);
      await tester.tap(find.text('B').last);
      await tester.pumpAndSettle();
      expect(repo.config.lastOrg, 'B');
      expect(_location(tester), '/p/beta/flow');

      await tester.tap(_header());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configurações'));
      await tester.pumpAndSettle();
      expect(_location(tester), '/settings');
    });

    testWidgets('shortcuts work outside the shell: ⌘, opens settings and ⌘2 there saves lastOrg', (tester) async {
      final (repo, _) = await pump(tester);

      await _meta(tester, LogicalKeyboardKey.comma);
      expect(_location(tester), '/settings');

      await _meta(tester, LogicalKeyboardKey.digit2);
      expect(repo.config.lastOrg, 'B');
      expect(_location(tester), '/settings');
    });

    testWidgets('Voltar returns to the last project route when the org did not change', (tester) async {
      final (repo, _) = await pump(tester);

      await _meta(tester, LogicalKeyboardKey.comma);
      await tester.tap(find.text('Voltar'));
      await tester.pumpAndSettle();

      expect(_location(tester), '/p/alpha/flow');
      expect(repo.writes, 0);
    });

    testWidgets('Voltar after ⌘2 in Configurações opens the new org instead of reverting it', (tester) async {
      final (repo, _) = await pump(tester);

      await _meta(tester, LogicalKeyboardKey.comma);
      await _meta(tester, LogicalKeyboardKey.digit2);
      await tester.tap(find.text('Voltar'));
      await tester.pumpAndSettle();

      expect(repo.config.lastOrg, 'B');
      expect(_location(tester), '/p/beta/flow');
      expect(_org(tester), 'B');
      expect(repo.writes, 1);
    });

    testWidgets('badges count only visible projects of the current org', (tester) async {
      await pump(tester);

      expect(find.byKey(const ValueKey('org-pending')), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('org-pending')), matching: find.text('1')),
        findsOneWidget,
        reason: 'alpha 1; beta (B), hid (hidden) and ghost (unknown) do not count in A',
      );
      expect(find.byTooltip('1 aguardando você'), findsOneWidget);
      expect(find.byTooltip('4 aguardando você'), findsNothing);
      expect(find.text('1 aguardando você'), findsOneWidget);
    });

    testWidgets('sessions tab: other projects stay inside the org', (tester) async {
      await pump(tester);

      _router(tester).go('/p/alpha/sessions');
      await tester.pumpAndSettle();
      expect(find.text('Sessão alpha'), findsOneWidget);
      expect(find.text('OUTROS PROJETOS'), findsNothing);
      expect(find.text('Sessão beta'), findsNothing);
      expect(find.text('Sessão hid'), findsNothing);
      expect(find.text('Sessão ghost'), findsNothing);
    });

    testWidgets('a session of an unknown project only shows up in Sem org', (tester) async {
      await pump(tester);

      _router(tester).go('/p/loose/sessions');
      await tester.pumpAndSettle();

      expect(_org(tester), 'Sem org');
      expect(find.text('OUTROS PROJETOS'), findsOneWidget);
      expect(find.text('Sessão ghost'), findsOneWidget);
      expect(find.text('Sessão alpha'), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('org-pending')), matching: find.text('8')), findsOneWidget);
    });

    testWidgets('a hidden project route opens with a notice and Reexibir brings it back', (tester) async {
      final (repo, _) = await pump(tester);

      _router(tester).go('/p/hid/flow');
      await tester.pumpAndSettle();
      expect(find.textContaining('Projeto oculto'), findsOneWidget);
      expect(_sidebar('hid'), findsNothing);
      expect(find.text('4 aguardando você'), findsNothing);

      await tester.tap(find.text('Reexibir'));
      await tester.pumpAndSettle();

      expect(repo.config.hidden, isEmpty);
      expect(find.textContaining('Projeto oculto'), findsNothing);
      expect(_sidebar('hid'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('org-pending')), matching: find.text('5')), findsOneWidget);
    });

    testWidgets('⌘K new conversation in a registered project sends its path as cwd', (tester) async {
      final (_, sessions) = await pump(tester);

      await tester.tap(_sidebar('gamma'));
      await tester.pumpAndSettle();
      expect(find.text('sem ciclo ativo'), findsWidgets);

      await _meta(tester, LogicalKeyboardKey.keyK);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'responda ok');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(sessions.created, [('gamma', 'responda ok', '/dev/a/gamma')]);
    });

    testWidgets('⌘K without a project keeps Nova conversa disabled', (tester) async {
      final (_, sessions) = await pump(tester);

      _router(tester).go('/p/nope/flow');
      await tester.pumpAndSettle();
      await _meta(tester, LogicalKeyboardKey.keyK);

      expect(find.text('nenhum projeto nesta org'), findsOneWidget);
      await tester.tap(find.text('Nova conversa'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.textContaining('escreva o prompt'), findsNothing);
      expect(sessions.created, isEmpty);
    });
  });

  group('landing', () {
    Future<MockFlowRepository> open(WidgetTester tester, Map<String, dynamic> config) async {
      final repo = MockFlowRepository(data: _data, config: config, suggestions: const ['/dev/a', '/dev/b']);
      await tester.pumpWidget(
        ClaudeFlowApp(repository: repo, sessions: _Sessions(), engine: const MockEngineController()),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    Finder nameField() => find.widgetWithText(TextField, 'Nome');

    testWidgets('without orgs a suggestion fills name and folder and saving opens the new org', (tester) async {
      final repo = await open(tester, {'engineDir': '/engine'});

      expect(find.text('Criar org'), findsWidgets);
      await tester.tap(find.widgetWithText(ActionChip, 'a'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(nameField()).controller!.text, 'a');
      expect(find.text('/dev/a'), findsOneWidget);

      await tester.enterText(nameField(), 'Pessoal');
      await tester.tap(find.widgetWithText(FilledButton, 'Criar org'));
      await tester.pumpAndSettle();

      expect(repo.rawConfig['orgs'], [
        {
          'name': 'Pessoal',
          'roots': ['/dev/a'],
        },
      ]);
      expect(repo.rawConfig['engineDir'], '/engine');
      expect(repo.config.lastOrg, 'Pessoal');
      expect(_location(tester), '/p/alpha/flow');
      expect(_org(tester), 'Pessoal');
    });

    testWidgets('Criar org rejects the reserved name and a missing folder inline', (tester) async {
      final repo = await open(tester, {});

      await tester.enterText(nameField(), 'x');
      await tester.tap(find.widgetWithText(FilledButton, 'Criar org'));
      await tester.pumpAndSettle();
      expect(find.text('escolha uma pasta para a org'), findsOneWidget);

      await tester.tap(find.widgetWithText(ActionChip, 'b'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), kNoOrg);
      await tester.tap(find.widgetWithText(FilledButton, 'Criar org'));
      await tester.pumpAndSettle();

      expect(find.text('"$kNoOrg" é um nome reservado'), findsOneWidget);
      expect(repo.rawConfig, isEmpty);
      expect(_location(tester), '/');
    });

    testWidgets('lastOrg unset offers the orgs plus Sem org and choosing one opens it', (tester) async {
      final repo = await open(tester, {..._config()}..remove('lastOrg'));

      expect(find.text('Escolha uma org'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'A'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'B'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, kNoOrg), findsOneWidget, reason: 'loose has no path');

      await tester.tap(find.widgetWithText(OutlinedButton, 'B'));
      await tester.pumpAndSettle();

      expect(repo.config.lastOrg, 'B');
      expect(_location(tester), '/p/beta/flow');
    });

    testWidgets('a stale lastOrg falls back to the chooser', (tester) async {
      await open(tester, {..._config(), 'lastOrg': 'Z'});

      expect(find.text('Escolha uma org'), findsOneWidget);
      expect(_location(tester), '/');
    });

    testWidgets('Sem org with only a pending session of an unknown project opens and links to it', (tester) async {
      final repo = MockFlowRepository(
        data: [
          for (final p in _data)
            if (p.name != 'loose') p,
        ],
        config: {..._config(), 'lastOrg': kNoOrg},
      );
      await tester.pumpWidget(
        ClaudeFlowApp(repository: repo, sessions: _Sessions(), engine: const MockEngineController()),
      );
      await tester.pumpAndSettle();

      expect(find.text('nenhum projeto em $kNoOrg — adicione em Configurações'), findsOneWidget);
      await tester.tap(find.text('Ver sessões aguardando em ghost'));
      await tester.pumpAndSettle();

      expect(_location(tester), '/p/ghost/sessions');
      expect(_org(tester), kNoOrg);
      expect(find.text('Sessão ghost'), findsWidgets);
      expect(repo.config.lastOrg, kNoOrg);
    });

    testWidgets('lastOrg without visible projects or roots shows the empty org notice', (tester) async {
      await open(tester, {
        'orgs': [
          {'name': 'E', 'roots': <String>[]},
        ],
        'lastOrg': 'E',
      });

      expect(find.text('nenhum projeto em E — adicione em Configurações'), findsOneWidget);
      expect(_location(tester), '/');
    });
  });
}
