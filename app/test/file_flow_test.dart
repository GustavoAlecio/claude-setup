import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/core/widgets/primitives.dart';
import 'package:claude_flow/data/file_flow_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _fixtures = 'test/fixtures/workflow';
final _stacksDir = Directory('test/fixtures/stacks').absolute.path;
const _names = ['alpha', 'beta', 'broken', 'gamma', 'legacy'];

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(followLinks: false)) {
    final name = entity.path.split('/').last;
    if (entity is Directory) {
      _copyTree(entity, Directory('${to.path}/$name'));
    } else if (entity is File) {
      entity.copySync('${to.path}/$name');
    }
  }
}

bool _allLoaded(List<Project> list) => _names.every((n) => list.any((p) => p.name == n));

/// Real IO (Directory.watch, Process.run) does not advance under FakeAsync, so loading happens in runAsync.
Future<List<Project>> _loadFixtures(WidgetTester tester) async {
  final projects = await tester.runAsync(() async {
    final repo = FileFlowRepository(Directory(_fixtures).absolute.path, stacksDir: _stacksDir);
    try {
      return await repo.watchProjects().firstWhere(_allLoaded).timeout(const Duration(seconds: 10));
    } finally {
      await repo.dispose();
    }
  });
  return projects!;
}

Future<void> _open(WidgetTester tester, List<Project> data, String location) async {
  await tester.pumpWidget(ClaudeFlowApp(repository: MockFlowRepository(data: data)));
  await tester.pumpAndSettle();
  await _go(tester, location);
}

Future<void> _go(WidgetTester tester, String location) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
  await tester.pumpAndSettle();
}

Finder _tierChip(Tier tier) => find.byWidgetPredicate((w) => w is TierChip && w.tier == tier);

Finder _currentStage(String stage) => find.descendant(
  of: find.ancestor(of: find.text('em andamento'), matching: find.byType(Column)).first,
  matching: find.text(stage),
);

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('alpha: blocked impl with repeated finding, escalation and ranked hypotheses', (tester) async {
    final data = await _loadFixtures(tester);
    await _open(tester, data, '/p/alpha/flow');

    expect(find.text('Pagina alpha'), findsWidgets);
    expect(find.text('#1001'), findsWidgets);
    expect(find.text('em andamento'), findsOneWidget);

    await _go(tester, '/p/alpha/runs');
    final t2Row = find.ancestor(of: find.text('Bloc e repositorio do alpha'), matching: find.byType(Row)).first;
    expect(find.descendant(of: t2Row, matching: _tierChip(Tier.haiku)), findsOneWidget);
    expect(find.descendant(of: t2Row, matching: _tierChip(Tier.sonnet)), findsOneWidget);

    await _go(tester, '/p/alpha/runs/impl-20260310T101500Z/T2');
    expect(find.text('Tentativas'), findsOneWidget);
    for (final label in ['#1', '#2', '#3', '#4']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('repetido ×3'), findsNWidgets(3));
    expect(find.text('igual à #1'), findsNWidgets(2));
    expect(find.text('lib/features/alpha/alpha_page.dart:12'), findsOneWidget);
    expect(find.text('unused_import'), findsNWidgets(3));
    expect(find.text('lib/features/alpha/alpha_repo.dart'), findsWidgets);
    expect(find.text('G1-ARCH-DI'), findsOneWidget);
    expect(find.text('→ sonnet'), findsOneWidget);

    final xs = [
      for (final lens in ['escopo', 'arquitetura', 'contrato']) tester.getTopLeft(find.text('lente: $lens')).dx,
    ];
    expect(xs[0] < xs[1] && xs[1] < xs[2], isTrue, reason: 'hypotheses ranked by confidence: $xs');
    expect(tester.takeException(), isNull);
  });

  testWidgets('beta: events-only run is running with 2 attempts, G0 fail and unknown tokens', (tester) async {
    final data = await _loadFixtures(tester);
    await _open(tester, data, '/p/beta/runs');

    expect(find.text('rodando'), findsWidgets);
    expect(find.textContaining('2 tentativas · — tokens out'), findsOneWidget);
    expect(find.text('—'), findsWidgets);

    await _go(tester, '/p/beta/runs/impl-20260311T140000Z/T1');
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
    final first = find.ancestor(of: find.text('#1'), matching: find.byType(Column)).first;
    expect(find.descendant(of: first, matching: find.text('G0')), findsOneWidget);
    expect(find.descendant(of: first, matching: find.text('fail')), findsWidgets);
    expect(find.text('→ sonnet'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('gamma: verify run labels attempts by round and shows cycle gate verdicts', (tester) async {
    final data = await _loadFixtures(tester);
    await _open(tester, data, '/p/gamma/runs');

    expect(find.text('smart-verify'), findsOneWidget);
    for (final gate in ['g1:flutter-architecture', 'g1:flutter-correctness', 'g1:dart-correctness', 'g2']) {
      final chip = find.ancestor(of: find.text(gate), matching: find.byType(Row)).first;
      expect(
        find.descendant(of: chip, matching: find.text('pass')),
        findsOneWidget,
        reason: gate,
      );
    }

    await _go(tester, '/p/gamma/runs/verify-20260310T113000Z/V1');
    expect(find.text('r1 #1'), findsOneWidget);
    expect(find.text('r1 #2'), findsOneWidget);
    expect(find.text('#1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy: partial current.json omits rows and shows the empty runs message', (tester) async {
    final data = await _loadFixtures(tester);
    await _open(tester, data, '/p/legacy/flow');

    expect(find.text('Ciclo'), findsOneWidget);
    for (final row in ['Card', 'Branch', 'Stack', 'Repo']) {
      expect(find.text(row), findsNothing, reason: row);
    }

    await _go(tester, '/p/legacy/runs');
    expect(find.text('sem execuções com escada neste ciclo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('broken: truncated jsonl and invalid result.json render without exceptions', (tester) async {
    final data = await _loadFixtures(tester);
    await _open(tester, data, '/p/broken/flow');
    expect(find.text('Fixture quebrada'), findsWidgets);
    expect(tester.takeException(), isNull);

    await _go(tester, '/p/broken/runs');
    expect(tester.takeException(), isNull);

    final run = data.firstWhere((p) => p.name == 'broken').cycle!.runs.firstOrNull;
    if (run != null && run.tasks.isNotEmpty) {
      await _go(tester, '/p/broken/runs/${run.id}/${run.tasks.first.id}');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('live stage label <= 1s', (tester) async {
    late Directory tmp;
    late FileFlowRepository repo;
    final current = await tester.runAsync(() async {
      tmp = Directory.systemTemp.createTempSync('file_flow_live');
      final root = '${tmp.path}/workflow';
      _copyTree(Directory(_fixtures), Directory(root));
      final past = DateTime.now().subtract(const Duration(days: 1));
      for (final n in _names.where((n) => n != 'alpha')) {
        File('$root/$n/current.json').setLastModifiedSync(past);
      }
      repo = FileFlowRepository(root, stacksDir: _stacksDir);
      await repo.watchProjects().firstWhere(_allLoaded).timeout(const Duration(seconds: 10));
      // Let FSEvents flush the copy before the timed change.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return File('$root/alpha/current.json');
    });
    addTearDown(
      () => tester.runAsync(() async {
        await repo.dispose();
        tmp.deleteSync(recursive: true);
      }),
    );

    await tester.pumpWidget(ClaudeFlowApp(repository: repo));
    await tester.pump();
    await _go(tester, '/p/alpha/flow');
    expect(_currentStage('implement'), findsOneWidget);

    final watch = Stopwatch();
    await tester.runAsync(() async {
      final json = jsonDecode(current!.readAsStringSync()) as Map<String, dynamic>;
      json['status'] = 'verifying';
      final staged = File('${current.parent.path}/current.tmp')..writeAsStringSync(jsonEncode(json));
      staged.renameSync(current.path);
      watch.start();
    });

    var moved = false;
    while (watch.elapsed < const Duration(seconds: 1)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      if (_currentStage('verify').evaluate().isNotEmpty) {
        moved = true;
        break;
      }
    }
    watch.stop();

    expect(moved, isTrue, reason: 'stage label did not move to verify within 1s (${watch.elapsedMilliseconds}ms)');
    expect(tester.takeException(), isNull);
  });
}
