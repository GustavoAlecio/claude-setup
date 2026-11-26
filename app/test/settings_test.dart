import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/core/claude_home.dart';
import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/flow_repository.dart';
import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_parser.dart';
import 'package:claude_flow/data/github_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _data = [Project(name: 'alpha', path: '/dev/a/alpha'), Project(name: 'beta', path: '/dev/b/beta')];

Map<String, dynamic> _config({String a = '/dev/a', String b = '/dev/b'}) => {
  'engineDir': '/engine',
  'orgs': [
    {
      'name': 'A',
      'roots': [a],
    },
    {
      'name': 'B',
      'roots': [b],
    },
  ],
  'projects': [
    {'name': 'gamma', 'path': '/dev/a/gamma', 'org': 'A'},
  ],
  'lastOrg': 'A',
};

Future<void> _openSettings(
  WidgetTester tester,
  FlowRepository repo, {
  FolderPicker? picker,
  GitHubRepository? github,
  MockSessionsRepository? sessions,
  EffectivePaths? paths,
}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: repo,
      sessions: sessions ?? MockSessionsRepository(),
      engine: const MockEngineController(),
      pickDirectory: picker ?? () async => null,
      github: github,
      paths: paths,
    ),
  );
  await tester.pumpAndSettle();
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/settings');
  await tester.pumpAndSettle();
}

class _RejectingConfig extends MockFlowRepository {
  _RejectingConfig({super.data, super.config});

  @override
  Future<void> updateConfig(ConfigMutation mutation) async => throw const ConfigWriteException('x');
}

class _EngineDown extends MockGitHubRepository {
  @override
  Future<List<GithubAccount>> accounts() async => throw const GitHubException('engine iniciando');
}

class _AccountsSequence extends MockGitHubRepository {
  final calls = <Completer<List<GithubAccount>>>[];

  @override
  Future<List<GithubAccount>> accounts() {
    final c = Completer<List<GithubAccount>>();
    calls.add(c);
    return c.future;
  }
}

class _SshHangs extends MockGitHubRepository {
  _SshHangs() : super(accountList: const [GithubAccount(login: 'acct-a', active: true, valid: true)]);

  final pending = Completer<SshIdentity>();

  @override
  Future<SshIdentity> sshIdentity({String? owner, String? cwd, bool fresh = false}) => pending.future;
}

Map<String, dynamic> _configWithOwner(String owner, {String? account}) {
  final c = _config();
  (c['orgs'] as List)[0]['github'] = {
    'account': account,
    'owners': [owner],
  };
  return c;
}

const _accts = [
  GithubAccount(login: 'acct-a', active: true, valid: true),
  GithubAccount(login: 'acct-b', valid: false),
];

Finder _save(String org) => _in('settings-org-form-$org', find.widgetWithText(FilledButton, 'Salvar'));

Finder _in(String key, Finder finder) => find.descendant(of: find.byKey(ValueKey(key)), matching: finder);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// git runs as a real process, which only completes outside FakeAsync: the tap and its handler run in runAsync.
/// Without [done] (an outcome only visible after a rebuild) it waits a fixed half second.
Future<void> _tapAndWait(WidgetTester tester, Finder finder, [bool Function()? done]) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    for (var i = 0; i < (done == null ? 10 : 100) && !(done?.call() ?? false); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 1400);
    view.devicePixelRatio = 1;
  });

  group('settings', () {
    testWidgets('adding a subfolder of a git repo registers its root in org 2; again is rejected', (tester) async {
      final tmp = (await tester.runAsync(() async {
        final root = Directory.systemTemp.createTempSync('settings_test').resolveSymbolicLinksSync();
        Directory('$root/b/repo/src').createSync(recursive: true);
        Directory('$root/a').createSync();
        final init = await Process.run('git', ['init', '-q', '$root/b/repo']);
        expect(init.exitCode, 0, reason: '${init.stderr}');
        return root;
      }))!;
      addTearDown(() => Directory(tmp).deleteSync(recursive: true));
      final repo = MockFlowRepository(
        data: _data,
        config: _config(a: '$tmp/a', b: '$tmp/b'),
      );
      await _openSettings(tester, repo, picker: () async => '$tmp/b/repo/src');

      await _tapAndWait(tester, find.text('Adicionar projeto'), () => repo.config.projects.length > 1);

      expect(repo.rawConfig['projects'], [
        {'name': 'gamma', 'path': '/dev/a/gamma', 'org': 'A'},
        {'name': 'repo', 'path': '$tmp/b/repo'},
      ]);
      expect(_in('settings-projects-B', find.text('repo')), findsOneWidget);
      expect(_in('settings-projects-B', find.text('$tmp/b/repo')), findsOneWidget);

      await _tapAndWait(tester, find.text('Adicionar projeto'));

      expect(find.text('projeto já adicionado: "repo"'), findsOneWidget);
      expect(repo.config.projects, hasLength(2));
    });

    testWidgets('Voltar sits below the macOS traffic lights', (tester) async {
      await _openSettings(tester, MockFlowRepository(data: _data, config: _config()));

      final voltar = tester.getRect(find.widgetWithText(TextButton, 'Voltar'));
      expect(voltar.top >= 28 || voltar.left >= 80, isTrue, reason: '$voltar');
    });

    testWidgets('Adicionar projeto stays disabled while the picker is open', (tester) async {
      final picked = Completer<String?>();
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, picker: () => picked.future);
      Finder button() => find.widgetWithText(TextButton, 'Adicionar projeto');

      await tester.tap(button());
      await tester.pump();
      expect(tester.widget<TextButton>(button()).onPressed, isNull);

      picked.complete(null);
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(button()).onPressed, isNotNull);
      expect(repo.config.projects, hasLength(1));
    });

    testWidgets('Enter in the org name saves it', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(repo.config.orgs.map((o) => o.name), ['Alfa', 'B']);
    });

    testWidgets('Ocultar moves the project to Ocultos and Reexibir brings it back', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await _tap(tester, _in('settings-projects-A', find.widgetWithText(TextButton, 'Ocultar')).first);

      expect(repo.config.hidden, ['alpha']);
      expect(_in('settings-projects-A', find.text('alpha')), findsNothing);
      expect(_in('settings-hidden', find.text('alpha')), findsOneWidget);

      await _tap(tester, _in('settings-hidden', find.text('Reexibir')));

      expect(repo.config.hidden, isEmpty);
      expect(_in('settings-projects-A', find.text('alpha')), findsOneWidget);
      expect(_in('settings-hidden', find.text('nenhum projeto oculto')), findsOneWidget);
    });

    testWidgets('trocar org pins the project to the chosen org', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await _tap(tester, find.byTooltip('Trocar org de alpha'));
      await _tap(tester, find.text('B').last);

      expect(repo.config.projects.where((p) => p.name == 'alpha').single.org, 'B');
      expect(_in('settings-projects-B', find.text('alpha')), findsOneWidget);
    });

    testWidgets('renaming an org rewrites projects[].org and lastOrg; removing one reverts to the root rule', (
      tester,
    ) async {
      final repo = MockFlowRepository(
        data: _data,
        config: {
          ..._config(),
          'projects': [
            {'name': 'gamma', 'path': '/dev/a/gamma', 'org': 'A'},
            {'name': 'delta', 'path': '/dev/a/delta', 'org': 'B'},
          ],
        },
      );
      await _openSettings(tester, repo);

      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await _tap(tester, _in('settings-org-form-A', find.text('Salvar')));

      expect(repo.config.orgs.map((o) => o.name), ['Alfa', 'B']);
      expect(repo.config.lastOrg, 'Alfa');
      expect(repo.config.projects.map((p) => p.org), ['Alfa', 'B']);

      expect(find.byKey(const ValueKey('settings-org-form-Alfa')), findsOneWidget, reason: 'rename keeps it selected');
      expect(find.byKey(const ValueKey('settings-org-form-B')), findsNothing);

      await _tap(tester, find.byKey(const ValueKey('settings-org-row-B')));
      await _tap(tester, _in('settings-org-form-B', find.text('Remover org')));
      expect(find.text('Remover B?'), findsOneWidget);
      expect(find.textContaining('2 projetos ficam sem org'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilledButton, 'Remover org'));

      expect(repo.config.orgs.map((o) => o.name), ['Alfa']);
      expect(repo.config.projects.map((p) => p.org), ['Alfa', null]);
      expect(_in('settings-projects-Alfa', find.text('delta')), findsOneWidget, reason: '/dev/a root');
      expect(_in('settings-projects-Sem org', find.text('beta')), findsOneWidget);
    });

    testWidgets('global budget per cycle saves a positive value and an org can override it', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await tester.enterText(find.byKey(const ValueKey('settings-cycle-budget')), '7,5');
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const ValueKey('settings-cycle-budget-save')));
      expect(repo.config.cycleBudget, 7.5);

      final orgBudget = _in('settings-org-form-A', find.byKey(const ValueKey('org-form-budget')));
      await tester.ensureVisible(orgBudget);
      expect(find.text('herdar global (\$7.50)'), findsOneWidget);
      await tester.enterText(orgBudget, '2');
      await tester.pumpAndSettle();
      final save = _in('settings-org-form-A', find.text('Salvar'));
      await tester.ensureVisible(save);
      await _tap(tester, save);
      expect(repo.config.orgs.firstWhere((o) => o.name == 'A').cycleBudget, 2);
    });

    testWidgets('Avançado writes nodePath and paletteSkills; blank removes the key; engineDir is required', (
      tester,
    ) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);
      final toggle = find.byKey(const ValueKey('settings-advanced-toggle'));
      await tester.scrollUntilVisible(toggle, 200, scrollable: find.byType(Scrollable).first);
      await _tap(tester, toggle);

      final save = find.byKey(const ValueKey('settings-advanced-save'));
      await tester.enterText(find.byKey(const ValueKey('settings-advanced-engine-dir')), '');
      await tester.pumpAndSettle();
      await tester.ensureVisible(save);
      await _tap(tester, save);
      expect(find.text('informe a pasta da engine: sem ela a engine não sobe'), findsOneWidget);
      expect(repo.config.engineDir, '/engine');

      await tester.enterText(find.byKey(const ValueKey('settings-advanced-engine-dir')), '/engine2');
      await tester.enterText(find.byKey(const ValueKey('settings-advanced-node-path')), '/opt/node');
      await tester.enterText(find.byKey(const ValueKey('settings-advanced-palette-skills')), '/fix, status');
      await tester.pumpAndSettle();
      await _tap(tester, save);

      expect(repo.config.paletteSkills, ['fix', 'status']);
      expect((repo.config.engineDir, repo.config.nodePath), ('/engine2', '/opt/node'));
      expect(find.text('Reiniciar engine'), findsOneWidget);
    });

    testWidgets('each project shows how its sessions run, from its org and the global defaults', (tester) async {
      final config = _config();
      (config['orgs'] as List)[0]['agent'] = {'provider': 'antigravity', 'account': 'likin.do'};
      await _openSettings(tester, MockFlowRepository(data: _data, config: config));

      final setup = find.byKey(const ValueKey('settings-project-setup-gamma'));
      await tester.scrollUntilVisible(setup, 200, scrollable: find.byType(Scrollable).first);
      expect(
        tester.widget<Text>(setup).data,
        'conversas: Antigravity · likin.do · modo: aceitar edições · GitHub: conta ativa',
      );
    });

    testWidgets('an org inserted above the open one keeps its dirty form mounted', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await _tap(tester, find.byKey(const ValueKey('settings-org-row-B')));
      await tester.enterText(_in('settings-org-form-B', find.widgetWithText(TextField, 'Nome')), 'Bravo');
      await tester.pumpAndSettle();

      await repo.updateConfig(
        (raw) => {
          ...raw,
          'orgs': [
            {
              'name': 'Z',
              'roots': ['/dev/z'],
            },
            ...(raw['orgs'] as List),
          ],
        },
      );
      await tester.pumpAndSettle();

      expect(repo.config.orgs.map((o) => o.name), ['Z', 'A', 'B']);
      expect(find.byKey(const ValueKey('settings-org-form-B')), findsOneWidget);
      expect(
        tester.widget<TextField>(_in('settings-org-form-B', find.widgetWithText(TextField, 'Bravo'))).controller?.text,
        'Bravo',
      );
    });

    testWidgets('Duplicar starts a new org with the same permissions and agent, asking only name and folder', (
      tester,
    ) async {
      final config = _config();
      (config['orgs'] as List)[0]['permissionMode'] = 'default';
      (config['orgs'] as List)[0]['agent'] = {'provider': 'antigravity', 'account': 'likin.do'};
      final repo = MockFlowRepository(data: _data, config: config);
      await _openSettings(tester, repo, picker: () async => '/dev/c');

      await _tap(tester, find.byKey(const ValueKey('settings-org-duplicate')));
      expect(find.text('Nova org (cópia das configurações)'), findsOneWidget);
      await tester.enterText(_in('settings-new-org', find.widgetWithText(TextField, 'Nome')), 'C');
      await _tap(tester, _in('settings-new-org', find.text('escolher pasta')));
      await _tap(tester, _in('settings-new-org', find.text('Criar org')));

      final created = repo.config.orgs.firstWhere((o) => o.name == 'C');
      expect(created.roots, ['/dev/c']);
      expect(created.permissionMode, PermissionMode.defaultMode);
      expect((created.agent?.provider, created.agent?.account), (AgentProvider.antigravity, 'likin.do'));
    });

    testWidgets('a new org overlapping another root or reusing a name is rejected inline', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, picker: () async => '/dev/a/sub');

      await _tap(tester, find.byKey(const ValueKey('settings-new-org-button')));
      await tester.enterText(_in('settings-new-org', find.widgetWithText(TextField, 'Nome')), 'C');
      await _tap(tester, _in('settings-new-org', find.text('escolher pasta')));
      await _tap(tester, _in('settings-new-org', find.text('Criar org')));

      expect(find.textContaining('sobrepõe'), findsOneWidget);

      await tester.enterText(_in('settings-new-org', find.widgetWithText(TextField, 'Nome')), 'B');
      await _tap(tester, _in('settings-new-org', find.text('Criar org')));

      expect(find.text('já existe uma org chamada "B"'), findsOneWidget);
      expect(repo.config.orgs.map((o) => o.name), ['A', 'B']);
    });
  });

  group('permissions', () {
    Future<void> scrollTo(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, Finder menu, String label) async {
      await _tap(tester, menu);
      await _tap(tester, find.text(label).last);
    }

    testWidgets('the global mode starts at aceitar edições; bypass asks first and then warns', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);
      final menu = find.byKey(const ValueKey('settings-permission-mode'));
      await scrollTo(tester, menu);

      expect(find.descendant(of: menu, matching: find.text('aceitar edições')), findsOneWidget);
      expect(_in('settings-advanced', find.text('as sessões rodam sem pedir confirmação')), findsNothing);

      await pick(tester, menu, 'bypass');
      expect(find.text('Usar bypass?'), findsOneWidget);
      await _tap(tester, find.text('Cancelar'));
      expect(repo.rawConfig['permissionMode'], isNull);

      await pick(tester, menu, 'bypass');
      await _tap(tester, find.text('Usar bypass'));
      expect(repo.rawConfig['permissionMode'], 'bypassPermissions');
      expect(_in('settings-advanced', find.text('as sessões rodam sem pedir confirmação')), findsOneWidget);
    });

    testWidgets('OrgForm writes the org mode and "herdar global" removes the key', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);
      final dropdown = _in('settings-org-form-A', find.byKey(const ValueKey('org-permission-mode')));
      expect(_in('settings-org-form-A', find.text('herdar global (aceitar edições)')), findsOneWidget);

      await _tap(tester, dropdown);
      await _tap(tester, find.textContaining('auto (classificador)').last);
      await _tap(tester, _save('A'));
      expect(repo.rawConfig['orgs'][0]['permissionMode'], 'auto');
      expect((repo.rawConfig['orgs'][1] as Map).containsKey('permissionMode'), isFalse);

      await pick(tester, dropdown, 'herdar global (aceitar edições)');
      await _tap(tester, _save('A'));
      expect((repo.rawConfig['orgs'][0] as Map).containsKey('permissionMode'), isFalse);
      expect(repo.config.orgs.first.name, 'A');
    });
  });

  group('alerta sonoro', () {
    const channel = MethodChannel('claude_flow/attention');
    late int sounds;

    Future<void> open(WidgetTester tester, MockFlowRepository repo) async {
      sounds = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'sound') sounds++;
        return call.method == 'isActive' ? true : null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      await _openSettings(tester, repo);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-alert-sound')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    final toggle = find.byKey(const ValueKey('settings-alert-sound'));

    testWidgets('desligar grava falso sem tocar; ligar grava verdadeiro e toca uma vez', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await open(tester, repo);
      expect(_in('settings-advanced', find.text('toca quando algo novo espera você')), findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isTrue);

      await _tap(tester, toggle);
      expect(repo.rawConfig['alertSound'], isFalse);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(sounds, 0);

      await _tap(tester, toggle);
      expect(repo.rawConfig['alertSound'], isTrue);
      expect(sounds, 1);
    });

    testWidgets('erro de escrita mostra a mensagem, mantém o valor e não toca', (tester) async {
      await open(tester, _RejectingConfig(data: _data, config: _config()));

      await _tap(tester, toggle);
      expect(find.byKey(const ValueKey('settings-alert-sound-error')), findsOneWidget);
      expect(find.text('x'), findsOneWidget);
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(sounds, 0);
    });
  });

  group('OrgForm tracker', () {
    Finder field(String key) => _in('settings-org-form-A', find.byKey(ValueKey('org-tracker-$key')));

    Future<void> pickKind(WidgetTester tester, String label) async {
      await _tap(tester, field('kind'));
      await _tap(tester, find.text(label).last);
    }

    testWidgets('Jira saves site, key and email; an incomplete tracker is refused inline', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);
      await pickKind(tester, 'Jira');

      await tester.enterText(field('site'), 'https://likindo.atlassian.net/');
      await tester.enterText(field('project'), 'lc');
      await _tap(tester, _save('A'));
      expect(find.text('informe o site, a chave do projeto e o email do Jira'), findsOneWidget);
      expect((repo.rawConfig['orgs'][0] as Map).containsKey('tracker'), isFalse);

      await tester.enterText(field('email'), 'me@likin.do');
      await _tap(tester, field('release'));
      await _tap(tester, _save('A'));
      expect(repo.rawConfig['orgs'][0]['tracker'], {
        'kind': 'jira',
        'project': 'LC',
        'site': 'likindo.atlassian.net',
        'email': 'me@likin.do',
        'base': 'release',
      });

      await pickKind(tester, 'nenhum (só kickoff manual)');
      await _tap(tester, _save('A'));
      expect((repo.rawConfig['orgs'][0] as Map).containsKey('tracker'), isFalse);
    });
  });

  group('OrgForm GitHub', () {
    testWidgets('lists the accounts and saves the chosen account with owners from suggestion and typing', (
      tester,
    ) async {
      final gh = MockGitHubRepository(
        accountList: _accts,
        orgSuggestions: {
          'acct-a': ['acct-a', 'Org-X'],
        },
        gitProtocol: 'https',
      );
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, github: gh);

      expect(find.byKey(const ValueKey('org-github-https')), findsWidgets);
      await _tap(tester, _in('settings-org-form-A', find.byKey(const ValueKey('org-github-account'))));
      await _tap(tester, find.text('acct-a').last);
      expect(gh.orgsCalls, contains('acct-a'));

      await _tap(tester, _in('settings-org-form-A', find.widgetWithText(ActionChip, 'Org-X')));
      await tester.enterText(_in('settings-org-form-A', find.byKey(const ValueKey('org-github-owner-input'))), 'ORG-y');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(_in('settings-org-form-A', find.byKey(const ValueKey('org-github-owner-input'))), 'org-x');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await _tap(tester, _save('A'));

      expect(repo.rawConfig['orgs'][0]['github'], {
        'account': 'acct-a',
        'owners': ['Org-X', 'ORG-y'],
      });
      expect(gh.sshCalls.every((c) => c.fresh), isTrue);
    });

    testWidgets('invalid owner format shows an inline error and is not added', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, github: MockGitHubRepository(accountList: _accts));

      final input = _in('settings-org-form-A', find.byKey(const ValueKey('org-github-owner-input')));
      await tester.enterText(input, 'a b');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.textContaining('org do GitHub inválida'), findsOneWidget);
      expect(_in('settings-org-form-A', find.byType(InputChip)), findsNothing);
    });

    testWidgets('SSH identity different from the account blocks saving, ignoring case elsewhere', (tester) async {
      final gh = MockGitHubRepository(
        accountList: _accts,
        sshIdentities: {'org-x': const SshIdentity(owner: 'org-x', host: 'github.com-alias', login: 'ACCT-B')},
      );
      final repo = MockFlowRepository(
        data: _data,
        config: _configWithOwner('org-x', account: 'acct-a'),
      );
      await _openSettings(tester, repo, github: gh);

      expect(find.text('SSH de org-x autentica como @ACCT-B, diferente da conta @acct-a'), findsOneWidget);
      expect(tester.widget<FilledButton>(_save('A')).onPressed, isNull);

      await _tap(tester, _in('settings-org-form-A', find.byKey(const ValueKey('org-github-account'))));
      await _tap(tester, find.text('acct-b').last);

      expect(find.text('SSH: @ACCT-B via github.com-alias'), findsOneWidget);
      expect(tester.widget<FilledButton>(_save('A')).onPressed, isNotNull);
    });

    testWidgets('SSH check failure shows "SSH não verificado" and saving stays enabled', (tester) async {
      final gh = MockGitHubRepository(accountList: _accts)..sshError = const GitHubException('timeout');
      final repo = MockFlowRepository(
        data: _data,
        config: _configWithOwner('org-x', account: 'acct-a'),
      );
      await _openSettings(tester, repo, github: gh);

      expect(find.text('SSH não verificado'), findsOneWidget);
      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await tester.pump();
      expect(tester.widget<FilledButton>(_save('A')).onPressed, isNotNull);
      await _tap(tester, _save('A'));
      expect(repo.rawConfig['orgs'][0]['github'], {
        'account': 'acct-a',
        'owners': ['org-x'],
      });
    });

    testWidgets('a pending SSH check of a saved owner does not block other edits', (tester) async {
      final repo = MockFlowRepository(
        data: _data,
        config: _configWithOwner('org-x', account: 'acct-a'),
      );
      await _openSettings(tester, repo, github: _SshHangs());

      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await tester.pump();
      expect(tester.widget<FilledButton>(_save('A')).onPressed, isNotNull);
      expect(find.byKey(const ValueKey('org-form-blocked')), findsNothing);
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('a new owner with a pending SSH check disables saving with the reason, for at most 10 s', (
      tester,
    ) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, github: _SshHangs());

      await tester.enterText(_in('settings-org-form-A', find.byKey(const ValueKey('org-github-owner-input'))), 'org-y');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<FilledButton>(_save('A')).onPressed, isNull);
      expect(find.text('verificando o SSH de org-y…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 11));
      expect(find.text('SSH não verificado'), findsOneWidget);
      expect(tester.widget<FilledButton>(_save('A')).onPressed, isNotNull);
    });

    testWidgets('engine unavailable shows "engine iniciando" and the rest of the org can be saved', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, github: _EngineDown());

      expect(find.text('engine iniciando'), findsWidgets);
      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await _tap(tester, _save('A'));

      expect(repo.config.orgs.map((o) => o.name), ['Alfa', 'B']);
      expect(repo.rawConfig['orgs'][0].containsKey('github'), isFalse);
    });

    testWidgets('an old accounts error does not come back after "Recarregar contas"', (tester) async {
      final gh = _AccountsSequence();
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, github: gh);
      final initial = gh.calls.length;

      await _tap(tester, _in('settings-org-form-A', find.byKey(const ValueKey('org-github-reload'))));
      expect(gh.calls, hasLength(initial + 1));

      gh.calls.last.complete(_accts);
      await tester.pumpAndSettle();
      gh.calls[0].completeError(const GitHubException('erro antigo'));
      await tester.pumpAndSettle();

      expect(find.text('erro antigo'), findsNothing);
    });

    testWidgets('the divergence message is the one from sshDivergence', (tester) async {
      const identity = SshIdentity(owner: 'org-x', host: 'github.com', login: 'acct-b');
      final gh = MockGitHubRepository(accountList: _accts, sshIdentities: {'org-x': identity});
      final repo = MockFlowRepository(
        data: _data,
        config: _configWithOwner('org-x', account: 'acct-a'),
      );
      await _openSettings(tester, repo, github: gh);

      expect(find.text(sshDivergence(identity, 'acct-a')!), findsOneWidget);
    });

    testWidgets('a saved account that is no longer logged in is flagged', (tester) async {
      final repo = MockFlowRepository(
        data: _data,
        config: _configWithOwner('org-x', account: 'gone'),
      );
      await _openSettings(tester, repo, github: MockGitHubRepository(accountList: _accts)..orgsFailFor = {'gone'});

      expect(find.text('não logada'), findsOneWidget);
    });
  });

  group('OrgForm Agente', () {
    Finder inA(Finder f) => _in('settings-org-form-A', f);

    Future<void> pick(WidgetTester tester, Finder menu, String label) async {
      await _tap(tester, menu);
      await _tap(tester, find.text(label).last);
    }

    testWidgets('Antigravity with the default account lists the models and saves provider and model', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await pick(tester, inA(find.byKey(const ValueKey('org-agent-provider'))), 'Antigravity');
      expect(inA(find.text('logada')), findsOneWidget);
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-model'))));
      expect(
        find.textContaining('Gemini 3.1 Pro (High)  esgotado · renova em'),
        findsWidgets,
        reason: 'quota beside the name',
      );
      await _tap(tester, find.textContaining('Gemini 3.1 Pro (High)').last);
      await _tap(tester, _save('A'));

      expect(repo.rawConfig['orgs'][0]['agent'], {'provider': 'antigravity', 'model': 'gemini-3.1-pro-high'});
      expect(
        _in(
          'settings-org-row-A',
          find.text('Antigravity nas conversas livres · aceitar edições · GitHub da conta ativa'),
        ),
        findsOneWidget,
        reason: 'the row shows the agent',
      );
    });

    testWidgets('an account without login shows the terminal command and no models', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await pick(tester, inA(find.byKey(const ValueKey('org-agent-provider'))), 'Antigravity');
      await tester.enterText(inA(find.byKey(const ValueKey('org-agent-account'))), 'likin.do');
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-check'))));

      expect(inA(find.textContaining('sem login')), findsOneWidget);
      expect(inA(find.text('HOME="~/.claude-flow/accounts/antigravity/likin.do" agy')), findsOneWidget);
      await _tap(tester, _save('A'));
      expect(repo.rawConfig['orgs'][0]['agent'], {'provider': 'antigravity', 'account': 'likin.do'});
    });

    testWidgets('Fazer login opens the account in Terminal and the form picks the login up', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      final sessions = MockSessionsRepository();
      await _openSettings(tester, repo, sessions: sessions);

      await pick(tester, inA(find.byKey(const ValueKey('org-agent-provider'))), 'Antigravity');
      await tester.enterText(inA(find.byKey(const ValueKey('org-agent-account'))), 'likin.do');
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-check'))));
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-login'))));

      expect(sessions.agentLoginCalls, ['likin.do']);
      expect(inA(find.text('aguardando o login no Terminal…')), findsOneWidget);

      sessions.loggedInAccounts.add('likin.do');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(inA(find.text('logada')), findsOneWidget);
    });

    testWidgets('an invalid account blocks saving inline', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await pick(tester, inA(find.byKey(const ValueKey('org-agent-provider'))), 'Antigravity');
      await tester.enterText(inA(find.byKey(const ValueKey('org-agent-account'))), '../x');
      await _tap(tester, _save('A'));

      expect(inA(find.text('conta do Antigravity inválida')), findsOneWidget);
      expect(repo.rawConfig['orgs'][0]['agent'], isNull);
    });
  });

  group('unsaved changes', () {
    testWidgets('an edited org shows it, and Voltar or another row asks before discarding', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo);

      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('org-form-dirty')), findsOneWidget);

      await _tap(tester, find.widgetWithText(TextButton, 'Voltar'));
      expect(find.text('Descartar alterações?'), findsOneWidget);
      await _tap(tester, find.text('Continuar editando'));
      expect(find.byKey(const ValueKey('settings-org-form-A')), findsOneWidget);

      await _tap(tester, find.byKey(const ValueKey('settings-org-row-B')));
      await _tap(tester, find.text('Descartar'));
      expect(find.byKey(const ValueKey('settings-org-form-B')), findsOneWidget);
      expect(repo.config.orgs.map((o) => o.name), ['A', 'B']);
      expect(find.byKey(const ValueKey('org-form-dirty')), findsNothing);
    });

    testWidgets('a global shortcut (⌘I) also asks before leaving with unsaved edits', (tester) async {
      await _openSettings(tester, MockFlowRepository(data: _data, config: _config()));
      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      Future<void> metaI() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pumpAndSettle();
      }

      await metaI();
      expect(find.text('Descartar alterações?'), findsOneWidget);
      await _tap(tester, find.text('Continuar editando'));
      expect(find.byKey(const ValueKey('settings-org-form-A')), findsOneWidget);

      await metaI();
      await _tap(tester, find.text('Descartar'));
      expect(find.byKey(const ValueKey('settings-org-form-A')), findsNothing);
    });

    testWidgets('quitting (⌘Q or closing the window) with unsaved edits asks; keep editing cancels the quit', (
      tester,
    ) async {
      await _openSettings(tester, MockFlowRepository(data: _data, config: _config()));
      await tester.enterText(_in('settings-org-form-A', find.widgetWithText(TextField, 'Nome')), 'Alfa');
      await tester.pumpAndSettle();

      final keep = tester.binding.handleRequestAppExit();
      await tester.pumpAndSettle();
      expect(find.text('Descartar alterações?'), findsOneWidget);
      await _tap(tester, find.text('Continuar editando'));
      expect(await keep, AppExitResponse.cancel);

      final discard = tester.binding.handleRequestAppExit();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Descartar'));
      expect(await discard, AppExitResponse.exit);
    });

    testWidgets('an untouched org leaves without asking', (tester) async {
      await _openSettings(tester, MockFlowRepository(data: _data, config: _config()));
      await _tap(tester, find.byKey(const ValueKey('settings-org-row-B')));
      expect(find.text('Descartar alterações?'), findsNothing);
      expect(find.byKey(const ValueKey('settings-org-form-B')), findsOneWidget);
    });
  });

  group('projects', () {
    testWidgets('moving a project that changes its agent asks first and can be undone', (tester) async {
      final config = _config();
      (config['orgs'] as List)[1]['agent'] = {'provider': 'antigravity', 'account': 'likin.do'};
      final repo = MockFlowRepository(data: _data, config: config);
      await _openSettings(tester, repo);

      await _tap(tester, find.byTooltip('Trocar org de gamma'));
      await _tap(tester, find.text('B').last);
      expect(find.text('Mover gamma para B?'), findsOneWidget);
      expect(find.textContaining('Agente: Claude → Antigravity · likin.do'), findsOneWidget);
      await _tap(tester, find.text('Mover'));
      expect(repo.config.projects.firstWhere((p) => p.name == 'gamma').org, 'B');

      await _tap(tester, find.text('Desfazer'));
      expect(repo.config.projects.firstWhere((p) => p.name == 'gamma').org, 'A');
    });

    testWidgets('the add button of an org pins the picked folder to it', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('settings-add-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, picker: () async => tmp.path);
      await tester.ensureVisible(find.byKey(const ValueKey('settings-add-project-B')));
      await tester.pumpAndSettle();

      await _tapAndWait(
        tester,
        find.byKey(const ValueKey('settings-add-project-B')),
        () => repo.config.projects.any((p) => p.path == tmp.path),
      );
      final added = repo.config.projects.firstWhere((p) => p.path == tmp.path);
      expect(added.org, 'B');
    });
  });

  group('org form details', () {
    Finder inA(Finder f) => _in('settings-org-form-A', f);

    testWidgets('a new org shows both missing fields at once, and picking a folder fills the name', (tester) async {
      await _openSettings(
        tester,
        MockFlowRepository(data: _data, config: _config()),
        picker: () async => '/dev/zeta',
      );
      await _tap(tester, find.byKey(const ValueKey('settings-new-org-button')));

      await _tap(tester, _in('settings-new-org', find.text('Criar org')));
      expect(_in('settings-new-org', find.text('informe um nome para a org')), findsOneWidget);
      expect(_in('settings-new-org', find.text('escolha uma pasta para a org')), findsOneWidget);

      await _tap(tester, _in('settings-new-org', find.text('escolher pasta')));
      expect(
        tester.widget<TextField>(_in('settings-new-org', find.widgetWithText(TextField, 'Nome'))).controller!.text,
        'zeta',
      );
    });

    testWidgets('an exhausted model warns that free prompts will fail', (tester) async {
      await _openSettings(tester, MockFlowRepository(data: _data, config: _config()));
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-provider'))));
      await _tap(tester, find.text('Antigravity').last);
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-model'))));
      await _tap(tester, find.textContaining('Gemini 3.1 Pro (High)').last);
      expect(inA(find.byKey(const ValueKey('org-agent-model-exhausted'))), findsOneWidget);
    });

    testWidgets('waiting for the Antigravity login can be cancelled', (tester) async {
      await _openSettings(tester, MockFlowRepository(data: _data, config: _config()));
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-provider'))));
      await _tap(tester, find.text('Antigravity').last);
      await tester.enterText(inA(find.byKey(const ValueKey('org-agent-account'))), 'likin.do');
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-check'))));
      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-login'))));
      expect(inA(find.text('aguardando o login no Terminal…')), findsOneWidget);

      await _tap(tester, inA(find.byKey(const ValueKey('org-agent-login-cancel'))));
      expect(inA(find.byKey(const ValueKey('org-agent-login'))), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('settings nav', () {
    const paths = EffectivePaths(home: '/dev', workflowRoot: '/dev/.claude/workflow');
    const sections = ['orgs', 'projects', 'stop', 'budget', 'advanced'];
    final longRoot = '/dev/${'c' * 75}';

    Map<String, dynamic> threeOrgs() {
      final config = _config();
      (config['orgs'] as List).add({
        'name': 'C',
        'roots': [longRoot, '/dev/other'],
      });
      ((config['orgs'] as List)[1] as Map)['github'] = {'account': 'gh-demo', 'owners': <String>[]};
      return config;
    }

    void small(WidgetTester tester) {
      final view = tester.binding.platformDispatcher.views.first;
      view.physicalSize = const Size(1100, 700);
      view.devicePixelRatio = 1;
    }

    Finder key(String k) => find.byKey(ValueKey(k));

    List<String> bold(WidgetTester tester) => [
      for (final id in sections)
        if (tester.widget<Text>(_in('settings-nav-$id', find.byType(Text))).style?.fontWeight == FontWeight.w600) id,
    ];

    testWidgets('opens on Orgs; Avançado brings its section to the top and takes the highlight', (tester) async {
      small(tester);
      await _openSettings(
        tester,
        MockFlowRepository(data: _data, config: threeOrgs()),
        paths: paths,
      );

      expect(key('settings-nav'), findsOneWidget);
      expect(_in('settings-nav', find.byType(Scrollable)), findsNothing);
      for (final id in sections) {
        expect(key('settings-$id'), findsOneWidget);
      }
      expect(bold(tester), ['orgs']);

      await tester.tap(key('settings-nav-advanced'));
      await tester.pumpAndSettle();

      final top = tester.getTopLeft(key('settings-advanced')).dy - tester.getTopLeft(key('settings-content')).dy;
      expect(top, inInclusiveRange(0, 40));
      expect(bold(tester), ['advanced']);

      await tester.tap(key('settings-nav-stop'));
      await tester.pumpAndSettle();
      expect(bold(tester), ['stop']);
      expect(
        tester.getTopLeft(key('settings-stop')).dy - tester.getTopLeft(key('settings-content')).dy,
        inInclusiveRange(0, 40),
      );
    });

    testWidgets('each org is a row with folder, summary and count; the first is open and a tap opens another', (
      tester,
    ) async {
      small(tester);
      await _openSettings(
        tester,
        MockFlowRepository(data: _data, config: threeOrgs()),
        paths: paths,
      );

      expect(_in('settings-org-row-A', find.text('~/a')), findsOneWidget);
      expect(_in('settings-org-row-A', find.text('Claude · aceitar edições · GitHub da conta ativa')), findsOneWidget);
      expect(_in('settings-org-row-A', find.text('2 projetos')), findsOneWidget);
      expect(_in('settings-org-row-B', find.text('~/b')), findsOneWidget);
      expect(_in('settings-org-row-B', find.text('Claude · aceitar edições · GitHub gh-demo')), findsOneWidget);
      expect(_in('settings-org-row-B', find.text('1 projeto')), findsOneWidget);
      expect(_in('settings-org-row-C', find.text('~/${'c' * 75} +1')), findsOneWidget);
      expect(_in('settings-org-row-C', find.text('0 projetos')), findsOneWidget);

      expect(key('settings-org-carousel'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => switch (w.key) {
            ValueKey<String>(:final value) => value.startsWith('settings-org-card-'),
            _ => false,
          },
        ),
        findsNothing,
      );

      expect(key('settings-org-form-A'), findsOneWidget);
      expect(
        tester.getTopLeft(key('settings-org-form-A')).dy,
        inInclusiveRange(
          tester.getBottomLeft(key('settings-org-row-A')).dy,
          tester.getTopLeft(key('settings-org-row-B')).dy,
        ),
        reason: 'the form sits right below its row',
      );

      await _tap(tester, key('settings-org-row-A'));
      expect(key('settings-org-form-A'), findsOneWidget, reason: 'tapping the open row does not close it');

      await _tap(tester, key('settings-org-row-B'));
      expect(key('settings-org-form-B'), findsOneWidget);
      expect(key('settings-org-form-A'), findsNothing);

      await tester.enterText(_in('settings-org-form-B', find.widgetWithText(TextField, 'Nome')), 'Beta');
      await tester.pumpAndSettle();
      await _tap(tester, key('settings-org-row-C'));
      expect(find.text('Descartar alterações?'), findsOneWidget);
      await _tap(tester, find.text('Descartar'));
      expect(key('settings-org-form-C'), findsOneWidget);

      await _tap(tester, key('settings-new-org-button'));
      expect(key('settings-new-org'), findsOneWidget);
      expect(
        tester.getBottomLeft(key('settings-new-org')).dy,
        lessThanOrEqualTo(tester.getTopLeft(key('settings-org-row-A')).dy),
      );
    });

    testWidgets('without a home the folder is shown whole', (tester) async {
      await _openSettings(
        tester,
        MockFlowRepository(data: _data, config: _config()),
        paths: const EffectivePaths(workflowRoot: '/dev/.claude/workflow'),
      );

      expect(_in('settings-org-row-A', find.text('/dev/a')), findsOneWidget);
    });

    testWidgets('Quando parar em você lists the three default rules, read-only', (tester) async {
      small(tester);
      await _openSettings(
        tester,
        MockFlowRepository(data: _data, config: threeOrgs()),
        paths: paths,
      );

      const rules = [
        ('Spec e PR', 'param sempre'),
        ('Plano e tasks', 'param só quando há uma decisão sua'),
        ('Travou ou bloqueou', 'para sempre'),
      ];
      for (final (i, (what, stops)) in rules.indexed) {
        final title = _in('settings-stop-$i', find.text(what));
        expect(title, findsOneWidget);
        expect(tester.widget<Text>(title).style?.fontWeight, FontWeight.w600);
        expect(_in('settings-stop-$i', find.text(stops)), findsOneWidget);
      }
      expect(key('settings-stop-3'), findsNothing);
      expect(_in('settings-stop', find.textContaining('/auto no terminal')), findsOneWidget);
    });

    testWidgets('a required plan gate splits Plano and Tasks into two rows', (tester) async {
      await _openSettings(
        tester,
        MockFlowRepository(data: _data, config: _config(), requiredGates: const {'spec', 'pr', 'plan'}),
      );

      expect(_in('settings-stop-1', find.text('Plano')), findsOneWidget);
      expect(_in('settings-stop-1', find.text('param sempre')), findsOneWidget);
      expect(_in('settings-stop-2', find.text('Tasks')), findsOneWidget);
      expect(key('settings-stop-3'), findsOneWidget);
      expect(key('settings-stop-4'), findsNothing);
    });

    testWidgets('Orçamento holds the budget field and Avançado the mode, the alert and the engine panel', (
      tester,
    ) async {
      small(tester);
      final repo = MockFlowRepository(data: _data, config: threeOrgs());
      await _openSettings(tester, repo, paths: paths);

      expect(_in('settings-budget', key('settings-cycle-budget')), findsOneWidget);
      expect(_in('settings-advanced', key('settings-cycle-budget')), findsNothing);
      expect(_in('settings-advanced', key('settings-permission-mode')), findsOneWidget);
      expect(_in('settings-advanced', key('settings-alert-sound')), findsOneWidget);
      expect(_in('settings-advanced', key('settings-advanced-toggle')), findsOneWidget);
      expect(key('settings-permissions'), findsNothing);
      expect(key('settings-advanced'), findsOneWidget);
      expect(
        tester.getTopLeft(key('settings-permission-mode')).dy,
        lessThan(tester.getTopLeft(key('settings-alert-sound')).dy),
      );
      expect(
        tester.getTopLeft(key('settings-alert-sound')).dy,
        lessThan(tester.getTopLeft(key('settings-advanced-toggle')).dy),
      );

      await tester.enterText(key('settings-cycle-budget'), '3');
      await tester.pumpAndSettle();
      await _tap(tester, key('settings-cycle-budget-save'));
      expect(repo.config.cycleBudget, 3);
    });

    testWidgets('1100x700 with three orgs, an 80-character folder and a form open does not overflow', (tester) async {
      small(tester);
      expect(longRoot, hasLength(80));
      await _openSettings(
        tester,
        MockFlowRepository(data: _data, config: threeOrgs()),
        paths: paths,
      );
      expect(tester.takeException(), isNull);

      await _tap(tester, key('settings-org-row-C'));
      expect(key('settings-org-form-C'), findsOneWidget);
      for (final id in sections) {
        await tester.tap(key('settings-nav-$id'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: id);
      }
    });
  });
}
