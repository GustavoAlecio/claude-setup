import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/file_flow_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/orgs.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixtures = 'test/fixtures/workflow';
final _stacksDir = Directory('test/fixtures/stacks').absolute.path;
const _within = Duration(seconds: 1);
final _script = File('../bin/wf-checkpoint.sh').absolute.path;

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

Project _project(List<Project> list, String name) => list.firstWhere((p) => p.name == name);

void main() {
  late Directory tmp;
  late String root;
  late FileFlowRepository repo;

  Future<List<Project>> firstWhere(
    bool Function(List<Project>) test, {
    Duration timeout = const Duration(seconds: 5),
  }) => repo.watchProjects().firstWhere(test).timeout(timeout);

  Future<List<Project>> loaded() => firstWhere((l) => l.isNotEmpty);

  // FSEvents can still deliver the fixture copy shortly after the stream starts; let it drain before asserting.
  Future<void> settle() async {
    await loaded();
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('file_flow_repo_');
    // Not resolved on purpose: /var -> /private/var on macOS must be handled by the repository.
    root = '${tmp.path}/workflow';
    _copyTree(Directory(_fixtures), Directory(root));
    repo = FileFlowRepository(root, stacksDir: _stacksDir, checkpointScript: _script);
  });

  tearDown(() async {
    await repo.dispose();
    tmp.deleteSync(recursive: true);
  });

  group('listing', () {
    test('lists project dirs without dot entries, newest current.json first', () async {
      final base = DateTime(2026, 3, 1);
      for (final (i, name) in ['legacy', 'gamma', 'alpha', 'beta', 'broken'].indexed) {
        File('$root/$name/current.json').setLastModifiedSync(base.add(Duration(hours: i)));
      }

      final list = await loaded();

      expect(list.map((p) => p.name), ['broken', 'beta', 'alpha', 'gamma', 'legacy']);
    });

    test('path from project_path, auto mode from flag, runs newest first', () async {
      final list = await loaded();

      final alpha = _project(list, 'alpha');
      expect(alpha.path, '/synthetic/alpha');
      expect(alpha.stack, isNull);
      expect(alpha.cycle!.autoMode, isTrue);
      expect(alpha.cycle!.tracker, '#1001');
      expect(alpha.cycle!.branch, isNull);
      expect(_project(list, 'legacy').path, isNull);
      expect(_project(list, 'gamma').cycle!.runs.map((r) => r.id), [
        'verify-20260310T113000Z',
        'verify-20260310T110000Z',
      ]);
      expect(_project(list, 'beta').cycle!.runs.single.status, Verdict.running);
    });

    test('auto mode off when flag is not "on"', () async {
      File('$root/auto_mode.flag').writeAsStringSync('off\n');

      final list = await loaded();

      expect(list.every((p) => p.cycle == null || !p.cycle!.autoMode), isTrue);
    });

    test('path from .dashboard.json, stack by detect in path/app, branch from git', () async {
      final repoDir = Directory('${tmp.path}/legacy-repo')..createSync();
      Directory('${repoDir.path}/app').createSync();
      File('${repoDir.path}/app/pubspec.yaml').writeAsStringSync('name: x\n');
      final git = await Process.run('git', ['init', '-q', '-b', 'feat/legacy-branch', repoDir.path]);
      expect(git.exitCode, 0, reason: '${git.stderr}');
      File('$root/.dashboard.json').writeAsStringSync(
        jsonEncode({
          'cwds': {'legacy': repoDir.path},
        }),
      );

      final legacy = _project(await loaded(), 'legacy');

      expect(legacy.path, repoDir.path);
      expect(legacy.stack, 'flutter');
      expect(legacy.cycle!.branch, 'feat/legacy-branch');
    });

    test('missing root emits an empty list and reload() picks it up later', () async {
      final missing = '${tmp.path}/not-yet';
      await repo.dispose();
      repo = FileFlowRepository(missing, stacksDir: _stacksDir);

      expect(await repo.watchProjects().first.timeout(_within), isEmpty);

      _copyTree(Directory(_fixtures), Directory(missing));
      final next = firstWhere((l) => l.isNotEmpty);
      await repo.reload();

      expect((await next).map((p) => p.name), containsAll(['alpha', 'beta', 'broken', 'gamma', 'legacy']));
    });
  });

  test('keeps last valid run when result.json becomes invalid', () async {
    const runDir = 'broken/runs/impl-20260312T070000Z';
    File('$_fixtures/alpha/runs/impl-20260310T101500Z/result.json').copySync('$root/$runDir/result.json');

    final before = _project(await loaded(), 'broken').cycle!.runs.firstWhere((r) => r.id == 'impl-20260312T070000Z');
    expect(before.status, Verdict.blocked);
    await settle();

    final next = repo.watchProjects().skip(1).first.timeout(const Duration(seconds: 3));
    File('$root/$runDir/result.json').writeAsStringSync('{"status": "done", "tasks": [ {"id": ');
    final after = _project(await next, 'broken').cycle!.runs.firstWhere((r) => r.id == 'impl-20260312T070000Z');

    expect(after.status, Verdict.blocked);
    expect(after.tasks.map((t) => t.id), before.tasks.map((t) => t.id));
  });

  test('ignores lock and tmp churn', () async {
    await settle();
    var emissions = 0;
    final sub = repo.watchProjects().skip(1).listen((_) => emissions++);

    final lock = File('$root/alpha/.current.json.lock').openSync(mode: FileMode.write);
    lock.writeStringSync('x');
    lock.closeSync();
    File('$root/alpha/current.tmp').writeAsStringSync('{}');
    File('$root/alpha/runs/impl-20260310T101500Z/result.json.tmp').writeAsStringSync('{}');
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await sub.cancel();

    expect(emissions, 0);
  });

  test('emits within 1s after replace/append', () async {
    await settle();

    final current = File('$root/alpha/current.json');
    final json = jsonDecode(current.readAsStringSync()) as Map<String, dynamic>;
    json['status'] = 'verifying';
    final staged = File('$root/alpha/current.tmp')..writeAsStringSync(jsonEncode(json));
    final stage = firstWhere((l) => _project(l, 'alpha').cycle!.stage == Stage.verify, timeout: _within);
    staged.renameSync(current.path);
    await stage;

    await Future<void>.delayed(const Duration(milliseconds: 400));
    TaskRun betaTask(List<Project> l) => _project(l, 'beta').cycle!.runs.single.tasks.single;
    final g0Fail = firstWhere((l) {
      final attempts = betaTask(l).attempts;
      return attempts.length == 2 && attempts[1].gates.any((g) => g.gate == 'g0' && g.verdict == Verdict.fail);
    }, timeout: _within);
    File('$root/beta/runs/impl-20260311T140000Z/events.jsonl').writeAsStringSync(
      '${jsonEncode({'role': 'g0', 'task': 'T1', 'tier': 'sonnet', 'verdict': 'fail', 'attempt': 2})}\n',
      mode: FileMode.append,
    );
    await g0Fail;
  });

  test('keeps the current snapshot when listing the root fails', () async {
    final before = (await loaded()).map((p) => p.name).toList();
    await settle();

    Process.runSync('chmod', ['000', root]);
    try {
      await repo.reload();
    } finally {
      Process.runSync('chmod', ['755', root]);
    }

    expect((await repo.watchProjects().first.timeout(_within)).map((p) => p.name), before);
  });

  test('discards a load that finishes after the root was torn down', () async {
    for (final name in ['beta', 'broken', 'gamma', 'legacy']) {
      Directory('$root/$name').deleteSync(recursive: true);
    }
    // A FIFO profile parks _loadProject on a real await until the test writes to it.
    final stacks = Directory('${tmp.path}/stacks')..createSync();
    final fifo = '${stacks.path}/blocked.json';
    expect(Process.runSync('mkfifo', [fifo]).exitCode, 0);
    await repo.dispose();
    repo = FileFlowRepository(root, stacksDir: stacks.path, checkpointScript: _script);

    final emissions = <List<Project>>[];
    final sub = repo.watchProjects().listen(emissions.add);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(emissions, isEmpty);

    final emptied = repo.watchProjects().firstWhere((l) => l.isEmpty).timeout(const Duration(seconds: 5));
    Directory(root).deleteSync(recursive: true);
    await emptied;

    File(fifo).writeAsStringSync('{"detect": ["pubspec.yaml"]}');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await sub.cancel();
    expect(emissions.expand((l) => l), isEmpty);
  });

  group('orgs', () {
    void writeConfig(Map<String, dynamic> config) =>
        File('$root/.dashboard.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));

    Future<DashboardConfig> configWhere(bool Function(DashboardConfig) test) =>
        repo.watchConfig().firstWhere(test).timeout(const Duration(seconds: 5));

    void expectSameCycles(List<Project> before, List<Project> after) {
      for (final p in before.where((p) => p.cycle != null)) {
        expect(identical(_project(after, p.name).cycle, p.cycle), isTrue, reason: '${p.name} was reloaded');
      }
    }

    test('project only in projects is listed with cycle null and its explicit org', () async {
      writeConfig({
        'orgs': [
          {
            'name': 'synthetic',
            'roots': ['/synthetic'],
          },
        ],
        'projects': [
          {'name': 'added', 'path': '/elsewhere/added', 'org': 'synthetic'},
        ],
      });

      final list = await firstWhere((l) => l.any((p) => p.name == 'added'));

      final added = _project(list, 'added');
      expect((added.cycle, added.path, added.org, added.registered), (null, '/elsewhere/added', 'synthetic', true));
      expect(_project(list, 'alpha').org, 'synthetic');
      expect(_project(list, 'alpha').registered, isFalse);
    });

    test('path by scanning <root>/a/<name> picks the org; two candidates → no path', () async {
      final dev = '${tmp.path}/dev';
      final found = Directory('$dev/r10/a/legacy')..createSync(recursive: true);
      Directory('$dev/r10/x/twin').createSync(recursive: true);
      Directory('$dev/r10/y/twin').createSync(recursive: true);
      Directory('$root/twin').createSync();
      writeConfig({
        'orgs': [
          {
            'name': 'r10',
            'roots': ['$dev/r10'],
          },
        ],
      });

      final list = await firstWhere((l) => l.any((p) => p.name == 'twin'));

      expect(_project(list, 'legacy').path, found.path);
      expect(_project(list, 'legacy').org, 'r10');
      expect(_project(list, 'twin').path, isNull);
      expect(_project(list, 'twin').org, kNoOrg);
      expect(_project(list, 'alpha').org, kNoOrg);
    });

    test('a new root emits the rescanned projects before the config that adds it', () async {
      final dev = '${tmp.path}/dev';
      final found = Directory('$dev/fresh/legacy')..createSync(recursive: true);
      await settle();
      List<Project>? latest;
      final sub = repo.watchProjects().listen((l) => latest = l);
      addTearDown(sub.cancel);

      final config = jsonDecode(File('$root/.dashboard.json').readAsStringSync()) as Map<String, dynamic>;
      (config['orgs'] as List).add({
        'name': 'fresh',
        'roots': ['$dev/fresh'],
      });
      final atConfig = configWhere((c) => c.orgs.any((o) => o.name == 'fresh')).then((_) => latest);
      writeConfig(config);

      final projects = (await atConfig)!;
      expect(_project(projects, 'legacy').path, found.path);
      expect(_project(projects, 'legacy').org, 'fresh');
    });

    test('config-only change re-emits without reload', () async {
      await settle();
      final before = await repo.watchProjects().first;

      final config = jsonDecode(File('$root/.dashboard.json').readAsStringSync()) as Map<String, dynamic>;
      config['hidden'] = ['alpha'];
      final staged = File('$root/.dashboard.json.tmp')..writeAsStringSync(jsonEncode(config));
      final next = firstWhere((l) => _project(l, 'alpha').hidden, timeout: _within * 2);
      staged.renameSync('$root/.dashboard.json');

      expectSameCycles(before, await next);
    });

    test('tmp rename reaches watcher: updateConfig lands as ConfigScope; lastOrg alone does not reload', () async {
      await settle();
      await repo.updateConfig(createOrg('other', ['${tmp.path}/other']));
      await configWhere((c) => c.lastOrg == 'other');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final before = await repo.watchProjects().first;

      await repo.updateConfig(setLastOrg('synthetic'));
      final config = await configWhere((c) => c.lastOrg == 'synthetic');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(config.orgs.map((o) => o.name), ['synthetic', 'other']);
      expect(File('$root/.dashboard.json.tmp').existsSync(), isFalse);
      expectSameCycles(before, await repo.watchProjects().first);
    });

    test('updateConfig emits the written config without waiting for the watcher; the echo is a no-op', () async {
      await settle();
      final emissions = <DashboardConfig>[];
      final sub = repo.watchConfig().skip(1).listen(emissions.add);
      addTearDown(sub.cancel);

      await repo.updateConfig(hideProject('alpha'));

      // Read before the 300 ms debounce could deliver the FSEvents echo.
      expect((await repo.watchConfig().first).hidden, ['alpha']);
      expect(_project(await repo.watchProjects().first, 'alpha').hidden, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(emissions.map((c) => c.hidden), [
        ['alpha'],
      ]);
    });

    test('a slower rescan of an older config never overwrites a newer one', () async {
      final slow = '${tmp.path}/slow';
      final fast = '${tmp.path}/fast';
      final slowStarted = Completer<void>();
      await repo.dispose();
      repo = FileFlowRepository(
        root,
        stacksDir: _stacksDir,
        checkpointScript: _script,
        scanRoots: (roots) async {
          final base = roots.where((r) => r == slow || r == fast).firstOrNull;
          if (base == null) return const {};
          if (base == slow) {
            if (!slowStarted.isCompleted) slowStarted.complete();
            await Future<void>.delayed(const Duration(milliseconds: 1500));
          }
          return {
            'legacy': [ScanCandidate('$base/legacy', 0)],
          };
        },
      );
      await settle();
      // Same cwds as the fixture so the first change is a rescan and the config is set after the scan.
      Map<String, dynamic> config(String name, String root) => {
        'cwds': {'beta': '/synthetic/beta'},
        'orgs': [
          {
            'name': name,
            'roots': [root],
          },
        ],
      };

      writeConfig(config('slow', slow));
      await slowStarted.future.timeout(const Duration(seconds: 5));
      writeConfig(config('fast', fast));

      await configWhere((c) => c.orgs.single.name == 'fast');
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      expect((await repo.watchConfig().first).orgs.single.name, 'fast');
      final legacy = _project(await repo.watchProjects().first, 'legacy');
      expect((legacy.path, legacy.org), ('$fast/legacy', 'fast'));
    });

    test('invalid .dashboard.json keeps the last valid config', () async {
      await settle();
      final emissions = <DashboardConfig>[];
      final sub = repo.watchConfig().skip(1).listen(emissions.add);

      File('$root/.dashboard.json').writeAsStringSync('{"orgs": [');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await sub.cancel();

      expect(emissions, isEmpty);
      expect((await repo.watchConfig().first).lastOrg, 'synthetic');
      expect(_project(await repo.watchProjects().first, 'alpha').org, 'synthetic');
    });
  });

  group('numstat', () {
    late Directory work;

    String git(List<String> args) {
      final r = Process.runSync('git', ['-C', work.path, '-c', 'user.email=t@t', '-c', 'user.name=t', ...args]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return (r.stdout as String).trim();
    }

    setUp(() {
      work = Directory.systemTemp.createTempSync('numstat_repo_');
      git(['init', '-q']);
      File('${work.path}/a.txt').writeAsStringSync('one\n');
      git(['add', '.']);
      git(['commit', '-qm', 'init']);
      Directory('$root/gitproj').createSync();
      File(
        '$root/gitproj/current.json',
      ).writeAsStringSync(jsonEncode({'project_path': work.path, 'status': 'implementing'}));
    });

    tearDown(() => work.deleteSync(recursive: true));

    test('reports modified and untracked files since the checkpoint', () async {
      await firstWhere((l) => l.any((p) => p.name == 'gitproj' && p.path == work.path));
      final tree = Process.runSync('bash', [_script, 'create', work.path]).stdout.toString().trim();
      File('${work.path}/a.txt').writeAsStringSync('one\ntwo\nthree\n');
      File('${work.path}/n.txt').writeAsStringSync('x\n');

      final stats = await repo.numstat('gitproj', tree);

      expect(stats.map((s) => (s.path, s.added, s.deleted)), [('a.txt', 2, 0), ('n.txt', 1, 0)]);
    });

    test('unknown project or invalid checkpoint yields an empty list', () async {
      await firstWhere((l) => l.any((p) => p.name == 'gitproj'));
      expect(await repo.numstat('nope', 'abc'), isEmpty);
      expect(await repo.numstat('gitproj', 'deadbeef'), isEmpty);
    });
  });

  test('events run: planned tasks keep current.json metadata and the dev start checkpoint', () async {
    final run = _project(await loaded(), 'beta').cycle!.runs.single;
    final t = run.tasks.single;
    expect((t.complexity, t.risk, t.tier0), (Complexity.m, false, Tier.haiku));
    expect(t.description, 'Implementar o servico beta; criterio: testes do servico passam.');
    expect(t.checkpoint, 'aaaa111');
    expect(t.stage!.label, 'implementando');
  });
}
