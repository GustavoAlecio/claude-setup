import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/docs_models.dart';
import 'package:claude_flow/data/docs_parser.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _diff = '''diff --git a/lib/a.dart b/lib/a.dart
index 111..222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,4 @@
 one
-two
+TWO
+extra
 three
@@ -10,2 +11,2 @@ fn
 ten
-old
\\ No newline at end of file
+new
\\ No newline at end of file
diff --git a/lib/b.dart b/lib/b.dart
--- a/lib/b.dart
+++ b/lib/b.dart
@@ -5 +5 @@
-x
+y
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+hello
+world
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-bye
-now
diff --git a/old/name.dart b/new/name.dart
similarity index 100%
rename from old/name.dart
rename to new/name.dart
diff --git a/img.png b/img.png
new file mode 100644
Binary files /dev/null and b/img.png differ
diff --git a/run.sh b/run.sh
old mode 100644
new mode 100755
''';

/// One file whose single hunk starts at old and new line [start] with [body] (unified diff lines with their prefix).
String _file(String path, List<String> body, {int start = 1}) =>
    'diff --git a/$path b/$path\n--- a/$path\n+++ b/$path\n@@ -$start +$start @@\n${body.join('\n')}\n';

List<String> _context(int from, int to) => [for (var i = from; i <= to; i++) ' l$i'];

List<List<String>> _texts(DiffExcerpt e) => [
  for (final b in e.blocks) [for (final l in b) l.text],
];

ReviewComment _c(String path, int? line, {String sev = 'major', String body = 'b'}) =>
    ReviewComment(path: path, line: line, severity: sev, agent: 'ag', body: body);

void main() {
  group('parseUnifiedDiff', () {
    final files = parseUnifiedDiff(_diff);

    test('lists files with paths', () {
      expect(files.map((f) => f.path), [
        'lib/a.dart',
        'lib/b.dart',
        'new.txt',
        'gone.txt',
        'new/name.dart',
        'img.png',
        'run.sh',
      ]);
    });

    test('numbers lines per hunk and counts +/-', () {
      final a = files[0];
      expect(a.hunks, hasLength(2));
      expect(a.additions, 3);
      expect(a.deletions, 2);
      final l = a.hunks[0].lines;
      expect(
        [for (final x in l) (x.type, x.oldNumber, x.newNumber, x.text)],
        [
          (DiffLineType.context, 1, 1, 'one'),
          (DiffLineType.del, 2, null, 'two'),
          (DiffLineType.add, null, 2, 'TWO'),
          (DiffLineType.add, null, 3, 'extra'),
          (DiffLineType.context, 3, 4, 'three'),
        ],
      );
      final h2 = a.hunks[1].lines;
      expect(h2.map((x) => x.type), [
        DiffLineType.context,
        DiffLineType.del,
        DiffLineType.noNewline,
        DiffLineType.add,
        DiffLineType.noNewline,
      ]);
      expect(h2[3].newNumber, 12);
      expect(h2[2].oldNumber, isNull);
      expect(h2[2].newNumber, isNull);
      expect(a.hunks[1].header, startsWith('@@ -10,2 +11,2 @@'));
    });

    test('hunk header without counts', () {
      expect(files[1].hunks.single.lines.map((x) => (x.oldNumber, x.newNumber)), [(5, null), (null, 5)]);
    });

    test('new and deleted files', () {
      expect(files[2].hunks.single.lines.map((x) => x.newNumber), [1, 2]);
      expect(files[2].additions, 2);
      expect(files[3].path, 'gone.txt');
      expect(files[3].hunks.single.lines.map((x) => x.oldNumber), [1, 2]);
      expect(files[3].deletions, 2);
    });

    test('rename without hunks', () {
      expect(files[4].kind, DiffFileKind.renamed);
      expect(files[4].oldPath, 'old/name.dart');
      expect(files[4].hunks, isEmpty);
    });

    test('binary and mode-only files', () {
      expect(files[5].kind, DiffFileKind.binary);
      expect(files[5].hunks, isEmpty);
      expect(files[6].kind, DiffFileKind.modeChanged);
      expect(files[6].hunks, isEmpty);
    });

    test('CRLF: trailing \\r is dropped from paths and text', () {
      final crlf = parseUnifiedDiff(_diff.replaceAll('\n', '\r\n'));
      expect(crlf.map((f) => f.path), files.map((f) => f.path));
      expect(crlf[0].hunks[0].lines[1].text, 'two');
      expect(crlf[0].hunks[0].lines.length, files[0].hunks[0].lines.length);
    });

    test('path falls back to the diff --git header', () {
      final f = parseUnifiedDiff('diff --git a/x y.txt b/x y.txt\nindex 1..2\n');
      expect(f.single.path, 'x y.txt');
      expect(f.single.kind, DiffFileKind.text);
    });

    test('content starting with +++ or --- inside a hunk is content', () {
      final f = parseUnifiedDiff('diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n---- x\n++++ y\n');
      expect(f.single.path, 'a');
      expect(f.single.additions, 1);
      expect(f.single.deletions, 1);
    });

    test('blank context line without leading space and trailing blank lines', () {
      final f = parseUnifiedDiff('diff --git a/a b/a\n@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n\n\n');
      final l = f.single.hunks.single.lines;
      expect(l.map((x) => x.type), [DiffLineType.context, DiffLineType.context, DiffLineType.del, DiffLineType.add]);
      expect(l[1].newNumber, 2);
    });

    test('hunk numbers beyond int range never throw and the line is not a hunk', () {
      const huge = '99999999999999999999999999';
      final f = parseUnifiedDiff('diff --git a/a b/a\n@@ -$huge,3 +1,3 @@\n+x\n');
      expect(f.single.hunks, isEmpty);

      final g = parseUnifiedDiff('diff --git a/a b/a\n@@ -1,3 +1,3 @@\n a\n@@ -1 +$huge @@\n+x\n');
      expect(g.single.hunks.single.lines.map((l) => l.text), ['a', '@ -1 +$huge @@', 'x']);
    });

    test('empty or non-diff input yields no files', () {
      expect(parseUnifiedDiff(''), isEmpty);
      expect(parseUnifiedDiff('\n'), isEmpty);
      expect(parseUnifiedDiff('just some text\n+not a diff\n'), isEmpty);
    });
  });

  group('diffStats', () {
    test('sums the parsed diff', () {
      final s = diffStats(parseUnifiedDiff(_diff));
      expect((s.files, s.additions, s.deletions, s.partial), (7, 3 + 1 + 2, 2 + 1 + 2, false));
    });

    test('real-like meta capped at 100 files vs a 150-file diff', () {
      final meta = parseReviewMeta(
        jsonEncode({
          'number': 7,
          'title': 'T',
          'body': 'x',
          'author': {'login': 'octo', 'id': 'U_1', 'is_bot': false},
          'baseRefName': 'main',
          'headRefName': 'feat',
          'files': [
            for (var i = 0; i < 100; i++) {'path': 'f$i', 'additions': 1, 'deletions': 2, 'changeType': 'MODIFIED'},
          ],
        }),
      )!;
      expect(meta.author, 'octo');
      expect(meta.stats.files, 100);
      expect(meta.stats.partial, isTrue);
      expect((meta.stats.additions, meta.stats.deletions), (100, 200));

      final big = parseUnifiedDiff(
        [
          for (var i = 0; i < 150; i++) 'diff --git a/f$i b/f$i\n--- a/f$i\n+++ b/f$i\n@@ -1 +1 @@\n-a\n+b\n+c\n',
        ].join(),
      );
      final s = diffStats(big);
      expect((s.files, s.additions, s.deletions, s.partial), (150, 300, 150, false));
    });

    test('pr.diff delta', () {
      final s = diffStats(parseUnifiedDiff(File('test/fixtures/workflow/delta/pr.diff').readAsStringSync()));
      expect((s.files, s.additions, s.deletions), (3, 8, 4));
    });
  });

  group('diffExcerpt', () {
    GateAnchor at(String path, int start, int end) => GateAnchor(path: path, start: start, end: end);

    test('anchor inside a hunk takes 3 lines on each side', () {
      final files = parseUnifiedDiff(_file('a.dart', _context(1, 20)));
      final e = diffExcerpt(files, at('a.dart', 10, 10));
      expect(_texts(e), [
        ['l7', 'l8', 'l9', 'l10', 'l11', 'l12', 'l13'],
      ]);
      expect(e.omitted, 0);
    });

    test('the range never starts before line 1', () {
      final files = parseUnifiedDiff(_file('a.dart', _context(1, 20)));
      expect(_texts(diffExcerpt(files, at('a.dart', 2, 3))), [
        ['l1', 'l2', 'l3', 'l4', 'l5', 'l6'],
      ]);
    });

    test('a removal right before the first line of the range comes in', () {
      final files = parseUnifiedDiff(_file('a.dart', [..._context(1, 5), '-gone', '-gone too', ..._context(6, 12)]));
      expect(_texts(diffExcerpt(files, at('a.dart', 9, 9))), [
        ['gone', 'gone too', 'l6', 'l7', 'l8', 'l9', 'l10', 'l11', 'l12'],
      ]);
    });

    test('a removal separated from the range by a context line outside it stays out', () {
      final files = parseUnifiedDiff(_file('a.dart', [..._context(1, 5), '-gone', ..._context(6, 14)]));
      expect(_texts(diffExcerpt(files, at('a.dart', 10, 10))), [
        ['l7', 'l8', 'l9', 'l10', 'l11', 'l12', 'l13'],
      ]);
    });

    test('a removal between lines of the range comes in, in diff order', () {
      final files = parseUnifiedDiff(_file('a.dart', [..._context(1, 3), '-old', '+new', ..._context(5, 6)]));
      final e = diffExcerpt(files, at('a.dart', 4, 4));
      expect(_texts(e), [
        ['l1', 'l2', 'l3', 'old', 'new', 'l5', 'l6'],
      ]);
      expect(e.blocks.single.map((l) => l.type), [
        DiffLineType.context,
        DiffLineType.context,
        DiffLineType.context,
        DiffLineType.del,
        DiffLineType.add,
        DiffLineType.context,
        DiffLineType.context,
      ]);
    });

    test('an anchor across two hunks keeps one block per hunk', () {
      const raw =
          'diff --git a/a.dart b/a.dart\n--- a/a.dart\n+++ b/a.dart\n'
          '@@ -1,3 +1,3 @@\n l1\n l2\n l3\n'
          '@@ -10,3 +10,3 @@\n l10\n l11\n l12\n';
      final e = diffExcerpt(parseUnifiedDiff(raw), at('a.dart', 4, 8));
      expect(_texts(e), [
        ['l1', 'l2', 'l3'],
        ['l10', 'l11'],
      ]);
    });

    test('an anchor with no line in the range is empty', () {
      final e = diffExcerpt(parseUnifiedDiff(_file('a.dart', _context(1, 20))), at('a.dart', 50, 52));
      expect(e.blocks, isEmpty);
      expect(e.omitted, 0);
    });

    test('a path absent from the diff, or absolute, is empty; a leading ./ matches', () {
      final files = parseUnifiedDiff(_file('lib/a.dart', _context(1, 5)));
      expect(diffExcerpt(files, at('lib/b.dart', 1, 1)).blocks, isEmpty);
      expect(diffExcerpt(files, at('/lib/a.dart', 1, 1)).blocks, isEmpty);
      expect(_texts(diffExcerpt(files, at('./lib/a.dart', 1, 1))), [
        ['l1', 'l2', 'l3', 'l4'],
      ]);
    });

    test('the no-newline marker does not count', () {
      final files = parseUnifiedDiff(
        _file('a.dart', [' l1', '-old', r'\ No newline at end of file', '+new', r'\ No newline at end of file']),
      );
      final e = diffExcerpt(files, at('a.dart', 2, 2));
      expect(_texts(e), [
        ['l1', 'old', 'new'],
      ]);
      expect(e.blocks.single.where((l) => l.type == DiffLineType.noNewline), isEmpty);
    });

    test('above 40 lines keeps 40 and counts the rest', () {
      final files = parseUnifiedDiff(_file('a.dart', [for (var i = 1; i <= 60; i++) '+a$i']));
      final e = diffExcerpt(files, at('a.dart', 1, 60));
      expect(e.blocks.single, hasLength(40));
      expect(e.blocks.single.last.text, 'a40');
      expect(e.omitted, 20);
    });

    test('the cap spans blocks: the second hunk is cut and a third is only counted', () {
      const raw = 'diff --git a/a.dart b/a.dart\n--- a/a.dart\n+++ b/a.dart\n';
      final hunks = [
        for (final start in [1, 100, 200])
          '@@ -$start,30 +$start,30 @@\n${[for (var i = start; i < start + 30; i++) ' l$i'].join('\n')}\n',
      ].join();
      final e = diffExcerpt(parseUnifiedDiff(raw + hunks), at('a.dart', 1, 229));
      expect(e.blocks.map((b) => b.length), [30, 10]);
      expect(e.omitted, 20 + 30);
    });
  });

  group('parseReviewMeta', () {
    test('invalid JSON or non-object', () {
      expect(parseReviewMeta('{oops'), isNull);
      expect(parseReviewMeta(''), isNull);
      expect(parseReviewMeta('[1]'), isNull);
    });

    test('author as string or without login is omitted; bad files are skipped', () {
      final m = parseReviewMeta('{"author":"octo","files":[1,{"path":"a","additions":"x"},{"additions":3}]}')!;
      expect(m.author, isNull);
      expect(m.files.map((f) => (f.path, f.additions, f.deletions)), [('a', 0, 0)]);
      expect(parseReviewMeta('{"author":{"login":5}}')!.author, isNull);
      expect(parseReviewMeta('{}')!.stats.partial, isFalse);
    });
  });

  group('parseReviewComments', () {
    test('invalid JSON or not a list', () {
      for (final raw in ['nope', '{"a":1}', '']) {
        final r = parseReviewComments(raw);
        expect(r.comments, isEmpty, reason: raw);
        expect(r.valid, isFalse, reason: raw);
      }
    });

    test('an empty list is valid', () {
      for (final raw in ['[]', ' [ ] \n']) {
        final r = parseReviewComments(raw);
        expect(r.comments, isEmpty, reason: raw);
        expect(r.valid, isTrue, reason: raw);
      }
    });

    test('strips ./ and normalizes invalid line', () {
      final c = parseReviewComments(
        jsonEncode([
          {'path': './lib/a.dart', 'line': 3, 'severity': 'critical', 'agent': 'x', 'body': 'b'},
          {'path': 'lib/a.dart'},
          {'path': 'lib/a.dart', 'line': 0},
          {'path': 'lib/a.dart', 'line': -2},
          {'path': 'lib/a.dart', 'line': 2.5},
          {'path': 'lib/a.dart', 'line': '4'},
          'junk',
        ]),
      ).comments;
      expect(c, hasLength(6));
      expect(c[0].path, 'lib/a.dart');
      expect(c[0].line, 3);
      expect(c[0].severity, 'critical');
      expect(c.skip(1).map((x) => x.line), everyElement(isNull));
    });
  });

  group('startsCollapsed', () {
    DiffFile file(int add, int del) =>
        DiffFile(path: 'a', kind: DiffFileKind.text, hunks: const [], additions: add, deletions: del);

    test('collapses big files without comments only', () {
      expect(startsCollapsed(file(200, 200), 0), isTrue);
      expect(startsCollapsed(file(399, 0), 0), isFalse);
      expect(startsCollapsed(file(200, 200), 1), isFalse);
    });
  });

  group('ordering', () {
    test('reviewIds: exact PR-<n>.md, descending numeric, decoys ignored', () {
      expect(reviewIds(['PR-9.md', 'PR-157.md', 'PR-1.full.md', 'PR-2.diff', 'PR-3.md.bak', 'xPR-4.md', 'PR-.md']), [
        157,
        9,
      ]);
      expect(reviewIds(const []), isEmpty);
    });

    test('orderDetails: newest name first, only visible .md', () {
      expect(
        orderDetails([
          'details/2026-01-02-b.md',
          'details/2026-03-01-a.md',
          'details/.hidden.md',
          'details/x.txt',
          'details/2026-01-02-c.md',
        ]),
        ['details/2026-03-01-a.md', 'details/2026-01-02-c.md', 'details/2026-01-02-b.md'],
      );
    });
  });

  group('stripFrontMatter', () {
    test('removes leading block', () {
      expect(stripFrontMatter('---\nstatus: x\n---\n# T\n'), '# T\n');
      expect(stripFrontMatter('---\r\nstatus: x\r\n---\r\n# T\r\n'), '# T\r\n');
      expect(stripFrontMatter('---\n---\nbody'), 'body');
    });

    test('keeps text without front-matter or without closing', () {
      expect(stripFrontMatter('# T\n---\nx\n---\n'), '# T\n---\nx\n---\n');
      expect(stripFrontMatter('---\nstatus: x\n# T\n'), '---\nstatus: x\n# T\n');
      expect(stripFrontMatter(''), '');
      expect(stripFrontMatter('---'), '---');
    });
  });

  group('buildDiffRows', () {
    final files = parseUnifiedDiff(_diff);

    int count(List<DiffRow> rows) => rows.whereType<CommentRow>().length;

    test('anchors after the line with newNumber == line, outside and others add up', () {
      final comments = [
        _c('lib/a.dart', 3, body: 'first'),
        _c('lib/a.dart', 3, body: 'second'),
        _c('lib/a.dart', 99, body: 'outside'),
        _c('lib/a.dart', null, body: 'noline'),
        _c('lib/b.dart', 5, body: 'b5'),
        _c('missing.dart', 1, body: 'other'),
      ];
      final rows = buildDiffRows(files, comments, {});
      expect(count(rows), comments.length);

      for (final r in rows.whereType<CommentRow>().where((r) => ['first', 'second', 'b5'].contains(r.comment.body))) {
        final i = rows.indexOf(r);
        var j = i - 1;
        while (rows[j] is CommentRow) {
          j--;
        }
        final prev = rows[j] as LineRow;
        expect(prev.line.newNumber, r.comment.line);
      }
      final firstIdx = rows.indexWhere((r) => r is CommentRow && r.comment.body == 'first');
      expect((rows[firstIdx + 1] as CommentRow).comment.body, 'second');

      final outsideIdx = rows.indexWhere((r) => r is OutsideDiffRow);
      expect((rows[outsideIdx] as OutsideDiffRow).count, 2);
      expect(rows[outsideIdx - 1], isA<FileHeaderRow>());
      expect(rows[outsideIdx + 3], isA<HunkRow>());

      expect(rows[rows.length - 2], isA<OthersRow>());
      expect((rows.last as CommentRow).comment.body, 'other');
      expect((rows.first as FileHeaderRow).commentCount, 4);
    });

    test('line is the new number: it anchors after the added line, never after the removed one', () {
      final rows = buildDiffRows(files, [_c('lib/a.dart', 2)], {});
      final i = rows.indexWhere((r) => r is CommentRow);
      expect((rows[i - 1] as LineRow).line.text, 'TWO');
      expect(rows.whereType<OutsideDiffRow>(), isEmpty);
    });

    test('collapsed file keeps only its header', () {
      final all = buildDiffRows(files, [_c('lib/a.dart', 3)], {});
      final rows = buildDiffRows(files, [_c('lib/a.dart', 3)], {'lib/a.dart'});
      expect(rows.first, isA<FileHeaderRow>());
      expect((rows.first as FileHeaderRow).collapsed, isTrue);
      expect(rows[1], isA<FileHeaderRow>());
      expect(count(rows), 0);
      expect(rows.length, lessThan(all.length));
    });

    test('empty diff: every comment goes to others', () {
      final rows = buildDiffRows(const [], [_c('a', 1), _c('b', null)], {});
      expect(rows.first, isA<OthersRow>());
      expect(count(rows), 2);
      expect(buildDiffRows(const [], const [], {}), isEmpty);
    });
  });

  group('reviewLine', () {
    String doc(String status, {String extra = '', String body = ''}) => '---\nstatus: $status\n$extra---\n$body';
    String achados(String counts) => '# R\n\n- **Achados:** $counts\n';

    test('draft summarises findings', () {
      expect(
        reviewLine(doc('draft', body: achados('1 critical, 1 major, 2 minor, 0 nit'))).text,
        'rascunho pronto: 2 problemas sérios, 2 menores',
      );
      expect(reviewLine(doc('draft', body: achados('0 critical, 1 major'))).text, 'rascunho pronto: 1 problema sério');
      expect(reviewLine(doc('draft', body: achados('1 minor'))).text, 'rascunho pronto: 1 menor');
      expect(
        reviewLine(doc('draft', body: achados('0 critical, 0 major, 0 minor, 0 nit'))).text,
        'rascunho pronto, sem problemas',
      );
      expect(reviewLine(doc('draft', body: achados('nenhum'))).text, 'rascunho pronto');
      expect(reviewLine(doc('draft')).text, 'rascunho pronto');
      expect(reviewLine(doc('draft')).status, ReviewStatus.draft);
    });

    test('approved and published', () {
      final a = reviewLine(doc('approved'));
      expect(a.status, ReviewStatus.approved);
      expect(a.text, 'aprovada, falta publicar');
      final p = reviewLine(doc('published', extra: 'published_at: 2026-09-28T15:00:00Z\n'));
      expect(p.status, ReviewStatus.published);
      expect(p.text, 'publicada em 28 set');
      expect(reviewLine(doc('published')).text, 'publicada');
      expect(reviewLine(doc('published', extra: 'published_at: ontem\n')).text, 'publicada');
    });

    test('unknown without front-matter or with an unknown status', () {
      for (final raw in ['', '# só corpo', doc('mystery'), '---\nstatus: draft\nsem fechamento']) {
        final r = reviewLine(raw);
        expect(r.status, ReviewStatus.unknown);
        expect(r.text, 'revisão');
      }
    });

    test('title keeps text after the first colon and drops quotes', () {
      expect(reviewLine(doc('draft', extra: 'title: feat: cache\n')).title, 'feat: cache');
      expect(reviewLine(doc('draft', extra: 'title: "x"\n')).title, 'x');
      expect(reviewLine(doc('draft', extra: "title: 'y'\n")).title, 'y');
      expect(reviewLine(doc('draft')).title, isNull);
    });
  });

  group('reference docs', () {
    DocEntry entry(String rel) => DocEntry(rel: rel, size: 1, modified: DateTime(2026));

    test('docTitle names what the document is', () {
      expect(docTitle('spec.md'), 'O que vai ser entregue');
      expect(docTitle('plan.md'), 'Como vai ser construído');
      expect(docTitle('tasks.md'), 'Tasks');
      expect(docTitle('phases.md'), 'Fases');
      expect(docTitle('challenge.md'), 'Desafio da spec');
      expect(docTitle('challenge-spec.md'), 'Desafio da spec');
      expect(docTitle('verify.md'), 'Verificação');
      expect(docTitle('qa.md'), 'QA');
      expect(docTitle('adr-candidates.md'), 'ADRs propostos');
      expect(docTitle('details/2026-10-01-x.md'), '2026-10-01-x');
      expect(docTitle('notas.md'), 'notas');
    });

    test('docKind only names spec, plan and tasks', () {
      expect(docKind('spec.md'), 'Especificação');
      expect(docKind('plan.md'), 'Plano técnico');
      expect(docKind('tasks.md'), 'Tasks');
      expect(docKind('qa.md'), isNull);
      expect(docKind('details/x.md'), isNull);
    });

    test('referenceDocs orders the cycle docs and keeps details as listed', () {
      final listing = DocsListing(
        artifacts: [
          for (final r in ['notas.md', 'tasks.md', 'spec.md', 'plan.md', 'verify.md']) entry(r),
        ],
        details: [entry('details/b.md'), entry('details/a.md')],
      );
      final docs = referenceDocs(listing);
      expect(docs.cycle.map((e) => e.rel), ['spec.md', 'plan.md', 'tasks.md', 'verify.md', 'notas.md']);
      expect(docs.details.map((e) => e.rel), ['details/b.md', 'details/a.md']);
    });

    test('referenceDocs sorts unknown docs alphabetically after the known ones', () {
      final docs = referenceDocs(DocsListing(artifacts: [entry('z.md'), entry('a.md'), entry('adr-candidates.md')]));
      expect(docs.cycle.map((e) => e.rel), ['adr-candidates.md', 'a.md', 'z.md']);
    });
  });

  group('docGateLine', () {
    ReportDoc report(Stage stage, String name, GateStatus status, {int round = 1}) => ReportDoc(
      feature: 'f',
      startedAt: null,
      stages: [
        StageReport(
          stage: stage,
          status: ReportStatus.done,
          gate: ReportGate(name: name, status: status, round: round),
        ),
      ],
    );

    test('approved says the round only after the first', () {
      expect(
        docGateLine('plan.md', report(Stage.plan, 'plan', GateStatus.approved, round: 2)),
        'aprovado, na 2ª rodada',
      );
      expect(docGateLine('plan.md', report(Stage.plan, 'plan', GateStatus.approved)), 'aprovado');
    });

    test('spec reads the gate of the challenge stage', () {
      expect(docGateLine('spec.md', report(Stage.challenge, 'spec', GateStatus.approved)), 'aprovado');
      expect(docGateLine('spec.md', report(Stage.specify, 'spec', GateStatus.approved)), isNull);
    });

    test('other statuses', () {
      expect(docGateLine('tasks.md', report(Stage.tasks, 'tasks', GateStatus.passed)), 'passou sem você');
      expect(docGateLine('tasks.md', report(Stage.tasks, 'tasks', GateStatus.open)), 'esperando você no gate');
      expect(
        docGateLine('tasks.md', report(Stage.tasks, 'tasks', GateStatus.revising, round: 3)),
        'em revisão, rodada 3',
      );
      expect(docGateLine('tasks.md', report(Stage.tasks, 'tasks', GateStatus.rejected)), 'rejeitado');
    });

    test('null without report, stage, gate or for other docs', () {
      final plan = report(Stage.plan, 'plan', GateStatus.approved);
      expect(docGateLine('plan.md', null), isNull);
      expect(docGateLine('notas.md', plan), isNull);
      expect(docGateLine('qa.md', plan), isNull);
      expect(docGateLine('tasks.md', plan), isNull);
      const noGate = ReportDoc(
        feature: 'f',
        startedAt: null,
        stages: [StageReport(stage: Stage.plan, status: ReportStatus.done)],
      );
      expect(docGateLine('plan.md', noGate), isNull);
      expect(docGateLine('plan.md', const ReportDoc(feature: 'f', startedAt: null, stages: [])), isNull);
    });
  });
}
