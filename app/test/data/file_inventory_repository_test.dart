import 'dart:io';

import 'package:claude_flow/data/file_inventory_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void _write(String path, String content) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}

void main() {
  late Directory tmp;
  late String home;
  late String projectDir;
  late FileInventoryRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('inventory_repo_');
    home = '${tmp.path}/claude';
    projectDir = '${tmp.path}/proj';
    repo = FileInventoryRepository(home);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('loadInventory', () {
    test('reads skills, following symlinks and ignoring dirs without SKILL.md', () async {
      _write('$home/skills/plan/SKILL.md', '---\nname: plan\ndescription: Planeja. Muito.\nmodel: opus\n---\nbody');
      _write('$home/skills/empty/README.md', 'x');
      _write('${tmp.path}/shared/linked/SKILL.md', '---\ndescription: via link\n---\n');
      Directory('$home/skills').createSync(recursive: true);
      Link('$home/skills/linked').createSync('${tmp.path}/shared/linked');
      _write('$home/skills/broken/SKILL.md', '---\nname: "aberto\n---\n');

      final inv = await repo.loadInventory();

      expect(inv.skills.map((s) => s.name), ['broken', 'linked', 'plan']);
      final plan = inv.skills.last;
      expect(plan.model, 'opus');
      expect(plan.description, 'Planeja. Muito.');
      expect(inv.skills[1].description, 'via link');
      expect(inv.skills.first.error, contains('SKILL.md'));
    });

    test('reads agents, workflows, stacks and the ladder', () async {
      _write('$home/agents/dev.md', '---\ndescription: Dev\ntools: Read, Grep\n---\n');
      _write('$home/agents/INDEX.txt', 'ignored');
      _write(
        '$home/workflows/smart-implement.js',
        "export const meta = { name: 'smart-implement', description: 'x', phases: [{ title: 'G0' }] }\n"
            "const LADDER = ['a', 'b']\nconst TIER0 = { S: 'a' }\nconst BLOCKING = ['major']\n",
      );
      _write('$home/workflows/bad.js', 'export const meta = { description: `t` }');
      _write('$home/stacks/flutter.json', '{"name":"flutter","g1_reviewers":["r"],"g2_agent":"qa","adr_dir":"adrs"}');
      _write('$home/stacks/broken.json', '{');

      final inv = await repo.loadInventory();

      expect(inv.claudeHome, home);
      expect(inv.agents.single.tools, ['Read', 'Grep']);
      expect(inv.workflows.map((w) => w.meta.name), ['bad', 'smart-implement']);
      expect(inv.workflows.first.meta.error, isNotNull);
      expect(inv.workflows.last.meta.phases.single.title, 'G0');
      expect(inv.stacks.single.g2Agent, 'qa');
      expect(inv.stacks.single.adrDir, 'adrs');
      expect(inv.stacks.single.rulesDir, '.claude/rules');
      expect(inv.ladder.tiers, ['a', 'b']);
      expect(inv.ladder.blocking, ['major']);
    });

    test('an empty home yields empty lists and a ladder error', () async {
      final inv = await repo.loadInventory();

      expect(inv.skills, isEmpty);
      expect(inv.agents, isEmpty);
      expect(inv.workflows, isEmpty);
      expect(inv.stacks, isEmpty);
      expect(inv.ladder.error, isNotNull);
    });
  });

  group('loadProject', () {
    Project project({String? path, String? stack}) => Project(name: 'proj', path: path, stack: stack);

    test('reads rules, ADRs (INDEX ignored), lessons and routing with the default dirs', () async {
      _write('$projectDir/docs/adr/INDEX.md', '# Index\n');
      _write('$projectDir/docs/adr/0001-x.md', '---\nid: "0001"\ntitle: X\nstatus: accepted\n---\n');
      _write('$projectDir/docs/adr/0002-bad.md', 'sem frontmatter');
      _write('$projectDir/.claude/rules/app.md', '---\npaths: ["app/**"]\n---\n\n# Título\n\nResumo da rule.\n');
      _write('$home/projects/proj/lessons.md', '# Lessons\n\n- [a] uma\n- [b] duas\n');
      _write('$home/projects/proj/routing.json', '{"overrides":{"L:high":{"tier0":"fable"}},"bands":[]}');

      final p = await repo.loadProject(project(path: projectDir));

      expect(p.adrs.map((a) => a.id), ['0001', '']);
      expect(p.adrs.last.error, contains('0002-bad.md'));
      expect(p.rules.single.name, 'app');
      expect(p.rules.single.summary, 'Resumo da rule.');
      expect(p.lessons, ['[a] uma', '[b] duas']);
      expect(p.routing.overrides, {'L:high': 'fable'});
    });

    test('uses rules_dir and adr_dir from the detected stack', () async {
      _write('$home/stacks/flutter.json', '{"name":"flutter","rules_dir":"r","adr_dir":"a"}');
      _write('$projectDir/a/0001-x.md', '---\nid: "0001"\ntitle: X\nstatus: accepted\n---\n');
      _write('$projectDir/r/one.md', '# One\n\nPrimeira.\n');
      _write('$projectDir/docs/adr/0009-ignored.md', '---\nid: "0009"\ntitle: Z\nstatus: x\n---\n');

      final p = await repo.loadProject(project(path: projectDir, stack: 'flutter'));

      expect(p.adrs.single.id, '0001');
      expect(p.rules.single.summary, 'Primeira.');
    });

    test('a project without path only gets lessons and routing; missing files are empty', () async {
      _write('$projectDir/docs/adr/0001-x.md', '---\nid: "0001"\ntitle: X\nstatus: accepted\n---\n');
      _write('$home/projects/proj/lessons.md', '- [a] uma\n');

      final p = await repo.loadProject(project());

      expect(p.adrs, isEmpty);
      expect(p.rules, isEmpty);
      expect(p.lessons, ['[a] uma']);
      expect(p.routing.bands, isEmpty);
      expect(p.routing.error, isNull);
    });

    test('invalid routing.json surfaces as an error without throwing', () async {
      _write('$home/projects/proj/routing.json', 'not json');

      final p = await repo.loadProject(project());

      expect(p.routing.error, isNotNull);
    });
  });
}
