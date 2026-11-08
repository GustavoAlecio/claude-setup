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
}
