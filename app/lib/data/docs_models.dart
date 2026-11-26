enum DiffLineType { add, del, context, noNewline }

class DiffLine {
  const DiffLine({required this.type, required this.text, this.oldNumber, this.newNumber});

  final DiffLineType type;
  final String text;
  final int? oldNumber;
  final int? newNumber;
}

class DiffHunk {
  const DiffHunk({required this.header, required this.lines});

  final String header;
  final List<DiffLine> lines;
}

/// Natureza do arquivo segundo os cabeçalhos do git; só decide o texto exibido quando não há hunks.
enum DiffFileKind { text, binary, renamed, modeChanged }

class DiffFile {
  const DiffFile({
    required this.path,
    required this.kind,
    required this.hunks,
    this.oldPath,
    this.additions = 0,
    this.deletions = 0,
  });

  final String path;
  final String? oldPath;
  final DiffFileKind kind;
  final List<DiffHunk> hunks;
  final int additions;
  final int deletions;
}

/// Lines of a diff around an anchor: one block per hunk that crosses the range, in diff order; [omitted] counts the
/// lines past the cap.
typedef DiffExcerpt = ({List<List<DiffLine>> blocks, int omitted});

class DiffStats {
  const DiffStats({required this.files, required this.additions, required this.deletions, this.partial = false});

  factory DiffStats.sum(int files, Iterable<(int additions, int deletions)> counts, {bool partial = false}) {
    var additions = 0;
    var deletions = 0;
    for (final (a, d) in counts) {
      additions += a;
      deletions += d;
    }
    return DiffStats(files: files, additions: additions, deletions: deletions, partial: partial);
  }

  final int files;
  final int additions;
  final int deletions;

  /// `meta.files` vem do `gh` limitado a 100 entradas; com 100 o total pode estar truncado.
  final bool partial;
}

class ReviewMetaFile {
  const ReviewMetaFile({required this.path, required this.additions, required this.deletions});

  final String path;
  final int additions;
  final int deletions;
}

class ReviewMeta {
  const ReviewMeta({this.number, this.title, this.author, this.headRefName, this.baseRefName, this.files = const []});

  final int? number;
  final String? title;

  /// `author.login` do `gh`; omitido quando `author` não é objeto com `login` string.
  final String? author;
  final String? headRefName;
  final String? baseRefName;
  final List<ReviewMetaFile> files;

  static const filesLimit = 100;

  DiffStats get stats =>
      DiffStats.sum(files.length, files.map((f) => (f.additions, f.deletions)), partial: files.length == filesLimit);
}

class ReviewComment {
  const ReviewComment({required this.path, required this.severity, required this.agent, required this.body, this.line});

  /// Sem o `./` inicial.
  final String path;

  /// `null` quando ausente, não inteira ou <= 0: o comentário vai para "fora do diff" do arquivo.
  final int? line;
  final String severity;
  final String agent;
  final String body;
}

sealed class DiffRow {
  const DiffRow();
}

class FileHeaderRow extends DiffRow {
  const FileHeaderRow({required this.file, required this.collapsed, required this.commentCount});

  final DiffFile file;
  final bool collapsed;
  final int commentCount;
}

class OutsideDiffRow extends DiffRow {
  const OutsideDiffRow(this.count);

  final int count;
}

class HunkRow extends DiffRow {
  const HunkRow(this.header);

  final String header;
}

class LineRow extends DiffRow {
  const LineRow(this.line);

  final DiffLine line;
}

class CommentRow extends DiffRow {
  const CommentRow(this.comment);

  final ReviewComment comment;
}

class OthersRow extends DiffRow {
  const OthersRow(this.count);

  final int count;
}

final _reviewIdPattern = RegExp(r'^PR-(\d+)\.md$');

class DocEntry {
  const DocEntry({required this.rel, required this.size, required this.modified});

  /// Relativo ao diretório do projeto no workflow, com `/`.
  final String rel;
  final int size;
  final DateTime modified;

  @override
  bool operator ==(Object other) =>
      other is DocEntry && other.rel == rel && other.size == size && other.modified == modified;

  @override
  int get hashCode => Object.hash(rel, size, modified);
}

class ReviewEntry {
  const ReviewEntry({required this.number, required this.report, this.diff, this.comments, this.meta});

  final int number;
  final DocEntry report;
  final DocEntry? diff;
  final DocEntry? comments;
  final DocEntry? meta;

  String get id => 'PR-$number';
}

class DocsListing {
  const DocsListing({this.artifacts = const [], this.details = const [], this.reviews = const []});

  /// Agrupa arquivos já filtrados pela contenção; quem lista só coleta a raiz, `details/` e `reviews/`.
  factory DocsListing.fromEntries(Iterable<DocEntry> entries) {
    final byRel = {for (final e in entries) e.rel: e};
    final root = [
      for (final rel in byRel.keys)
        if (!rel.contains('/') && rel.endsWith('.md') && !rel.startsWith('.')) rel,
    ]..sort();
    final details = orderDetails([
      for (final rel in byRel.keys)
        if (rel.startsWith('details/') && !rel.substring(8).contains('/')) rel,
    ]);
    final reviewNames = [
      for (final rel in byRel.keys)
        if (rel.startsWith('reviews/') && !rel.substring(8).contains('/')) rel.substring(8),
    ];
    return DocsListing(
      artifacts: [for (final rel in root) byRel[rel]!],
      details: [for (final rel in details) byRel[rel]!],
      reviews: [
        for (final n in reviewIds(reviewNames))
          ReviewEntry(
            number: n,
            report: byRel['reviews/PR-$n.md']!,
            diff: byRel['reviews/PR-$n.diff'],
            comments: byRel['reviews/PR-$n.comments.json'],
            meta: byRel['reviews/PR-$n.meta.json'],
          ),
      ],
    );
  }

  static const empty = DocsListing();

  final List<DocEntry> artifacts;
  final List<DocEntry> details;
  final List<ReviewEntry> reviews;
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
