import 'dart:io';

import 'package:claude_flow/data/inventory_parser.dart';
import 'package:flutter_test/flutter_test.dart';

String workflow(String name) => File('../workflows/$name.js').readAsStringSync();

void main() {
  group('parseFrontmatter', () {
    test('(a) escalar simples e (d) chave desconhecida ignorada', () {
      final r = parseFrontmatter('---\nname: foo\nfuture-key: {a: b}\nmodel: opus\n---\ncorpo');
      expect(r.error, isNull);
      expect(r.fields, {'name': 'foo', 'model': 'opus'});
    });

    test('(b) aspas duplas com : e \\" e aspas simples com \'\'', () {
      final r = parseFrontmatter('---\ndescription: "a: b \\"c\\""\ntitle: \'t\'\'s: x\'\n---\n');
      expect(r.error, isNull);
      expect(r.fields['description'], 'a: b "c"');
      expect(r.fields['title'], "t's: x");
    });

    test('(c) >- vira uma linha sem o indicador; | preserva quebras', () {
      final r = parseFrontmatter(
        '---\ndescription: >-\n  linha um\n  linha dois\nname: x\nwhenToUse: |\n  a\n  b\n---\n',
      );
      expect(r.error, isNull);
      expect(r.fields['description'], 'linha um linha dois');
      expect(r.fields['name'], 'x');
      expect(r.fields.containsKey('whenToUse'), isFalse);

      final pipe = parseFrontmatter('---\ndescription: |-\n  a\n   b\n---\n');
      expect(pipe.fields['description'], 'a\n b');
    });

    test('(e) tools como string separada por vírgula e como lista', () {
      expect(parseFrontmatter('---\ntools: Read, Grep\n---\n').fields['tools'], ['Read', 'Grep']);
      expect(parseFrontmatter('---\ntools: [Read, "Bash"]\n---\n').fields['tools'], ['Read', 'Bash']);
    });

    test('sem frontmatter devolve vazio sem erro', () {
      final r = parseFrontmatter('# só corpo');
      expect(r.error, isNull);
      expect(r.fields, isEmpty);
    });

    test('malformado vira error sem lançar', () {
      for (final raw in [
        '---\nname: foo\n',
        '---\nname: "aberto\n---\n',
        '---\nlinha solta\n---\n',
        '---\ndescription:\n  multilinha plana\n---\n',
        '---\nname: "a" b\n---\n',
      ]) {
        expect(parseFrontmatter(raw).error, isNotNull, reason: raw);
      }
    });
  });

  group('parseInventoryItem', () {
    test('usa o nome do arquivo no erro e continua com fallbackName', () {
      final item = parseInventoryItem('---\nname: "x\n---\n', path: '/h/skills/foo/SKILL.md', fallbackName: 'foo');
      expect(item.name, 'foo');
      expect(item.error, contains('SKILL.md'));
    });

    test('monta item completo', () {
      final item = parseInventoryItem(
        '---\nname: Agente\ndescription: >-\n  faz x\nmodel: sonnet\ntools: Read, Grep\n---\n',
        path: '/h/agents/a.md',
        fallbackName: 'a',
      );
      expect(item.error, isNull);
      expect(item.name, 'Agente');
      expect(item.description, 'faz x');
      expect(item.model, 'sonnet');
      expect(item.tools, ['Read', 'Grep']);
    });
  });

  group('parseWorkflowMeta', () {
    test('lê 5/3/3 phases com títulos exatos dos workflows do repo', () {
      final impl = parseWorkflowMeta(workflow('smart-implement'));
      expect(impl.error, isNull);
      expect(impl.name, 'smart-implement');
      expect(impl.phases.map((p) => p.title), ['Implement', 'G0', 'G1', 'Ops', 'Diagnose']);
      expect(impl.phases.first.detail, 'dev-implementer no tier corrente');

      final verify = parseWorkflowMeta(workflow('smart-verify'));
      expect(verify.error, isNull);
      expect(verify.phases.map((p) => p.title), ['G1', 'G2', 'Reentry']);

      final tot = parseWorkflowMeta(workflow('tot-plan'));
      expect(tot.error, isNull);
      expect(tot.phases.map((p) => p.title), ['Branch', 'Judge', 'Synthesize']);
    });

    test('chave sem aspas, aspas simples, vírgula sobrando e campo desconhecido', () {
      final m = parseWorkflowMeta(
        "export const meta = { name: 'a', extra: [1, {x: true}], 'description': \"d\",\n"
        "  phases: [{ title: 'P', detail: 'x', },], }\nconst A = 1",
      );
      expect(m.error, isNull);
      expect(m.name, 'a');
      expect(m.description, 'd');
      expect(m.phases.single.title, 'P');
    });

    test('template string, spread e identificador viram erro', () {
      for (final lit in ['{ name: `x` }', '{ ...base }', '{ name: foo }', '{ name: "a" + "b" }', '{ name: "a"']) {
        final m = parseWorkflowMeta('export const meta = $lit', fallbackName: 'w');
        expect(m.error, isNotNull, reason: lit);
        expect(m.name, 'w');
      }
    });

    test('sem meta', () {
      expect(parseWorkflowMeta('const x = 1').error, isNotNull);
    });
  });

  group('parseLadder', () {
    test('lê LADDER, TIER0 e BLOCKING de smart-implement.js', () {
      final l = parseLadder(workflow('smart-implement'));
      expect(l.error, isNull);
      expect(l.tiers, ['haiku', 'sonnet', 'opus', 'fable']);
      expect(l.tier0, {'S': 'haiku', 'M': 'sonnet', 'L': 'opus'});
      expect(l.blocking, ['critical', 'major']);
    });

    test('constante multilinha não lança e lê os três literais', () {
      final l = parseLadder(
        'const LADDER = [\n  "a",\n  "b",\n]\nconst TIER0 = {\n  S: "a",\n}\nconst BLOCKING = [\n"x"\n];\n',
      );
      expect(l.error, isNull);
      expect(l.tiers, ['a', 'b']);
      expect(l.tier0, {'S': 'a'});
      expect(l.blocking, ['x']);
    });

    test('escape \\u inválido vira error sem exceção', () {
      final l = parseLadder("const LADDER = ['\\u-001']\nconst TIER0 = {}\nconst BLOCKING = []\n");
      expect(l.error, contains('LADDER'));
      expect(parseWorkflowMeta("export const meta = {name: '\\u-001'}", fallbackName: 'f').error, isNotNull);
      expect(parseWorkflowMeta("export const meta = {name: '\\u12'}", fallbackName: 'f').error, isNotNull);
    });

    test('ausente ou malformado vira error', () {
      expect(parseLadder('const LADDER = ["a"]\n').error, contains('TIER0'));
      expect(parseLadder('const LADDER = [`a`]\nconst TIER0 = {}\nconst BLOCKING = []\n').error, contains('LADDER'));
    });
  });

  group('parseStack', () {
    test('lê campos e aplica os defaults só no construtor', () {
      final s = parseStack('{"name": "flutter", "g1_reviewers": ["a", 1], "g2_agent": "qa"}', fallbackName: 'x');
      expect(s!.name, 'flutter');
      expect(s.g1Reviewers, ['a']);
      expect(s.g2Agent, 'qa');
      expect((s.rulesDir, s.adrDir), ('.claude/rules', 'docs/adr'));
    });

    test('nome cai no fallback e dirs customizados valem', () {
      final s = parseStack('{"rules_dir": "r", "adr_dir": "a"}', fallbackName: 'file');
      expect((s!.name, s.rulesDir, s.adrDir), ('file', 'r', 'a'));
    });

    test('JSON inválido ou não objeto vira null', () {
      expect(parseStack('{', fallbackName: 'x'), isNull);
      expect(parseStack('[]', fallbackName: 'x'), isNull);
    });
  });

  group('ADR, rule, lessons', () {
    test('parseAdr', () {
      final a = parseAdr(
        '---\nid: 0007\ntitle: Engine Node\nstatus: accepted\naffects: ["a/**"]\n---\n# x',
        path: '/d/0007-x.md',
      );
      expect(a.error, isNull);
      expect((a.id, a.title, a.status), ('0007', 'Engine Node', 'accepted'));

      final bad = parseAdr('---\nid: 0001\n---\n', path: '/d/0001-y.md');
      expect(bad.error, contains('0001-y.md'));
    });

    test('parseRuleSummary pula frontmatter e título', () {
      final r = parseRuleSummary(
        '---\npaths: ["app/**"]\n---\n\n# Convenções\n\nResumo aqui.\nOutra.\n',
        path: '/r/flutter-app.md',
      );
      expect(r.error, isNull);
      expect(r.name, 'flutter-app');
      expect(r.summary, 'Resumo aqui.');
      expect(parseRuleSummary('# T\n', path: '/r/x.md').summary, '');
      expect(parseRuleSummary('---\nsem fim', path: '/r/x.md').error, isNotNull);
    });

    test('parseLessons só pega linhas "- "', () {
      expect(parseLessons('# Lessons\n\n- [a] um\n  continuação\n- [b] dois\n-sem espaço\n'), ['[a] um', '[b] dois']);
    });
  });

  group('parseRouting', () {
    test('sem bands', () {
      final r = parseRouting('{"overrides": {"M:low": {"tier0": "haiku"}}}');
      expect(r.error, isNull);
      expect(r.bands, isEmpty);
      expect(r.overrides, {'M:low': 'haiku'});
    });

    test('com bands', () {
      final r = parseRouting('''{"overrides": {}, "extra": 1, "bands": [
        {"complexity": "M", "risk": "low", "n": 4, "pass_tier0": 3, "escalated": 1, "blocked": 0,
         "attempts_per_task": 1.5, "final_tiers": {"sonnet": 3, "opus": 1}}]}''');
      expect(r.error, isNull);
      final b = r.bands.single;
      expect((b.complexity, b.risk, b.n, b.passTier0, b.escalated, b.blocked), ('M', 'low', 4, 3, 1, 0));
      expect(b.attemptsPerTask, 1.5);
      expect(b.finalTiers, {'sonnet': 3, 'opus': 1});
    });

    test('inválido vira error sem lançar', () {
      expect(parseRouting('{').error, isNotNull);
      expect(parseRouting('[]').error, isNotNull);
      expect(parseRouting('{"bands": [{"complexity": 1}]}').error, isNotNull);
    });
  });

  group('firstSentence', () {
    test('corta no primeiro ". " seguido de maiúscula', () {
      expect(firstSentence('Faz isto. Depois aquilo.'), 'Faz isto.');
      expect(firstSentence('Sem ponto final'), 'Sem ponto final');
      expect(firstSentence('Linha um\nlinha dois. outra minúscula'), 'Linha um linha dois. outra minúscula');
    });

    test('não corta em "ex. LC-101" nem dentro de parênteses', () {
      const d = 'Pega uma issue do Linear pela key (ex. LC-101), entende a regra. Depois posta.';
      expect(firstSentence(d), 'Pega uma issue do Linear pela key (ex. LC-101), entende a regra.');
      expect(firstSentence('Usa a key, ex. LC-101, e segue'), 'Usa a key, ex. LC-101, e segue');
    });
  });
}
