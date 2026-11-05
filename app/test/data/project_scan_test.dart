import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/orgs.dart';
import 'package:claude_flow/data/project_scan.dart';
import 'package:flutter_test/flutter_test.dart';

bool _nodeMissing() {
  try {
    return Process.runSync('node', ['--version']).exitCode != 0;
  } on ProcessException {
    return true;
  }
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory(Directory.systemTemp.createTempSync('project_scan_').resolveSymbolicLinksSync()));

  tearDown(() => tmp.deleteSync(recursive: true));

  String mkdir(String rel) => (Directory('${tmp.path}/$rel')..createSync(recursive: true)).path;

  List<String>? paths(Map<String, List<ScanCandidate>> index, String name) => index[name]?.map((c) => c.path).toList();

  group('scanRoots', () {
    test('SKIP and depth match engine/cwd.mjs', () {
      final source = File('../engine/cwd.mjs').readAsStringSync();
      final skip = RegExp(r'const SKIP = new Set\(\[([^\]]*)\]\)').firstMatch(source)!.group(1)!;
      final names = RegExp(r'"([^"]+)"').allMatches(skip).map((m) => m.group(1)).toSet();
      final depth = RegExp(r'await scan\(root, name, (\d+), found\)').firstMatch(source)!.group(1);

      expect(names, kScanSkip);
      expect(int.parse(depth!), kScanDepth);
    });

    test('finds <root>/a/<name> and lists every candidate of a repeated name', () async {
      final single = mkdir('dev/a/solo');
      final first = mkdir('dev/a/twin');
      final second = mkdir('dev/b/c/twin');

      final index = await scanRoots(['${tmp.path}/dev/']);

      expect(paths(index, 'solo'), [single]);
      expect(paths(index, 'twin'), unorderedEquals([first, second]));
    });

    test('skips dot and SKIP dirs, stops at the engine depth and does not follow symlinks', () async {
      mkdir('dev/.hidden/dot');
      mkdir('dev/node_modules/dep');
      mkdir('dev/x/build/out');
      final deepest = mkdir('dev/1/2/3/four');
      mkdir('dev/1/2/3/4/five');
      final target = mkdir('elsewhere/linked');
      Link('${tmp.path}/dev/link').createSync('${tmp.path}/elsewhere');

      final index = await scanRoots(['${tmp.path}/dev']);

      expect(index.keys, isNot(contains(anyOf('dot', 'dep', 'out', 'five', 'link', 'linked'))));
      expect(paths(index, 'four'), [deepest]);
      expect(index.values.expand((v) => v).map((c) => c.path), isNot(contains(target)));
    });

    test('a dir under an ancestor with the same name is not a candidate, like the engine', () async {
      final outer = mkdir('dev/app');
      mkdir('dev/app/app');

      expect(paths(await scanRoots(['${tmp.path}/dev']), 'app'), [outer]);
    });

    test('missing roots are ignored', () async {
      final only = mkdir('dev/p');

      final index = await scanRoots(['${tmp.path}/missing', '${tmp.path}/dev']);

      expect(index.keys, ['p']);
      expect(paths(index, 'p'), [only]);
    });

    test('depth is relative to the scanned root and the shallowest candidate resolves the path', () async {
      final top = mkdir('dev/x');
      final copy = mkdir('dev/docs/repos/x');
      mkdir('dev/a/twin');
      mkdir('dev/b/twin');

      final index = await scanRoots(['${tmp.path}/dev']);

      expect({for (final c in index['x']!) c.path: c.depth}, {top: 0, copy: 2});
      expect(resolvePath(name: 'x', scanIndex: index), top);
      expect(resolvePath(name: 'twin', scanIndex: index), isNull);
    });
  });

  group('scanRoots repo-root rule (same trees as engine/test/cwd.test.mjs)', () {
    void gitDir(String rel) => mkdir('$rel/.git');
    void gitFile(String rel) => File('${mkdir(rel)}/.git').writeAsStringSync('gitdir: /tmp/elsewhere\n');

    test('a copy nested in another repo loses to the repo of the same name', () async {
      gitDir('dev/repoA');
      mkdir('dev/repoA/sub/proj');
      gitDir('dev/proj');

      final index = await scanRoots(['${tmp.path}/dev']);

      expect(paths(index, 'proj'), ['${tmp.path}/dev/proj']);
      expect(resolvePath(name: 'proj', scanIndex: index), '${tmp.path}/dev/proj');
    });

    test('a folder inside a repo that is not its root is not a candidate', () async {
      gitDir('dev/repoB');
      mkdir('dev/repoB/sub/nested');

      final index = await scanRoots(['${tmp.path}/dev']);

      expect(index['nested'], isNull);
      expect(resolvePath(name: 'nested', scanIndex: index), isNull);
    });

    test('a folder with no .git anywhere is still a candidate', () async {
      final plain = mkdir('dev/plain/loose');

      expect(paths(await scanRoots(['${tmp.path}/dev']), 'loose'), [plain]);
    });

    test('a scanned root with .git counts as an ancestor', () async {
      gitDir('dev');
      mkdir('dev/x');

      final index = await scanRoots(['${tmp.path}/dev']);

      expect(index['x'], isNull);
      expect(resolvePath(name: 'x', scanIndex: index), isNull);
    });

    test('.git as a file (worktree or submodule) inside another repo is a repo root', () async {
      gitDir('dev/repoA');
      gitFile('dev/repoA/x');

      final index = await scanRoots(['${tmp.path}/dev']);

      expect(paths(index, 'x'), ['${tmp.path}/dev/repoA/x']);
      expect(resolvePath(name: 'x', scanIndex: index), '${tmp.path}/dev/repoA/x');
    });

    test('.git as a symlink counts without being followed', () async {
      gitDir('dev/repoA');
      Link('${mkdir('dev/repoA/linked')}/.git').createSync('${tmp.path}/missing');

      expect(paths(await scanRoots(['${tmp.path}/dev']), 'linked'), ['${tmp.path}/dev/repoA/linked']);
    });

    test('a refused candidate does not stop the descent nor block the name below it', () async {
      gitDir('dev/repoD');
      mkdir('dev/repoD/deep');
      gitDir('dev/repoD/deep/deep');

      expect(paths(await scanRoots(['${tmp.path}/dev']), 'deep'), ['${tmp.path}/dev/repoD/deep/deep']);
    });

    test('app and engine resolve the same paths on the same tree', () async {
      final mixed = '${tmp.path}/mixed';
      final gitRoot = '${tmp.path}/gitroot';
      gitDir('mixed/repoA');
      mkdir('mixed/repoA/sub/proj');
      gitDir('mixed/proj');
      mkdir('mixed/repoA/sub/nested');
      mkdir('mixed/plain/loose');
      gitFile('mixed/repoA/wt');
      gitDir('mixed/repoD');
      mkdir('mixed/repoD/deep');
      gitDir('mixed/repoD/deep/deep');
      mkdir('mixed/a/twin');
      mkdir('mixed/b/twin');
      gitDir('gitroot');
      mkdir('gitroot/inside');
      const names = ['proj', 'nested', 'loose', 'wt', 'deep', 'twin', 'inside'];

      final index = await scanRoots([mixed, gitRoot]);
      final app = {for (final n in names) n: resolvePath(name: n, scanIndex: index)};

      final cwd = File('../engine/cwd.mjs').absolute.uri;
      final script =
          'const {resolveCwd} = await import(${jsonEncode('$cwd')});'
          'const out = {};'
          'for (const n of ${jsonEncode(names)}) out[n] = (await resolveCwd(n, null)).cwd;'
          'console.log(JSON.stringify(out));';
      final result = Process.runSync(
        'node',
        ['--input-type=module', '-e', script],
        environment: {'CLAUDE_HOME': mkdir('home'), 'CLAUDE_WEB_SCAN_ROOTS': '$mixed:$gitRoot'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');

      expect(jsonDecode(result.stdout as String), app);
      expect(app, {
        'proj': '$mixed/proj',
        'nested': null,
        'loose': '$mixed/plain/loose',
        'wt': '$mixed/repoA/wt',
        'deep': '$mixed/repoD/deep/deep',
        'twin': null,
        'inside': null,
      });
    }, skip: _nodeMissing() ? 'node não está no PATH' : false);

    test('an accepted repo still blocks its own name below it', () async {
      gitDir('dev/app');
      gitDir('dev/app/app');

      expect(paths(await scanRoots(['${tmp.path}/dev']), 'app'), ['${tmp.path}/dev/app']);
    });
  });

  group('listSubdirectories', () {
    test('immediate non-dot folders, sorted; missing base → empty', () async {
      mkdir('dev/r10/inner');
      mkdir('dev/abm');
      mkdir('dev/.cache');
      File('${tmp.path}/dev/file.txt').writeAsStringSync('x');

      expect(await listSubdirectories('${tmp.path}/dev'), ['${tmp.path}/dev/abm', '${tmp.path}/dev/r10']);
      expect(await listSubdirectories('${tmp.path}/nope'), isEmpty);
    });
  });

  group('inspectDirectory', () {
    void git(String dir, List<String> args) {
      final r = Process.runSync('git', ['-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t', ...args]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    String repo(String rel, {String? remote}) {
      final dir = mkdir(rel);
      git(dir, ['init', '-q']);
      if (remote != null) git(dir, ['remote', 'add', 'origin', remote]);
      return dir;
    }

    bool none(String _) => false;

    test('subdirectory resolves to the git root and the remote name', () async {
      final root = repo('dev/local_name', remote: 'git@host:org/My_Repo.git');
      final sub = mkdir('dev/local_name/app/lib');

      final dir = await inspectDirectory(sub, workflowExists: none);

      expect(dir.path, root);
      expect(dir.name, 'My-Repo');
      expect(dir.divergence, isNull);
    });

    test('without remote the root basename is used with _ → -', () async {
      final root = repo('dev/my_tool');

      final dir = await inspectDirectory('$root/', workflowExists: none);

      expect((dir.path, dir.name), (root, 'my-tool'));
    });

    test('outside git the folder itself names the project', () async {
      final plain = mkdir('plain_dir');

      final dir = await inspectDirectory(plain, workflowExists: none);

      expect((dir.path, dir.name), (plain, 'plain-dir'));
    });

    test('worktree without remote takes the main repo basename', () async {
      final main = repo('dev/main_repo');
      File('$main/a.txt').writeAsStringSync('a');
      git(main, ['add', '.']);
      git(main, ['commit', '-qm', 'init']);
      final wt = '${tmp.path}/dev/wt-checkout';
      git(main, ['worktree', 'add', '-q', wt]);

      final dir = await inspectDirectory(wt, workflowExists: none);

      expect((dir.path, dir.name), (wt, 'main-repo'));
    });

    test('an existing workflow dir under the raw basename wins over the remote name', () async {
      final root = repo('dev/old_name', remote: 'https://host/org/new-name.git');

      final dir = await inspectDirectory(root, workflowExists: (n) => n == 'old_name');

      expect(dir.name, 'old_name');
      expect(dir.divergence, contains('workflow existente em old_name'));
    });
  });
}
