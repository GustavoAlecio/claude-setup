import 'dart:io';

import 'package:claude_flow/data/project_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late String home;
  final script = File('../bin/get-project.sh').absolute.path;

  setUp(() {
    tmp = Directory(Directory.systemTemp.createTempSync('project_name_').resolveSymbolicLinksSync());
    home = '${tmp.path}/home';
    Directory('$home/workflow').createSync(recursive: true);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String mkdir(String rel) => (Directory('${tmp.path}/$rel')..createSync(recursive: true)).path;

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

  void workflow(String name) => Directory('$home/workflow/$name').createSync(recursive: true);

  Future<void> expectParity(String dir, String expected) async {
    final r = await Process.run('bash', [script], workingDirectory: dir, environment: {'CLAUDE_HOME': home});
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final dart = await inspectDirectory(dir, workflowExists: (n) => Directory('$home/workflow/$n').existsSync());

    expect((r.stdout as String).trim(), expected);
    expect(dart.name, expected);
    expect((r.stderr as String).trim(), dart.divergence ?? '');
  }

  group('projectNameFor matches bin/get-project.sh', () {
    test('remote name from a subdirectory', () async {
      repo('dev/local_name', remote: 'git@host:org/My_Repo.git');

      await expectParity(mkdir('dev/local_name/app/lib'), 'My-Repo');
    });

    test('no remote → root basename with _ → -', () async {
      await expectParity(repo('dev/my_tool'), 'my-tool');
    });

    test('worktree without remote → main repo basename', () async {
      final main = repo('dev/main_repo');
      File('$main/a.txt').writeAsStringSync('a');
      git(main, ['add', '.']);
      git(main, ['commit', '-qm', 'init']);
      final wt = '${tmp.path}/dev/wt-checkout';
      git(main, ['worktree', 'add', '-q', wt]);

      await expectParity(wt, 'main-repo');
    });

    test('outside git → folder basename', () async {
      await expectParity(mkdir('plain_dir'), 'plain-dir');
    });

    test('divergence: workflow under the raw basename wins over the remote name', () async {
      final root = repo('dev/old_name', remote: 'https://host/org/new-name.git');
      workflow('old_name');

      await expectParity(root, 'old_name');
    });

    test('divergence with _ and no remote keeps the raw basename', () async {
      final root = repo('dev/my_tool');
      workflow('my_tool');

      await expectParity(root, 'my_tool');
    });

    test('no divergence when the remote name already has a workflow', () async {
      final root = repo('dev/old_name', remote: 'https://host/org/new-name.git');
      workflow('old_name');
      workflow('new-name');

      await expectParity(root, 'new-name');
    });
  });
}
