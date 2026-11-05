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

      expect(p.adrs.map((a) => (a.id, a.status)), [('0001', 'accepted'), ('0002', '?')]);
      expect(p.adrs.last.error, contains('0002-bad.md'));
      expect(p.rules.single.name, 'app');
      expect(p.rules.single.summary, 'Resumo da rule.');
      expect(p.lessons, ['[a] uma', '[b] duas']);
      expect(p.routing.overrides, {'L:high': 'fable'});
    });

    test('duplicate ADR ids: the first file wins, the other gets an error', () async {
      _write('$projectDir/docs/adr/0003-a.md', '---\nid: "0003"\ntitle: A\nstatus: accepted\n---\n');
      _write('$projectDir/docs/adr/0003-b.md', '---\nid: "0003"\ntitle: B\nstatus: accepted\n---\n');

      final p = await repo.loadProject(project(path: projectDir));

      expect(p.adrs.map((a) => a.title), ['A', 'B']);
      expect(p.adrs.first.error, isNull);
      expect(p.adrs.last.error, contains('id duplicado'));
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

  group('loadAdr', () {
    const project = Project(name: 'proj', path: null);

    test('returns the body after the closing --- and null for an unknown id', () async {
      _write(
        '$projectDir/docs/adr/0001-x.md',
        '---\nid: "0001"\ntitle: X\nstatus: accepted\nsupersedes: [0000]\n---\n# X\n\ncorpo\n---\nfim\n',
      );
      final p = Project(name: 'proj', path: projectDir);

      final r = await repo.loadAdr(p, '0001');

      expect(r!.entry.title, 'X');
      expect(r.entry.supersedes, ['0000']);
      expect(r.body, '# X\n\ncorpo\n---\nfim\n');
      expect(await repo.loadAdr(p, '0042'), isNull);
    });

    test('an ADR without frontmatter is found by the filename digits with the raw body', () async {
      _write('$projectDir/docs/adr/0002-bad.md', 'sem frontmatter\nlinha');

      final r = await repo.loadAdr(Project(name: 'proj', path: projectDir), '0002');

      expect(r!.entry.status, '?');
      expect(r.entry.error, contains('0002-bad.md'));
      expect(r.body, 'sem frontmatter\nlinha');
    });

    test('duplicate id resolves to the first file', () async {
      _write('$projectDir/docs/adr/0003-a.md', '---\nid: "0003"\ntitle: A\nstatus: accepted\n---\nA');
      _write('$projectDir/docs/adr/0003-b.md', '---\nid: "0003"\ntitle: B\nstatus: accepted\n---\nB');

      final r = await repo.loadAdr(Project(name: 'proj', path: projectDir), '0003');

      expect((r!.entry.title, r.body), ('A', 'A'));
    });

    test('reads .gitmodules and exposes the submodule holding the ADRs', () async {
      _write(
        '$projectDir/.gitmodules',
        '[submodule "docs"]\n\tpath = docs\n\turl = git@github.com:acme/org-docs.git\n',
      );
      _write('$projectDir/docs/adr/0001-a.md', '---\nid: "0001"\ntitle: A\nstatus: accepted\n---\nA');
      _write('$home/stacks/s.json', '{"name":"s","adr_dir":"docs/adr"}');
      final p = Project(name: 'proj', path: projectDir, stack: 's');

      final inv = await repo.loadProject(p);

      expect((inv.adrSubmodule?.path, inv.adrSubmodule?.url), ('docs', 'git@github.com:acme/org-docs.git'));
    });

    test('missing, unrelated or oversized .gitmodules gives no submodule and no error', () async {
      final p = Project(name: 'proj', path: projectDir);
      expect((await repo.loadProject(p)).adrSubmodule, isNull);

      _write('$projectDir/.gitmodules', '[submodule "x"]\n\tpath = other\n\turl = u\n');
      expect((await repo.loadProject(p)).adrSubmodule, isNull);

      _write('$projectDir/.gitmodules', '[submodule "d"]\n\tpath = docs\n\turl = u\n${' ' * (300 * 1024)}');
      expect((await repo.loadProject(p)).adrSubmodule, isNull);
    });

    test('an ADR in free format is listed with a warning and its body omits the header', () async {
      _write(
        '$projectDir/docs/adr/0005-livre.md',
        '# ADR 0005 — Livre\n\n**Status:** proposta · **Data:** 2026-01-02\n\ncorpo\n',
      );

      final inv = await repo.loadProject(Project(name: 'proj', path: projectDir));
      final r = await repo.loadAdr(Project(name: 'proj', path: projectDir), '0005');

      expect((inv.adrs.single.title, inv.adrs.single.status), ('Livre', 'proposed'));
      expect(r!.entry.error, isNull);
      expect(r.body, 'corpo\n');
    });

    test('a project without path has no ADR', () async {
      expect(await repo.loadAdr(project, '0001'), isNull);
    });
  });
}
