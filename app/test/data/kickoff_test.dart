import 'package:claude_flow/data/kickoff.dart';
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
    test('accepts numeric and keyed IDs', () {
      expect(normalizeCardId('#123'), '123');
      expect(normalizeCardId('lc-101'), 'LC-101');
      expect(normalizeCardId(' 42 '), '42');
      expect(normalizeCardId('AB2-7'), 'AB2-7');
    });

    test('rejects anything else', () {
      expect(normalizeCardId('abc'), isNull);
      expect(normalizeCardId(''), isNull);
      expect(normalizeCardId('#'), isNull);
      expect(normalizeCardId('2AB-1'), isNull);
      expect(normalizeCardId('LC-'), isNull);
      expect(normalizeCardId('12 3'), isNull);
    });
  });
}
