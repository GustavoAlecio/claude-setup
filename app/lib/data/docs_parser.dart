import 'dart:convert';

import 'docs_models.dart';
import 'front_matter.dart';

final _hunkPattern = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// Números fora do alcance de `int` (ou ausentes) não fazem da linha um hunk.
(int, int)? _hunkStart(String line) {
  final m = _hunkPattern.firstMatch(line);
  if (m == null) return null;
  final old = int.tryParse(m.group(1)!);
  final now = int.tryParse(m.group(2)!);
  return old == null || now == null ? null : (old, now);
}

final _gitHeaderPattern = RegExp(r'^diff --git a/(.+) b/(.+)$');
final _binaryPattern = RegExp(r'^Binary files (?:a/)?(.+?) and (?:b/(.+)|/dev/null) differ$');
final _reviewIdPattern = RegExp(r'^PR-(\d+)\.md$');

/// Remove `---\n…\n---` do início; sem fechamento, devolve o texto intacto.
String stripFrontMatter(String raw) {
  final lines = raw.split('\n');
  final end = frontMatterEnd(lines);
  return end < 0 ? raw : lines.sublist(end + 1).join('\n');
}

const kCollapseThreshold = 400;

bool startsCollapsed(DiffFile file, int commentCount) =>
    commentCount == 0 && file.additions + file.deletions >= kCollapseThreshold;

class _FileBuilder {
  _FileBuilder(this.headerPath, this.headerOldPath);

  final String headerPath;
  final String? headerOldPath;
  String? plusPath;
  String? renameTo;
  String? renameFrom;
  String? binaryPath;
  var sawMode = false;
  final hunks = <DiffHunk>[];
  var additions = 0;
  var deletions = 0;

  DiffFile build() {
    final path = plusPath ?? renameTo ?? binaryPath ?? headerPath;
    final kind = binaryPath != null
        ? DiffFileKind.binary
        : renameTo != null
        ? DiffFileKind.renamed
        : sawMode
        ? DiffFileKind.modeChanged
        : DiffFileKind.text;
    return DiffFile(
      path: path,
      oldPath: kind == DiffFileKind.renamed ? (renameFrom ?? headerOldPath) : null,
      kind: kind,
      hunks: hunks,
      additions: additions,
      deletions: deletions,
    );
  }
}

/// Nunca lança; texto sem `diff --git` resulta em lista vazia.
List<DiffFile> parseUnifiedDiff(String raw) {
  final lines = raw.split('\n').map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l).toList();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  final files = <DiffFile>[];
  _FileBuilder? file;
  List<DiffLine>? hunkLines;
  String? hunkHeader;
  var oldNo = 0;
  var newNo = 0;

  void closeHunk() {
    if (file != null && hunkLines != null) file!.hunks.add(DiffHunk(header: hunkHeader!, lines: hunkLines!));
    hunkLines = null;
  }

  void closeFile() {
    closeHunk();
    if (file != null) files.add(file!.build());
    file = null;
  }

  for (final line in lines) {
    if (line.startsWith('diff --git ')) {
      closeFile();
      final m = _gitHeaderPattern.firstMatch(line);
      file = _FileBuilder(m?.group(2) ?? line.substring(11), m?.group(1));
      continue;
    }
    final f = file;
    if (f == null) continue;

    if (hunkLines == null) {
      final hunk = _hunkStart(line);
      if (hunk != null) {
        (oldNo, newNo) = hunk;
        hunkHeader = line;
        hunkLines = [];
      } else if (line.startsWith('+++ b/')) {
        f.plusPath = line.substring(6);
      } else if (line.startsWith('rename to ')) {
        f.renameTo = line.substring(10);
      } else if (line.startsWith('rename from ')) {
        f.renameFrom = line.substring(12);
      } else if (line.startsWith('old mode ') || line.startsWith('new mode ')) {
        f.sawMode = true;
      } else {
        final bin = _binaryPattern.firstMatch(line);
        if (bin != null) f.binaryPath = bin.group(2) ?? bin.group(1);
      }
      continue;
    }

    final hunk = _hunkStart(line);
    if (hunk != null) {
      closeHunk();
      (oldNo, newNo) = hunk;
      hunkHeader = line;
      hunkLines = [];
      continue;
    }
    if (line.startsWith('+')) {
      f.additions++;
      hunkLines!.add(DiffLine(type: DiffLineType.add, text: line.substring(1), newNumber: newNo++));
    } else if (line.startsWith('-')) {
      f.deletions++;
      hunkLines!.add(DiffLine(type: DiffLineType.del, text: line.substring(1), oldNumber: oldNo++));
    } else if (line.startsWith('\\')) {
      hunkLines!.add(DiffLine(type: DiffLineType.noNewline, text: line));
    } else {
      final text = line.isEmpty ? '' : line.substring(1);
      hunkLines!.add(DiffLine(type: DiffLineType.context, text: text, oldNumber: oldNo++, newNumber: newNo++));
    }
  }
  closeFile();
  return files;
}

Object? _decode(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

String? _string(Object? v) => v is String ? v : null;

int? _integer(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt();
  return null;
}

/// `null` para JSON inválido ou que não seja objeto.
ReviewMeta? parseReviewMeta(String raw) {
  final json = _decode(raw);
  if (json is! Map) return null;
  final author = json['author'];
  final files = <ReviewMetaFile>[];
  final rawFiles = json['files'];
  if (rawFiles is List) {
    for (final entry in rawFiles) {
      if (entry is! Map) continue;
      final path = _string(entry['path']);
      if (path == null) continue;
      files.add(
        ReviewMetaFile(
          path: path,
          additions: _integer(entry['additions']) ?? 0,
          deletions: _integer(entry['deletions']) ?? 0,
        ),
      );
    }
  }
  return ReviewMeta(
    number: _integer(json['number']),
    title: _string(json['title']),
    author: author is Map ? _string(author['login']) : null,
    headRefName: _string(json['headRefName']),
    baseRefName: _string(json['baseRefName']),
    files: files,
  );
}

/// `valid` é falso para JSON inválido ou que não seja lista (então `comments` é vazio); `[]` é válido.
/// Entradas que não são objetos são ignoradas.
({List<ReviewComment> comments, bool valid}) parseReviewComments(String raw) {
  final json = _decode(raw);
  if (json is! List) return (comments: const [], valid: false);
  final out = <ReviewComment>[];
  for (final entry in json) {
    if (entry is! Map) continue;
    var path = _string(entry['path']) ?? '';
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    final line = _integer(entry['line']);
    out.add(
      ReviewComment(
        path: path,
        line: line != null && line > 0 ? line : null,
        severity: _string(entry['severity']) ?? '',
        agent: _string(entry['agent']) ?? '',
        body: _string(entry['body']) ?? '',
      ),
    );
  }
  return (comments: out, valid: true);
}

/// Números de `PR-<n>.md`, do maior para o menor; só nomes exatos e canônicos (sem zeros à esquerda),
/// porque os irmãos `.diff`/`.json` são procurados por `PR-<n>`.
List<int> reviewIds(Iterable<String> fileNames) {
  final ids = <int>{};
  for (final name in fileNames) {
    final digits = _reviewIdPattern.firstMatch(name)?.group(1);
    final n = digits == null ? null : int.tryParse(digits);
    if (n != null && n.toString() == digits) ids.add(n);
  }
  return ids.toList()..sort((a, b) => b.compareTo(a));
}

/// `.md` não ocultos, do nome mais novo para o mais antigo (os nomes começam pela data).
List<String> orderDetails(Iterable<String> names) {
  String base(String s) => s.split('/').last;
  final kept = names.where((n) => base(n).endsWith('.md') && !base(n).startsWith('.')).toList();
  kept.sort((a, b) {
    final byBase = base(b).compareTo(base(a));
    return byBase != 0 ? byBase : b.compareTo(a);
  });
  return kept;
}

DiffStats diffStats(List<DiffFile> files) => DiffStats.sum(files.length, files.map((f) => (f.additions, f.deletions)));

/// Lista achatada para uma única lista virtualizada. `collapsed` guarda paths; arquivo recolhido
/// fica só com o cabeçalho (comentários dele também saem da lista).
List<DiffRow> buildDiffRows(List<DiffFile> files, List<ReviewComment> comments, Set<String> collapsed) {
  final owner = <String, int>{};
  for (var i = 0; i < files.length; i++) {
    owner.putIfAbsent(files[i].path, () => i);
  }
  final perFile = List.generate(files.length, (_) => <ReviewComment>[]);
  final others = <ReviewComment>[];
  for (final c in comments) {
    final i = owner[c.path];
    if (i == null) {
      others.add(c);
    } else {
      perFile[i].add(c);
    }
  }

  final rows = <DiffRow>[];
  for (var i = 0; i < files.length; i++) {
    final file = files[i];
    final mine = perFile[i];
    final isCollapsed = collapsed.contains(file.path);
    rows.add(FileHeaderRow(file: file, collapsed: isCollapsed, commentCount: mine.length));
    if (isCollapsed) continue;

    final anchored = <int>{};
    if (owner[file.path] == i) {
      for (final h in file.hunks) {
        for (final l in h.lines) {
          if (l.newNumber != null) anchored.add(l.newNumber!);
        }
      }
    }
    final outside = mine.where((c) => c.line == null || !anchored.contains(c.line)).toList();
    if (outside.isNotEmpty) {
      rows.add(OutsideDiffRow(outside.length));
      rows.addAll(outside.map(CommentRow.new));
    }
    for (final h in file.hunks) {
      rows.add(HunkRow(h.header));
      for (final l in h.lines) {
        rows.add(LineRow(l));
        final n = l.newNumber;
        if (n == null) continue;
        rows.addAll(mine.where((c) => c.line == n).map(CommentRow.new));
      }
    }
  }
  if (others.isNotEmpty) {
    rows.add(OthersRow(others.length));
    rows.addAll(others.map(CommentRow.new));
  }
  return rows;
}
