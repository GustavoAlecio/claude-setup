import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primitives.dart';
import '../../data/docs_models.dart';
import '../../data/docs_parser.dart';
import '../../data/report_models.dart';
import '../reviews/reviews_diff.dart';

/// Lines drawn per open file of the full diff; the rest is only counted.
const kGateDiffFileLines = 400;

/// The `caminho:início-fim` label of a `pr` point and its excerpt of the diff. [diff] carries `null` data when the
/// diff is unavailable; while it loads nothing is drawn.
class GatePointDiff extends StatelessWidget {
  const GatePointDiff({super.key, required this.index, required this.anchor, required this.diff});

  final int index;
  final GateAnchor anchor;
  final AsyncSnapshot<List<DiffFile>?> diff;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Mono(anchor.label, size: 11.5, key: ValueKey('gate-point-$index-anchor')),
        const SizedBox(height: 6),
        KeyedSubtree(
          key: ValueKey('gate-point-$index-excerpt'),
          child: switch (diff) {
            AsyncSnapshot(connectionState: ConnectionState.done, data: final files?) => _excerpt(
              c,
              diffExcerpt(files, anchor),
            ),
            AsyncSnapshot(connectionState: ConnectionState.done) => const Muted('diff indisponível', size: 12),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }

  Widget _excerpt(AppColors c, DiffExcerpt excerpt) {
    if (excerpt.blocks.isEmpty) return const Muted('trecho fora do diff', size: 12);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, block) in excerpt.blocks.indexed) ...[
            if (i > 0) const _Gap(),
            for (final line in block) DiffLineView(line),
          ],
          if (excerpt.omitted > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Muted('mais ${countLabel(excerpt.omitted, 'linha')}', size: 11.5),
            ),
        ],
      ),
    );
  }
}

/// Boundary between two non-contiguous blocks of an excerpt.
class _Gap extends StatelessWidget {
  const _Gap();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    child: Text(
      '⋯',
      style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: context.colors.textMuted),
    ),
  );
}

/// The whole `pr.diff`, folded: a closed file builds no lines and an open one at most [kGateDiffFileLines].
class GateDiffFull extends StatefulWidget {
  const GateDiffFull({super.key, required this.files});

  final List<DiffFile> files;

  @override
  State<GateDiffFull> createState() => _GateDiffFullState();
}

class _GateDiffFullState extends State<GateDiffFull> {
  bool _open = false;
  final _openFiles = <String>{};

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final files = widget.files;
    final stats = diffStats(files);
    return Panel(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toggle(
            key: const ValueKey('gate-diff-full-toggle'),
            open: _open,
            onTap: () => setState(() => _open = !_open),
            children: [
              Text(
                'Diff completo',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Muted(
                  '${countLabel(stats.files, 'arquivo')}, +${stats.additions} −${stats.deletions}',
                  key: const ValueKey('gate-diff-full-stats'),
                ),
              ),
            ],
          ),
          if (_open)
            for (final (i, file) in files.indexed) ...[
              _Toggle(
                key: ValueKey('gate-diff-file-$i'),
                open: _openFiles.contains(file.path),
                onTap: () => setState(
                  () => _openFiles.contains(file.path) ? _openFiles.remove(file.path) : _openFiles.add(file.path),
                ),
                children: [
                  Expanded(
                    child: Text(
                      file.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Mono('+${file.additions}', color: c.pass),
                  const SizedBox(width: 6),
                  Mono('−${file.deletions}', color: c.fail),
                ],
              ),
              if (_openFiles.contains(file.path)) _FileLines(file),
            ],
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({super.key, required this.open, required this.onTap, required this.children});

  final bool open;
  final VoidCallback onTap;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: context.colors.textMuted),
          const SizedBox(width: 6),
          ...children,
        ],
      ),
    ),
  );
}

class _FileLines extends StatelessWidget {
  const _FileLines(this.file);

  final DiffFile file;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    var drawn = 0;
    var rest = 0;
    for (final hunk in file.hunks) {
      if (drawn >= kGateDiffFileLines) {
        rest += hunk.lines.length;
        continue;
      }
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
          child: Mono(hunk.header, size: 11, color: context.colors.textMuted),
        ),
      );
      for (final line in hunk.lines) {
        if (drawn < kGateDiffFileLines) {
          children.add(DiffLineView(line));
          drawn++;
        } else {
          rest++;
        }
      }
    }
    if (rest > 0) {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: Muted('mais ${countLabel(rest, 'linha')} neste arquivo', size: 11.5),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
