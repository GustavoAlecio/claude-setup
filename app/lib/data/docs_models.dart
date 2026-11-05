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
