import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/doc_body.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/refresh_loop.dart';
import '../../data/docs_models.dart';
import '../../data/docs_parser.dart';
import '../../data/docs_repository.dart';
import '../../data/models.dart';
import 'reviews_diff.dart';

class ReviewsPage extends StatefulWidget {
  const ReviewsPage({super.key, required this.projectName, this.pr});

  final String projectName;

  /// `?pr=` da rota; ausente ou fora da listagem → o 1º item, trocando a URL.
  final int? pr;

  @override
  State<ReviewsPage> createState() => _ReviewsPageState();
}

enum _SubTab { diff, report }

class _DiffLoad {
  const _DiffLoad({this.files = const [], this.tooLarge = false, this.error});

  final List<DiffFile> files;
  final bool tooLarge;
  final String? error;

  bool get usable => !tooLarge && error == null;
}

class _Review {
  const _Review({
    required this.entry,
    required this.report,
    required this.diff,
    required this.comments,
    required this.commentsIssue,
    required this.meta,
  });

  final ReviewEntry entry;
  final DocText report;

  /// `null` quando o PR não tem `.diff`.
  final _DiffLoad? diff;
  final List<ReviewComment> comments;
  final String? commentsIssue;
  final ReviewMeta? meta;
}

bool _sameStamps(ReviewEntry a, ReviewEntry b) =>
    a.report == b.report && a.diff == b.diff && a.comments == b.comments && a.meta == b.meta;

class _ReviewsPageState extends State<ReviewsPage> with RefreshLoop<ReviewsPage> {
  DocsListing? _listing;
  _Review? _review;
  List<DiffRow> _rows = const [];
  _SubTab? _tab;
  final _collapsed = <String>{};

  /// Paths que já receberam o estado inicial; uma releitura não reaplica a regra dos 400 sobre eles.
  final _known = <String>{};
  bool _started = false;

  @override
  String get logName => 'ReviewsPage';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    refresh();
  }

  @override
  void didUpdateWidget(ReviewsPage old) {
    super.didUpdateWidget(old);
    if (old.pr != widget.pr) refresh();
  }

  String _location(int pr) =>
      Uri(pathSegments: ['', 'p', widget.projectName, 'reviews'], queryParameters: {'pr': '$pr'}).toString();

  @override
  Future<void> sync() async {
    final repository = DocsScope.of(context);
    final project = widget.projectName;
    final listing = await repository.list(project);
    if (!mounted) return;
    setState(() => _listing = listing);
    final entry = listing.reviews.where((r) => r.number == widget.pr).firstOrNull;
    if (entry == null) {
      if (listing.reviews.isNotEmpty) context.go(_location(listing.reviews.first.number));
      return;
    }
    final current = _review;
    final old = current != null && current.entry.number == entry.number ? current : null;
    if (old != null && _sameStamps(old.entry, entry)) return;

    Future<DocText> read(DocEntry e) => repository.read(project, e.rel);
    final report = old != null && old.entry.report == entry.report
        ? old.report
        : (await read(entry.report)).mapText(stripFrontMatter);
    final diffEntry = entry.diff;
    final diff = diffEntry == null
        ? null
        : old != null && old.entry.diff == diffEntry
        ? old.diff
        : await _loadDiff(await read(diffEntry), diffEntry.size);
    final (comments, commentsIssue) = old != null && old.entry.comments == entry.comments
        ? (old.comments, old.commentsIssue)
        : await _loadComments(entry.comments, read);
    final meta = old != null && old.entry.meta == entry.meta
        ? old.meta
        : switch (entry.meta) {
            null => null,
            final e => switch (await read(e)) {
              DocText(:final String text) => parseReviewMeta(text),
              _ => null,
            },
          };
    if (!mounted || widget.pr != entry.number) return;

    setState(() {
      if (old == null) {
        _tab = null;
        _collapsed.clear();
        _known.clear();
      }
      final review = _Review(
        entry: entry,
        report: report,
        diff: diff,
        comments: comments,
        commentsIssue: commentsIssue,
        meta: meta,
      );
      _review = review;
      final perPath = <String, int>{};
      for (final c in comments) {
        perPath[c.path] = (perPath[c.path] ?? 0) + 1;
      }
      for (final f in diff?.files ?? const <DiffFile>[]) {
        if (!_known.add(f.path)) continue;
        if (startsCollapsed(f, perPath[f.path] ?? 0)) _collapsed.add(f.path);
      }
      _rows = _buildRows(review);
    });
  }

  static Future<_DiffLoad> _loadDiff(DocText text, int size) async => switch (text) {
    DocText(:final String text) => _DiffLoad(files: await parseDiffText(text, size)),
    DocText(tooLarge: true) => const _DiffLoad(tooLarge: true),
    DocText(:final error) => _DiffLoad(error: error ?? 'não foi possível ler o diff'),
  };

  static Future<(List<ReviewComment>, String?)> _loadComments(
    DocEntry? entry,
    Future<DocText> Function(DocEntry) read,
  ) async {
    if (entry == null) return (const <ReviewComment>[], 'sem comments.json');
    return switch (await read(entry)) {
      DocText(:final String text) => switch (parseReviewComments(text)) {
        (:final comments, valid: false) => (comments, 'comments.json inválido'),
        (:final comments, valid: true) => (comments, null),
      },
      DocText(tooLarge: true) => (const <ReviewComment>[], 'comments.json grande demais'),
      _ => (const <ReviewComment>[], 'comments.json inválido'),
    };
  }

  List<DiffRow> _buildRows(_Review review) {
    final diff = review.diff;
    final files = diff != null && diff.usable ? diff.files : const <DiffFile>[];
    return buildDiffRows(files, review.comments, _collapsed);
  }

  void _toggle(String path) => setState(() {
    if (!_collapsed.remove(path)) _collapsed.add(path);
    _rows = _buildRows(_review!);
  });

  void _onLink(Uri uri) {
    if (opensExternally(uri)) {
      unawaited(DocsScope.openerOf(context)(uri));
    } else {
      log('link ignored: $uri', name: 'ReviewsPage');
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(
      listenWhen: (_, s) => s.hasData,
      listener: (_, _) => refresh(),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (refreshFailed) return const Center(child: Muted('não foi possível ler os reviews', size: 13));
    final listing = _listing;
    if (listing == null) return const SizedBox.shrink();
    if (listing.reviews.isEmpty) {
      return const Center(child: Muted('nenhum review; rode /review em um PR', size: 13));
    }
    final review = _review;
    final shown = review != null && review.entry.number == widget.pr ? review : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReviewList(reviews: listing.reviews, selected: widget.pr, onSelect: (n) => context.go(_location(n))),
        Expanded(child: shown == null ? const SizedBox.shrink() : _detail(context, shown)),
      ],
    );
  }

  Widget _detail(BuildContext context, _Review review) {
    final hasDiff = review.diff != null;
    final tab = hasDiff ? (_tab ?? _SubTab.diff) : _SubTab.report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(review: review),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<_SubTab>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: _SubTab.diff, label: const Text('Diff + comentários'), enabled: hasDiff),
                const ButtonSegment(value: _SubTab.report, label: Text('Relatório')),
              ],
              selected: {tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
        ),
        Expanded(
          child: switch (tab) {
            _SubTab.diff => ReviewsDiff(
              storageKey: PageStorageKey('diff-${review.entry.number}'),
              rows: _rows,
              onToggle: _toggle,
              onLink: _onLink,
              warning: _diffWarning(review.diff!),
            ),
            _SubTab.report => DocBody(
              review.report,
              storageKey: PageStorageKey('report-${review.entry.number}'),
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
              onLink: _onLink,
            ),
          },
        ),
      ],
    );
  }

  static String? _diffWarning(_DiffLoad diff) {
    if (diff.tooLarge) return 'arquivo grande demais';
    if (diff.error != null) return diff.error;
    if (diff.files.isEmpty) return 'diff vazio';
    return null;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.review});

  final _Review review;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final meta = review.meta;
    final diff = review.diff;
    final DiffStats? stats = diff != null && diff.usable ? diffStats(diff.files) : meta?.stats;
    final counts = {for (final s in kSeverities) s: review.comments.where((x) => x.severity == s).length};
    final issues = [
      if (review.entry.meta == null) 'sem meta.json' else if (meta == null) 'meta.json inválido',
      ?review.commentsIssue,
    ];
    final head = meta?.headRefName;
    final base = meta?.baseRefName;
    final details = [
      if (meta?.author case final author?) Text('@$author', style: TextStyle(fontSize: 12, color: c.textSecondary)),
      if (head != null && base != null) Mono('$head → $base'),
      if (stats != null) ...[
        Text(
          '${stats.files} arquivos${stats.partial ? ' (parcial)' : ''}',
          style: TextStyle(fontSize: 12, color: c.textSecondary),
        ),
        Mono('+${stats.additions}', color: c.pass),
        Mono('−${stats.deletions}', color: c.fail),
      ],
      for (final MapEntry(key: severity, value: n) in counts.entries)
        if (n > 0) Pill(label: '$n $severity', color: severityColor(c, severity)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                review.entry.id,
                style: TextStyle(fontFamily: monoFamily, fontSize: 13, fontWeight: FontWeight.w600, color: c.textMuted),
              ),
              if (meta?.title case final title?) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: details),
          ],
          if (issues.isNotEmpty) ...[const SizedBox(height: 6), Muted(issues.join(' · '), size: 11)],
        ],
      ),
    );
  }
}

class _ReviewList extends StatelessWidget {
  const _ReviewList({required this.reviews, required this.selected, required this.onSelect});

  final List<ReviewEntry> reviews;
  final int? selected;
  final void Function(int number) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 180,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          for (final r in reviews)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Material(
                color: r.number == selected ? c.hover : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  hoverColor: c.hover,
                  onTap: () => onSelect(r.number),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Text(
                      r.id,
                      style: TextStyle(
                        fontFamily: monoFamily,
                        fontSize: 12.5,
                        fontWeight: r.number == selected ? FontWeight.w600 : FontWeight.w400,
                        color: r.number == selected ? c.textPrimary : c.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
