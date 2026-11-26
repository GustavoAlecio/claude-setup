import 'dart:async';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/attention.dart';
import 'package:claude_flow/data/inventory_models.dart';
import 'package:claude_flow/data/inventory_parser.dart';
import 'package:claude_flow/data/inventory_repository.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_inventory_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/orgs.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/features/launcher/command_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _alpha = Project(name: 'alpha', path: '/dev/a/alpha');

const _data = [_alpha, Project(name: 'beta', path: '/dev/b/beta')];

const _config = <String, dynamic>{
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
  'lastOrg': 'A',
};

SessionSummary _waiting(String id, String project) => SessionSummary(
  id: id,
  project: project,
  command: 'resuma $project',
  title: 'Sessão $project',
  status: SessionStatus.waitingPermission,
  createdAt: '2026-03-10T14:41:00Z',
  pendingPermissions: 1,
);

class _Sessions extends MockSessionsRepository {
  _Sessions({this.list = const [], this.loadSkills});

  final List<SessionSummary> list;

  /// `null` keeps the skills of the mock.
  final Future<List<PaletteSkill>> Function()? loadSkills;

  @override
  Future<List<PaletteSkill>> skills() => loadSkills?.call() ?? super.skills();

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.value(list);

  @override
  Stream<SessionDetail> watchSession(String id) {
    final fixed = list.where((s) => s.id == id).firstOrNull;
    return fixed == null ? super.watchSession(id) : Stream.value(SessionDetail(summary: fixed));
  }
}

class _Adrs implements InventoryRepository {
  const _Adrs(this.adrs);

  final List<AdrEntry> adrs;

  @override
  Future<Inventory> loadInventory() async => const Inventory(claudeHome: '/mock/.claude');

  @override
  Future<ProjectInventory> loadProject(Project project) async => ProjectInventory(adrs: adrs);

  @override
  Future<({AdrEntry entry, String body})?> loadAdr(Project project, String id) async => null;
}

AdrEntry _adr(String id, String title, String file) =>
    AdrEntry(id: id, title: title, status: 'accepted', path: '/dev/a/alpha/docs/adr/$file');

final _twentySkills = [
  for (var i = 0; i < 20; i++)
    PaletteSkill(
      'skill-$i',
      'Faz uma tarefa bem comprida de descrever para caber em uma linha só da paleta número $i sem quebrar nada',
    ),
];

Finder _entry(String key) => find.byKey(ValueKey(key));

final _start = _entry('palette-action-start');
final _conversation = _entry('palette-action-conversation');
final _pending = _entry('palette-action-pending');
final _field = find.byType(TextField).last;

Finder _selected(String key) => find.descendant(of: _entry(key), matching: find.text('↵'));

Finder _within(Finder entry, String text) => find.descendant(of: entry, matching: find.text(text));

String _hint(WidgetTester tester) => tester.widget<TextField>(_field).decoration!.hintText!;

TextEditingController _text(WidgetTester tester) => tester.widget<TextField>(_field).controller!;

GoRouter _router(WidgetTester tester) => GoRouter.of(tester.element(find.byType(Scaffold).first));

String _location(WidgetTester tester) => _router(tester).routerDelegate.currentConfiguration.uri.toString();

Future<void> _pump(
  WidgetTester tester,
  String location, {
  _Sessions? sessions,
  MockDocsRepository? docs,
  bool inventory = false,
  InventoryRepository? adrs,
}) async {
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(data: _data, config: _config),
      sessions: sessions ?? _Sessions(),
      engine: const MockEngineController(),
      docs: docs,
      inventory: adrs ?? (inventory ? MockInventoryRepository() : const MockInventoryRepository.empty()),
    ),
  );
  await tester.pumpAndSettle();
  _router(tester).go(location);
  await tester.pumpAndSettle();
}

Future<void> _openPalette(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

// Not the Fluxo: without a cycle it asks the same question as the palette hint, and its side panel has a composer.
const _projectRoute = '/p/alpha/runs';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  test('paletteSelection picks the shortcut by name prefix, then the first jump, then the conversation', () {
    const skills = ['fix', 'status', 'review'];
    expect(paletteSelection('fix', skills: skills, hasJump: true), 'palette-skill-fix');
    expect(paletteSelection(' FI ', skills: skills, hasJump: false), 'palette-skill-fix');
    for (final text in ['revisar', 'revisar o login', 'explica o cache']) {
      expect(paletteSelection(text, skills: skills, hasJump: false), 'palette-action-conversation', reason: text);
    }
    expect(paletteSelection('spec', skills: skills, hasJump: true), 'jump');
    expect(paletteSelection('spec', skills: const [], hasJump: false), 'palette-action-conversation');
  });

  testWidgets('an artifact jump of a project with a space in the name opens the encoded location', (tester) async {
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(
          data: [const Project(name: 'my app', path: '~/development/my-app')],
        ),
        sessions: MockSessionsRepository(),
        engine: const MockEngineController(),
        docs: MockDocsRepository({'spec.md': '# Spec'}),
      ),
    );
    await tester.pumpAndSettle();
    final router = _router(tester);
    router.go(artifactsLocation('my app', 'spec.md'));
    await tester.pumpAndSettle();
    router.go(Uri(pathSegments: ['', 'p', 'my app', 'flow']).toString());
    await tester.pumpAndSettle();

    await _openPalette(tester);
    await _type(tester, 'spec');
    final jump = _entry('palette-jump-${artifactsLocation('my app', 'spec.md')}');
    expect(_within(jump, 'O que vai ser entregue'), findsOneWidget);
    await tester.tap(jump);
    await tester.pumpAndSettle();

    expect(_location(tester), artifactsLocation('my app', 'spec.md'));
    expect(artifactsLocation('my app', 'spec.md'), '/p/my%20app/artifacts?doc=spec.md');
  });

  group('palette', () {
    testWidgets('a project palette asks what to do and lists the actions above the shortcuts', (tester) async {
      await _pump(tester, _projectRoute);
      await _openPalette(tester);

      expect(_hint(tester), 'O que você quer fazer em alpha?');
      expect(_within(_start, 'Começar um ciclo'), findsOneWidget);
      expect(_within(_start, 'de um card ou de uma descrição'), findsOneWidget);
      expect(_within(_conversation, 'Nova conversa'), findsOneWidget);
      expect(_within(_conversation, 'perguntar ou pedir algo fora de um ciclo'), findsOneWidget);
      expect(_within(_pending, 'Ir para a próxima pendência'), findsOneWidget);
      expect(_within(_pending, '⌘J'), findsOneWidget);
      final tops = [
        for (final f in [_start, _conversation, _pending, find.text('Atalhos do projeto')]) tester.getTopLeft(f).dy,
      ];
      expect(tops, [...tops]..sort());
      expect(tops.toSet(), hasLength(4));
      expect(find.text('Digite para buscar conversas, documentos e decisões · esc fecha'), findsOneWidget);
    });

    testWidgets('the pending action counts every org and goes where ⌘J would', (tester) async {
      final waiting = [_waiting('s-alpha', 'alpha'), _waiting('s-beta', 'beta')];
      await _pump(tester, _projectRoute, sessions: _Sessions(list: waiting));
      await _openPalette(tester);

      expect(_within(_pending, '2 esperando você'), findsOneWidget);
      expect(nextAttentionRoute(pendingAttention(waiting, _data), _projectRoute), '/p/alpha/sessions/s-alpha');

      await tester.tap(_pending);
      await tester.pumpAndSettle();
      expect(_conversation, findsNothing);
      expect(_location(tester), '/p/alpha/sessions/s-alpha');

      await _openPalette(tester);
      await tester.tap(_pending);
      await tester.pumpAndSettle();
      expect(_location(tester), '/p/beta/sessions/s-beta', reason: 'the item after the one on screen');
    });

    testWidgets('with nothing waiting the pending action is disabled', (tester) async {
      await _pump(tester, _projectRoute);
      await _openPalette(tester);

      expect(_within(_pending, 'nada esperando você'), findsOneWidget);
      await tester.tap(_pending);
      await tester.pumpAndSettle();
      expect(_conversation, findsOneWidget);
      expect(_location(tester), _projectRoute);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selected('palette-action-pending'), findsNothing, reason: 'selected, but ↵ is not offered');
      await _enter(tester);
      expect(_conversation, findsOneWidget);
    });

    testWidgets('enter on the empty field starts a cycle in a project', (tester) async {
      await _pump(tester, _projectRoute);
      await _openPalette(tester);
      expect(_selected('palette-action-start'), findsOneWidget);

      await _enter(tester);
      expect(_conversation, findsNothing);
      expect(find.text('Novo kickoff em alpha'), findsOneWidget);
    });

    testWidgets('enter on the empty field opens the free prompt in an org', (tester) async {
      await _pump(tester, '/o/A/sessions');
      await _openPalette(tester);

      expect(_hint(tester), 'O que você quer fazer em A?');
      expect(_start, findsNothing);
      expect(find.text('Atalhos da org'), findsOneWidget);
      expect(_selected('palette-action-conversation'), findsOneWidget);

      await _enter(tester);
      expect(_hint(tester), 'Nova conversa em A: escreva o prompt');
    });

    testWidgets('typing a skill name and enter asks for its arguments', (tester) async {
      await _pump(tester, _projectRoute);
      await _openPalette(tester);
      await _type(tester, 'fix');
      expect(_selected('palette-skill-fix'), findsOneWidget);

      await _enter(tester);
      expect(_hint(tester), 'argumentos (opcional)');
      expect(find.descendant(of: _field, matching: find.text('/fix')), findsOneWidget);
      expect(_text(tester).text, isEmpty);
    });

    testWidgets('free text and enter opens the prompt with the text kept', (tester) async {
      await _pump(tester, _projectRoute);
      await _openPalette(tester);
      await _type(tester, 'explica o cache');
      expect(_selected('palette-action-conversation'), findsOneWidget);

      await _enter(tester);
      expect(_hint(tester), 'Nova conversa em alpha: escreva o prompt');
      expect(_text(tester).text, startsWith('explica o cache'));
      expect(_text(tester).selection, const TextSelection.collapsed(offset: 15));
    });

    testWidgets('text that only matches the phrase of a shortcut still opens the prompt', (tester) async {
      final sessions = _Sessions();
      await _pump(tester, _projectRoute, sessions: sessions);
      await _openPalette(tester);
      await _type(tester, 'revisar');
      expect(_entry('palette-skill-review'), findsOneWidget);
      expect(_selected('palette-action-conversation'), findsOneWidget);

      await _type(tester, 'revisar o login');
      await _enter(tester);
      expect(_hint(tester), 'Nova conversa em alpha: escreva o prompt');

      await _enter(tester);
      expect(sessions.createCalls.single.$2, 'revisar o login');
    });

    testWidgets('arrow down from the last action selects the first shortcut', (tester) async {
      await _pump(tester, _projectRoute);
      await _openPalette(tester);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.pumpAndSettle();

      expect(_selected('palette-skill-fix'), findsOneWidget);
    });

    testWidgets('skills that arrive after the text was typed take the selection', (tester) async {
      final skills = Completer<List<PaletteSkill>>();
      await _pump(tester, _projectRoute, sessions: _Sessions(loadSkills: () => skills.future));
      await _openPalette(tester);
      await _type(tester, 'fix');
      expect(_entry('palette-skill-fix'), findsNothing);
      expect(_selected('palette-action-conversation'), findsOneWidget);

      skills.complete(const [PaletteSkill('status', ''), PaletteSkill('fix', '')]);
      await tester.pumpAndSettle();
      expect(_selected('palette-skill-fix'), findsOneWidget);
      expect(_selected('palette-action-conversation'), findsNothing);
    });

    testWidgets('a skill the engine lists twice shows once', (tester) async {
      await _pump(
        tester,
        _projectRoute,
        sessions: _Sessions(
          loadSkills: () async => const [
            PaletteSkill('fix', 'primeira'),
            PaletteSkill('status', ''),
            PaletteSkill('fix', 'segunda'),
          ],
        ),
      );
      await _openPalette(tester);

      expect(tester.takeException(), isNull);
      expect(_entry('palette-skill-fix'), findsOneWidget);
      expect(_entry('palette-skill-status'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_selected('palette-skill-status'), findsOneWidget);
    });

    testWidgets('ADRs that share an id or have none leave a single jump', (tester) async {
      final adrs = markDuplicateAdrs([
        _adr('0007', 'Cache local', '0007-cache-local.md'),
        _adr('0007', 'Cache remoto', '0007-cache-remoto.md'),
        _adr('', 'Rascunho de cache', 'rascunho.md'),
        _adr('', 'Outro rascunho de cache', 'outro.md'),
      ]);
      await _pump(tester, _projectRoute, adrs: _Adrs(adrs));
      await _openPalette(tester);
      await _type(tester, 'decis');

      expect(tester.takeException(), isNull);
      final jump = _entry('palette-jump-/p/alpha/adrs?adr=0007');
      expect(jump, findsOneWidget);
      expect(_within(jump, '0007 Cache local'), findsOneWidget);
      expect(find.textContaining('Cache remoto'), findsNothing);
      expect(find.textContaining('ascunho'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('skills that arrive after ↑↓ leave the selection alone', (tester) async {
      final skills = Completer<List<PaletteSkill>>();
      await _pump(tester, _projectRoute, sessions: _Sessions(loadSkills: () => skills.future));
      await _openPalette(tester);
      await _type(tester, 'fix');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_selected('palette-action-start'), findsOneWidget);

      skills.complete(const [PaletteSkill('fix', '')]);
      await tester.pumpAndSettle();
      expect(_selected('palette-action-start'), findsOneWidget);
    });

    testWidgets('skills that arrive after ↑↓ over a jump keep that jump selected', (tester) async {
      final skills = Completer<List<PaletteSkill>>();
      await _pump(
        tester,
        _projectRoute,
        sessions: _Sessions(loadSkills: () => skills.future),
        adrs: _Adrs([
          _adr('0001', 'Plano de cache', '0001-plano-de-cache.md'),
          _adr('0002', 'Plano de retry', '0002-plano-de-retry.md'),
        ]),
      );
      await _openPalette(tester);
      await _type(tester, 'pl');
      expect(_selected('palette-jump-/p/alpha/adrs?adr=0001'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selected('palette-jump-/p/alpha/adrs?adr=0002'), findsOneWidget);

      skills.complete(const [PaletteSkill('plan', '')]);
      await tester.pumpAndSettle();
      expect(_entry('palette-skill-plan'), findsOneWidget);
      expect(_selected('palette-jump-/p/alpha/adrs?adr=0002'), findsOneWidget);

      await _enter(tester);
      expect(_location(tester), '/p/alpha/adrs?adr=0002');
    });

    testWidgets('a shortcut shows its phrase and command, and the search keeps the actions', (tester) async {
      await _pump(tester, _projectRoute);
      await _openPalette(tester);

      final fix = _entry('palette-skill-fix');
      expect(_within(fix, 'Corrigir um bug sem abrir ciclo'), findsOneWidget);
      expect(_within(fix, '/fix'), findsOneWidget);

      await _type(tester, 'bug');
      expect(fix, findsOneWidget);
      expect(_entry('palette-skill-status'), findsNothing);
      expect(_entry('palette-skill-review'), findsNothing);
      for (final action in [_start, _conversation, _pending]) {
        expect(action, findsOneWidget);
      }

      await _type(tester, 'zzz');
      expect(find.text('Atalhos do projeto'), findsNothing);
    });

    testWidgets('documents are found by title or file name, and decisions carry their status', (tester) async {
      await _pump(tester, _projectRoute, docs: MockDocsRepository({'spec.md': '# Spec'}), inventory: true);
      await _openPalette(tester);
      final spec = _entry('palette-jump-${artifactsLocation('alpha', 'spec.md')}');

      for (final text in ['entregue', 'spec']) {
        await _type(tester, text);
        expect(_within(spec, 'O que vai ser entregue'), findsOneWidget, reason: text);
        expect(_within(spec, 'documento · alpha'), findsOneWidget, reason: text);
      }
      expect(_selected('palette-jump-${artifactsLocation('alpha', 'spec.md')}'), findsOneWidget);

      await _type(tester, 'parser puro');
      final adr = _entry('palette-jump-/p/alpha/adrs?adr=0001');
      expect(_within(adr, '0001 Parser puro separado do IO'), findsOneWidget);
      expect(_within(adr, 'decisão · aceito'), findsOneWidget);
    });

    testWidgets('without a project the actions and shortcuts are disabled', (tester) async {
      final sessions = _Sessions();
      await _pump(tester, '/p/nope/flow', sessions: sessions);
      await _openPalette(tester);

      expect(_hint(tester), 'O que você quer fazer?');
      expect(_within(_start, 'sem projeto nesta org'), findsOneWidget);
      expect(_within(_conversation, 'sem projeto nesta org'), findsOneWidget);
      expect(_within(_pending, 'nada esperando você'), findsOneWidget);

      for (final entry in [_start, _conversation, _entry('palette-skill-fix')]) {
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(_hint(tester), 'O que você quer fazer?');
      }
      await _enter(tester);
      expect(_hint(tester), 'O que você quer fazer?');
      expect(sessions.createCalls, isEmpty);
    });

    testWidgets('skill: opens on the arguments of the command before the engine lists the skills', (tester) async {
      final skills = Completer<List<PaletteSkill>>();
      final sessions = _Sessions(loadSkills: () => skills.future);
      await _pump(tester, _projectRoute, sessions: sessions);
      void open() => unawaited(
        showCommandPalette(tester.element(find.byType(Scaffold).first), const ProjectTarget(_alpha), skill: 'plan'),
      );

      open();
      await tester.pump();
      expect(_hint(tester), 'argumentos (opcional)');
      expect(find.descendant(of: _field, matching: find.text('/plan')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_hint(tester), 'O que você quer fazer em alpha?');
      expect(_conversation, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_conversation, findsNothing);

      open();
      await tester.pump();
      await _enter(tester);
      expect(sessions.createCalls.single.$2, '/plan');
      expect(_location(tester), '/p/alpha/sessions/mock-1');
      skills.complete(const []);
    });

    testWidgets('arrow down to the last of 20 shortcuts keeps the selected entry in view', (tester) async {
      await _pump(tester, _projectRoute, sessions: _Sessions(loadSkills: () async => _twentySkills));
      await _openPalette(tester);
      final list = find.ancestor(of: _start, matching: find.byType(SingleChildScrollView));
      expect(tester.getRect(_entry('palette-skill-skill-19')).top, greaterThan(tester.getRect(list).bottom));

      for (var i = 0; i < 22; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }

      expect(_selected('palette-skill-skill-19'), findsOneWidget);
      final viewport = tester.getRect(list);
      final entry = tester.getRect(_entry('palette-skill-skill-19'));
      expect(entry.top, greaterThanOrEqualTo(viewport.top));
      expect(entry.bottom, lessThanOrEqualTo(viewport.bottom));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_selected('palette-action-start'), findsOneWidget);
      expect(tester.getRect(_start).top, greaterThanOrEqualTo(tester.getRect(list).top));
    });

    testWidgets('20 skills with long descriptions fit a 1100 px window', (tester) async {
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, _projectRoute, sessions: _Sessions(loadSkills: () async => _twentySkills));
      await _openPalette(tester);

      expect(tester.takeException(), isNull);
      expect(_entry('palette-skill-skill-0'), findsOneWidget);
      expect(_within(_entry('palette-skill-skill-0'), '/skill-0'), findsOneWidget);
    });
  });
}
