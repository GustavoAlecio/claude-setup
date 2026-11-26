import 'package:claude_flow/data/kickoff.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('kickoffCommand', () {
    test('with an ID it is the tracker form and ignores description and type', () {
      expect(kickoffCommand(id: '123', description: 'ignorada', type: KickoffType.bug), '/kickoff 123');
      expect(kickoffCommand(id: 'LC-101'), '/kickoff LC-101');
    });

    test('manual form carries the type flag on the first line', () {
      expect(kickoffCommand(description: 'algo'), '/kickoff --manual\n\nalgo');
      expect(kickoffCommand(description: 'algo', type: KickoffType.bug), '/kickoff --manual --bug\n\nalgo');
      expect(kickoffCommand(description: 'algo', type: KickoffType.feature), '/kickoff --manual --feature\n\nalgo');
    });

    test('multiline description with shell metacharacters goes in verbatim', () {
      const description = 'linha 1 com "aspas"\nlinha 2 com \\ barra e `crase`\nlinha 3 com \$(date) e \$HOME\n';
      final command = kickoffCommand(description: description, type: KickoffType.bug);
      expect(command, '/kickoff --manual --bug\n\n$description');
      expect(command.codeUnits, [...'/kickoff --manual --bug\n\n'.codeUnits, ...description.codeUnits]);
    });
  });

  group('startCommand', () {
    const ado = OrgTracker(kind: TrackerKind.ado, org: 'o', project: 'p');
    const jira = OrgTracker(kind: TrackerKind.jira, site: 's', project: 'LC', email: 'e');

    test('blank text is null', () {
      expect(startCommand('', ado), isNull);
      expect(startCommand('  \n\t ', null), isNull);
    });

    test('a lone card ID of the tracker goes by the tracker form', () {
      expect(startCommand('4821', ado), '/kickoff 4821');
      expect(startCommand(' #4821 ', ado), '/kickoff 4821');
      expect(startCommand('lc-101', jira), '/kickoff LC-101');
    });

    test('a phrase with the number in the middle is the manual form', () {
      expect(startCommand('corrigir o card 4821', ado), '/kickoff --manual\n\ncorrigir o card 4821');
    });

    test('without tracker a number is a description', () {
      expect(startCommand('4821', null), '/kickoff --manual\n\n4821');
    });

    test('an ID the tracker does not accept is a description', () {
      expect(startCommand('LC-101', ado), '/kickoff --manual\n\nLC-101');
    });

    test('manual description is trimmed and keeps inner line breaks', () {
      expect(startCommand('  linha 1\nlinha 2 \n', jira), '/kickoff --manual\n\nlinha 1\nlinha 2');
    });
  });

  group('normalizeCardId', () {
    const ado = OrgTracker(kind: TrackerKind.ado, org: 'o', project: 'p');
    const jira = OrgTracker(kind: TrackerKind.jira, site: 's', project: 'LC', email: 'e');
    const linear = OrgTracker(kind: TrackerKind.linear);

    test('ADO takes only numeric IDs', () {
      expect(normalizeCardId('#123', ado), '123');
      expect(normalizeCardId(' 42 ', ado), '42');
      expect(normalizeCardId('LC-101', ado), isNull);
    });

    test('Jira and Linear take keys; a number gets the project or team prefix', () {
      expect(normalizeCardId('lc-101', jira), 'LC-101');
      expect(normalizeCardId('AB2-7', jira), 'AB2-7');
      expect(normalizeCardId('101', jira), 'LC-101');
      expect(normalizeCardId('lc-9', linear), 'LC-9');
      expect(normalizeCardId('101', linear), isNull);
    });

    test('rejects anything else', () {
      for (final raw in ['abc', '', '#', '2AB-1', 'LC-', '12 3']) {
        expect(normalizeCardId(raw, jira), isNull, reason: raw);
        expect(normalizeCardId(raw, ado), isNull, reason: raw);
      }
    });
  });

  test('cardIdHint follows the tracker', () {
    expect(cardIdHint(const OrgTracker(kind: TrackerKind.ado)), '4821');
    expect(cardIdHint(const OrgTracker(kind: TrackerKind.jira, project: 'APP')), 'APP-101');
    expect(cardIdHint(const OrgTracker(kind: TrackerKind.linear)), 'LC-101');
  });

  group('skillLabel', () {
    test('known names use the fixed phrase', () {
      expect(skillLabel('fix', 'qualquer coisa'), 'Corrigir um bug sem abrir ciclo');
      expect(skillLabel('challenge-spec', ''), 'Desafiar a spec antes do plano');
    });

    test('strips the stage prefix and cuts at the first sentence', () {
      expect(
        skillLabel('foo', 'Etapa 2 do Fluxo Smart — gera plano técnico detalhado. Mais texto'),
        'Gera plano técnico detalhado',
      );
      expect(skillLabel('foo', 'Fluxo Review etapa 2 — gate local. X'), 'Gate local');
      expect(skillLabel('foo', 'etapa final do fluxo smart — fecha tudo'), 'Fecha tudo');
    });

    test('keeps inner dots and drops only the final one', () {
      expect(
        skillLabel('foo', 'Gera uma proposta (definida em company.json) em PDF.'),
        'Gera uma proposta (definida em company.json) em PDF',
      );
    });

    test('cuts at an em dash or a spaced hyphen', () {
      expect(skillLabel('foo', 'faz isso — e aquilo'), 'Faz isso');
      expect(skillLabel('foo', 'faz isso - e aquilo'), 'Faz isso');
      expect(skillLabel('foo', 'pr-status sem corte'), 'Pr-status sem corte');
    });

    test('long text is cut at a word within 60 characters and ends in an ellipsis', () {
      final description = List.filled(20, 'palavra').join(' ');
      expect(description.length, greaterThan(100));
      final label = skillLabel('foo', description);
      expect(label.length, lessThanOrEqualTo(60));
      expect(label.endsWith('…'), isTrue);
      expect(label, 'Palavra ${List.filled(6, 'palavra').join(' ')}…');
    });

    test('empty description is the name', () {
      expect(skillLabel('foo', ''), 'foo');
      expect(skillLabel('foo', '   '), 'foo');
    });
  });

  test('pendingLine', () {
    expect(pendingLine(0), 'nada esperando você');
    expect(pendingLine(1), '1 esperando você');
    expect(pendingLine(3), '3 esperando você');
  });
}
