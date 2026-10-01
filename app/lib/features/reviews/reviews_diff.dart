import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../data/docs_models.dart';
import '../../data/docs_parser.dart';

const kIsolateParseThreshold = 256 * 1024;

/// Arquivo com pelo menos isto de linhas alteradas e sem comentário começa recolhido.
const kSeverities = ['critical', 'major', 'minor', 'nit'];

Color severityColor(AppColors c, String severity) => switch (severity) {
  'critical' => c.fail,
  'major' => c.warn,
  'minor' => c.accent,
  _ => c.idle,
};

/// Top-level para o closure do isolate não capturar o `State` de quem chama.
Future<List<DiffFile>> parseDiffText(String text, int size) =>
    size > kIsolateParseThreshold ? Isolate.run(() => parseUnifiedDiff(text)) : Future.value(parseUnifiedDiff(text));

/// Uma lista virtualizada sobre [rows]; a seleção de texto vale só dentro de cada linha ou comentário.
class ReviewsDiff extends StatelessWidget {
  const ReviewsDiff({
    super.key,
    required this.rows,
    required this.onToggle,
    required this.onLink,
    required this.storageKey,
    this.warning,
  });

  /// Guarda a rolagem por PR quando a sub-aba troca ou o diff é relido.
  final PageStorageKey<String> storageKey;

  final List<DiffRow> rows;
  final void Function(String path) onToggle;
  final void Function(Uri) onLink;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final warning = this.warning;
    final offset = warning == null ? 0 : 1;
    return ListView.builder(
      key: storageKey,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      itemCount: rows.length + offset,
      itemBuilder: (context, i) {
        if (i < offset) {
          return Padding(padding: const EdgeInsets.only(bottom: 10), child: Muted(warning!, size: 12.5));
        }
        return switch (rows[i - offset]) {
          FileHeaderRow(:final file, :final collapsed, :final commentCount) => _FileHeader(
            file: file,
            collapsed: collapsed,
            commentCount: commentCount,
            onTap: () => onToggle(file.path),
          ),
          OutsideDiffRow(:final count) => _SectionLabel('fora do diff ($count)'),
          HunkRow(:final header) => _Hunk(header),
          LineRow(:final line) => DiffLineView(line),
          CommentRow(:final comment) => _CommentCard(comment: comment, onLink: onLink),
          OthersRow(:final count) => _SectionLabel('outros comentários ($count)', top: 18),
        };
      },
    );
  }
}

class _FileHeader extends StatelessWidget {
  const _FileHeader({required this.file, required this.collapsed, required this.commentCount, required this.onTap});

  final DiffFile file;
  final bool collapsed;
  final int commentCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final note = file.hunks.isNotEmpty
        ? null
        : switch (file.kind) {
            DiffFileKind.binary => 'arquivo binário',
            DiffFileKind.renamed => 'renomeado de ${file.oldPath ?? '?'}',
            DiffFileKind.modeChanged => 'modo alterado',
            DiffFileKind.text => null,
          };
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: c.elevated,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: c.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    file.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.textPrimary),
                  ),
                ),
                if (note != null) ...[const SizedBox(width: 10), Muted(note, size: 11.5)],
                if (commentCount > 0) ...[
                  const SizedBox(width: 10),
                  Pill(label: '$commentCount comentários', color: c.accent, dot: false),
                ],
                const SizedBox(width: 10),
                Mono('+${file.additions}', color: c.pass),
                const SizedBox(width: 6),
                Mono('−${file.deletions}', color: c.fail),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.top = 6});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(4, top, 4, 4), child: Muted(text, size: 11));
}

class _Hunk extends StatelessWidget {
  const _Hunk(this.header);

  final String header;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.accent.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        header,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, color: c.textMuted),
      ),
    );
  }
}

class DiffLineView extends StatelessWidget {
  const DiffLineView(this.line, {super.key});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (background, prefix) = switch (line.type) {
      DiffLineType.add => (c.pass.withValues(alpha: 0.12), '+'),
      DiffLineType.del => (c.fail.withValues(alpha: 0.12), '-'),
      DiffLineType.context => (null, ' '),
      DiffLineType.noNewline => (null, ''),
    };
    final numberStyle = TextStyle(fontFamily: monoFamily, fontSize: 11.5, height: 1.45, color: c.textMuted);
    Widget number(int? n) => SizedBox(
      width: 44,
      child: Text(n?.toString() ?? '', textAlign: TextAlign.right, style: numberStyle),
    );
    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          number(line.oldNumber),
          number(line.newNumber),
          const SizedBox(width: 10),
          Expanded(
            // SelectableText would bring an inner vertical Scrollable per line that wins drags over the list.
            child: SelectionArea(
              child: Text(
                '$prefix${line.text}',
                style: TextStyle(
                  fontFamily: monoFamily,
                  fontSize: 12,
                  height: 1.45,
                  color: line.type == DiffLineType.noNewline ? c.textMuted : c.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentCard extends StatelessWidget {
  const _CommentCard({required this.comment, required this.onLink});

  final ReviewComment comment;
  final void Function(Uri) onLink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = severityColor(c, comment.severity);
    final where = comment.line == null ? comment.path : '${comment.path}:${comment.line}';
    return Container(
      margin: const EdgeInsets.fromLTRB(98, 4, 0, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(label: comment.severity.isEmpty ? '—' : comment.severity, color: color),
              const SizedBox(width: 8),
              Mono(comment.agent, size: 11),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  where,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          MarkdownView(comment.body, onLink: onLink),
        ],
      ),
    );
  }
}
