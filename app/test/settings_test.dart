import 'dart:async';
import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/flow_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:flutter/material.dart';
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

Future<void> _openSettings(WidgetTester tester, FlowRepository repo, {FolderPicker? picker}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: repo,
      sessions: MockSessionsRepository(),
      engine: const MockEngineController(),
      pickDirectory: picker ?? () async => null,
    ),
  );
  await tester.pumpAndSettle();
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/settings');
  await tester.pumpAndSettle();
}

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

      await tester.enterText(_in('settings-org-form-A', find.byType(TextField)), 'Alfa');
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

      await tester.enterText(_in('settings-org-form-A', find.byType(TextField)), 'Alfa');
      await _tap(tester, _in('settings-org-form-A', find.text('Salvar')));

      expect(repo.config.orgs.map((o) => o.name), ['Alfa', 'B']);
      expect(repo.config.lastOrg, 'Alfa');
      expect(repo.config.projects.map((p) => p.org), ['Alfa', 'B']);

      await _tap(tester, _in('settings-org-form-B', find.text('Remover org')));

      expect(repo.config.orgs.map((o) => o.name), ['Alfa']);
      expect(repo.config.projects.map((p) => p.org), ['Alfa', null]);
      expect(_in('settings-projects-Alfa', find.text('delta')), findsOneWidget, reason: '/dev/a root');
      expect(_in('settings-projects-Sem org', find.text('beta')), findsOneWidget);
    });

    testWidgets('a new org overlapping another root or reusing a name is rejected inline', (tester) async {
      final repo = MockFlowRepository(data: _data, config: _config());
      await _openSettings(tester, repo, picker: () async => '/dev/a/sub');

      await _tap(tester, find.text('Nova org'));
      await tester.enterText(_in('settings-new-org', find.byType(TextField)), 'C');
      await _tap(tester, _in('settings-new-org', find.text('escolher pasta')));
      await _tap(tester, _in('settings-new-org', find.text('Criar org')));

      expect(find.textContaining('sobrepõe'), findsOneWidget);

      await tester.enterText(_in('settings-new-org', find.byType(TextField)), 'B');
      await _tap(tester, _in('settings-new-org', find.text('Criar org')));

      expect(find.text('já existe uma org chamada "B"'), findsOneWidget);
      expect(repo.config.orgs.map((o) => o.name), ['A', 'B']);
    });
  });
}
