import 'dart:io';

import 'package:claude_flow/data/docs_repository.dart';
import 'package:claude_flow/data/file_docs_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void _write(String path, String content) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}

void _writeBytes(String path, int size) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(List.filled(size, 0x61));
}

void main() {
  late Directory tmp;
  late String root;
  late String proj;
  late FileDocsRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('docs_repo_');
    root = '${tmp.path}/workflow';
    proj = '$root/demo';
    Directory(proj).createSync(recursive: true);
    repo = FileDocsRepository(root);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('list', () {
    test('groups root artifacts alphabetically and details newest first, ignoring hidden', () async {
      _write('$proj/tasks.md', 't');
      _write('$proj/plan.md', 'p');
      _write('$proj/spec.md', 'sss');
      _write('$proj/.draft.md', 'x');
      _write('$proj/current.json', '{}');
      _write('$proj/notes.txt', 'x');
      Directory('$proj/dir.md').createSync();
      _write('$proj/details/2026-03-10-a.md', 'a');
      _write('$proj/details/2026-03-12-b.md', 'b');
      _write('$proj/details/.hidden.md', 'x');
      _write('$proj/details/nested/2026-04-01-c.md', 'x');
      _write('$proj/.hidden/spec.md', 'x');

      final listing = await repo.list('demo');

      expect(listing.artifacts.map((e) => e.rel), ['plan.md', 'spec.md', 'tasks.md']);
      expect(listing.details.map((e) => e.rel), ['details/2026-03-12-b.md', 'details/2026-03-10-a.md']);
      final spec = listing.artifacts[1];
      expect(spec.size, 3);
      expect(spec.modified, File('$proj/spec.md').statSync().modified);
    });

    test('review IDs come from exact PR-<n>.md with only their exact siblings', () async {
      for (final name in [
        'PR-9.md',
        'PR-157.md',
        'PR-157.diff',
        'PR-157.comments.json',
        'PR-157.meta.json',
        'PR-157.full.md',
        'PR-157.scoped.diff',
        'PR-157.txt',
        'PR-1.full.md',
        'PR-2.diff',
        'PR-07.md',
        '.PR-3.md',
      ]) {
        _write('$proj/reviews/$name', name);
      }

      final reviews = (await repo.list('demo')).reviews;

      expect(reviews.map((r) => r.id), ['PR-157', 'PR-9']);
      final pr157 = reviews.first;
      expect(pr157.report.rel, 'reviews/PR-157.md');
      expect(pr157.diff?.rel, 'reviews/PR-157.diff');
      expect(pr157.comments?.rel, 'reviews/PR-157.comments.json');
      expect(pr157.meta?.rel, 'reviews/PR-157.meta.json');
      final pr9 = reviews.last;
      expect([pr9.diff, pr9.comments, pr9.meta], [null, null, null]);
    });

    test('missing project dir or invalid project name is empty', () async {
      for (final project in ['nope', '..', '.hidden', 'a/b', '']) {
        final listing = await repo.list(project);
        expect([listing.artifacts, listing.details, listing.reviews], [isEmpty, isEmpty, isEmpty], reason: project);
      }
    });

    test('skips symlinks that resolve outside the project', () async {
      _write('${tmp.path}/outside.md', 'secret');
      Link('$proj/leak.md').createSync('${tmp.path}/outside.md');
      _write('$proj/real.md', 'r');
      Link('$proj/alias.md').createSync('$proj/real.md');

      final listing = await repo.list('demo');

      expect(listing.artifacts.map((e) => e.rel), ['alias.md', 'real.md']);
    });
  });

  group('read', () {
    test('reads a contained file', () async {
      _write('$proj/details/2026-03-10-a.md', '# título');

      final doc = await repo.read('demo', 'details/2026-03-10-a.md');

      expect(doc.text, '# título');
      expect(doc.error, isNull);
      expect(doc.tooLarge, isFalse);
    });

    test('rejects traversal, absolute paths, hidden segments and other extensions', () async {
      _write('$root/x.md', 'parent');
      _write('$proj/.secret/a.md', 'hidden');
      _write('$proj/a.txt', 'txt');
      _write('$proj/a.md', 'ok');

      for (final rel in ['../x.md', 'details/../../x.md', '$root/x.md', '/etc/hosts', '.secret/a.md', 'a.txt', '']) {
        final doc = await repo.read('demo', rel);
        expect(doc.text, isNull, reason: rel);
        expect(doc.error, isNotNull, reason: rel);
      }
      expect((await repo.read('../workflow', 'demo/a.md')).text, isNull);
    });

    test('a missing file is "não encontrado", not "fora do diretório"', () async {
      _write('$proj/gone.md', 'x');
      File('$proj/gone.md').deleteSync();

      final doc = await repo.read('demo', 'gone.md');

      expect(doc.text, isNull);
      expect(doc.error, contains('não encontrado'));
    });

    test('rejects a file symlink that leaves the project dir', () async {
      _write('${tmp.path}/outside.md', 'secret');
      Link('$proj/leak.md').createSync('${tmp.path}/outside.md');
      Directory('$proj/reviews').createSync();
      Link('$proj/reviews/PR-1.md').createSync('${tmp.path}/outside.md');

      expect((await repo.read('demo', 'leak.md')).text, isNull);
      expect((await repo.read('demo', 'reviews/PR-1.md')).text, isNull);
      expect((await repo.read('demo', 'leak.md')).error, contains('fora do diretório'));
    });

    test('works when the workflow root itself is reached through a symlink', () async {
      _write('$proj/spec.md', 'via link');
      Link('${tmp.path}/alias').createSync(root);
      final linked = FileDocsRepository('${tmp.path}/alias/');

      expect((await linked.read('demo', 'spec.md')).text, 'via link');
      expect((await linked.list('demo')).artifacts.map((e) => e.rel), ['spec.md']);
    });

    test('exactly the limit is read; one more byte is too large', () async {
      _writeBytes('$proj/at.diff', kDocSizeLimit);
      _writeBytes('$proj/over.diff', kDocSizeLimit + 1);

      final at = await repo.read('demo', 'at.diff');
      final over = await repo.read('demo', 'over.diff');

      expect(at.text?.length, kDocSizeLimit);
      expect(over.tooLarge, isTrue);
      expect(over.text, isNull);
    });

    test('malformed UTF-8 decodes without throwing', () async {
      File('$proj/bad.md').writeAsBytesSync([0x61, 0xff, 0x62]);

      expect((await repo.read('demo', 'bad.md')).text, 'a�b');
    });
  });

  group('open', () {
    late List<String> calls;
    late FileDocsRepository opener;

    setUp(() {
      calls = [];
      opener = FileDocsRepository(
        root,
        run: (executable, arguments) async {
          calls.add([executable, ...arguments].join(' '));
          return ProcessResult(0, 0, '', '');
        },
      );
    });

    test('opens http, https and mailto with the macOS open command', () async {
      await opener.open(Uri.parse('https://example.com/a?b=1'));
      await opener.open(Uri.parse('http://example.com'));
      await opener.open(Uri.parse('mailto:dev@example.com'));

      expect(calls, ['open https://example.com/a?b=1', 'open http://example.com', 'open mailto:dev@example.com']);
    });

    test('refuses file:, absolute paths, javascript:, anchors and relative links', () async {
      for (final link in ['file:///x', '/Applications/X.app', 'javascript:x', '#a', 'details/a.md', 'https:///x']) {
        await opener.open(Uri.parse(link));
      }

      expect(calls, isEmpty);
    });
  });
}
