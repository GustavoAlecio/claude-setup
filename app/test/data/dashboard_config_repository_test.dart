import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/dashboard_config_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileDashboardConfigRepository', () {
    late Directory tmp;
    late File file;
    late FileDashboardConfigRepository repo;

    Map<String, dynamic> read() => jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dashboard_config_');
      file = File('${tmp.path}/.dashboard.json');
      repo = FileDashboardConfigRepository(file.path);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('keeps original keys, values and order; new keys go last; 2-space indent; no .tmp left', () async {
      file.writeAsStringSync(
        jsonEncode({
          'zeta': {'nested': true},
          'cwds': {'a': '/x/a'},
          'paletteSkills': ['plan', 'fix'],
          'engineDir': '/e',
          'unknown': [1, 2],
        }),
      );

      await repo.update(createOrg('r10', ['/dev/r10']));

      final out = read();
      expect(out.keys, ['zeta', 'cwds', 'paletteSkills', 'engineDir', 'unknown', 'orgs', 'lastOrg']);
      expect(out['zeta'], {'nested': true});
      expect(out['cwds'], {'a': '/x/a'});
      expect(out['paletteSkills'], ['plan', 'fix']);
      expect(out['engineDir'], '/e');
      expect(out['unknown'], [1, 2]);
      expect(out['orgs'], [
        {
          'name': 'r10',
          'roots': ['/dev/r10'],
        },
      ]);
      expect(out['lastOrg'], 'r10');
      expect(file.readAsStringSync(), startsWith('{\n  "zeta": {\n    "nested": true\n  },'));
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('creates the file when it does not exist', () async {
      await repo.update(createOrg('r10', ['/dev/r10']));

      expect(read()['lastOrg'], 'r10');
    });

    test('re-reads the disk: a cwds change made after the app last read survives', () async {
      file.writeAsStringSync(
        jsonEncode({
          'cwds': {'a': '/x/a'},
          'orgs': [
            {
              'name': 'r10',
              'roots': ['/dev/r10'],
            },
          ],
        }),
      );
      await repo.update(setLastOrg('r10'));

      final external = read();
      (external['cwds'] as Map<String, dynamic>)['b'] = '/x/b';
      file.writeAsStringSync(jsonEncode(external));
      await repo.update(hideProject('a'));

      final out = read();
      expect(out['cwds'], {'a': '/x/a', 'b': '/x/b'});
      expect(out['hidden'], ['a']);
      expect(out['lastOrg'], 'r10');
    });

    test('invalid JSON on disk: throws and leaves the bytes untouched', () async {
      const broken = '{"cwds": {"a": "/x/a"},, ';
      file.writeAsStringSync(broken);
      final before = file.readAsBytesSync();

      await expectLater(
        repo.update(createOrg('r10', ['/dev/r10'])),
        throwsA(isA<ConfigWriteException>().having((e) => e.message, 'message', kInvalidDashboardConfig)),
      );

      expect(file.readAsBytesSync(), before);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('a rejected mutation surfaces as ConfigWriteException and writes nothing', () async {
      file.writeAsStringSync('{"cwds":{}}');

      await expectLater(repo.update(createOrg('Sem org', ['/dev/x'])), throwsA(isA<ConfigWriteException>()));

      expect(file.readAsStringSync(), '{"cwds":{}}');
    });

    test('a mutation that changes nothing does not write', () async {
      const compact = '{"hidden":["a"],"cwds":{}}';
      file.writeAsStringSync(compact);
      final stamp = DateTime(2020);
      file.setLastModifiedSync(stamp);

      await repo.update(hideProject('a'));

      expect(file.readAsStringSync(), compact);
      expect(file.lastModifiedSync(), stamp);
    });

    test('two concurrent writes are serialized without a lost update', () async {
      file.writeAsStringSync(
        jsonEncode({
          'orgs': [
            {
              'name': 'r10',
              'roots': ['/dev/r10'],
            },
          ],
        }),
      );

      await Future.wait([repo.update(hideProject('a')), repo.update(setLastOrg('r10'))]);

      final out = read();
      expect(out['hidden'], ['a']);
      expect(out['lastOrg'], 'r10');
    });

    test('a failed write does not block the next one', () async {
      file.writeAsStringSync('{}');

      await expectLater(repo.update(setLastOrg('nope')), throwsA(isA<ConfigWriteException>()));
      await repo.update(hideProject('a'));

      expect(read()['hidden'], ['a']);
    });
  });
}
