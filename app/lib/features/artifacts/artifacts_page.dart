import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/doc_body.dart';
import '../../core/widgets/refresh_loop.dart';
import '../../core/widgets/primitives.dart';
import '../../data/docs_parser.dart';
import '../../data/docs_repository.dart';
import '../../data/models.dart';

class ArtifactsPage extends StatefulWidget {
  const ArtifactsPage({super.key, required this.projectName, this.doc});

  final String projectName;

  /// `?doc=` da rota; ausente ou fora da listagem → o 1º item, trocando a URL.
  final String? doc;

  @override
  State<ArtifactsPage> createState() => _ArtifactsPageState();
}

class _ArtifactsPageState extends State<ArtifactsPage> with RefreshLoop<ArtifactsPage> {
  DocsListing? _listing;
  ({DocEntry entry, DocText text})? _open;
  bool _started = false;

  @override
  String get logName => 'ArtifactsPage';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    refresh();
  }

  @override
  void didUpdateWidget(ArtifactsPage old) {
    super.didUpdateWidget(old);
    if (old.doc != widget.doc) refresh();
  }

  String _location(String rel) =>
      Uri(pathSegments: ['', 'p', widget.projectName, 'artifacts'], queryParameters: {'doc': rel}).toString();

  @override
  Future<void> sync() async {
    final repository = DocsScope.of(context);
    final project = widget.projectName;
    final listing = await repository.list(project);
    if (!mounted) return;
    setState(() => _listing = listing);
    final all = [...listing.artifacts, ...listing.details];
    final entry = all.where((e) => e.rel == widget.doc).firstOrNull;
    if (entry == null) {
      if (all.isNotEmpty) context.go(_location(all.first.rel));
      return;
    }
    if (_open?.entry == entry) return;
    final text = (await repository.read(project, entry.rel)).mapText(stripFrontMatter);
    if (!mounted) return;
    setState(() => _open = (entry: entry, text: text));
  }

  void _onLink(Uri uri) {
    if (opensExternally(uri)) {
      unawaited(DocsScope.openerOf(context)(uri));
      return;
    }
    final target = _projectDoc(uri);
    if (target == null) {
      log('link ignored: $uri', name: 'ArtifactsPage');
      return;
    }
    context.go(_location(target));
  }

  /// Link relativo resolvido a partir do documento aberto; só vale se cair num artefato listado.
  /// Compara o caminho decodificado (`my%20doc.md` abre `my doc.md`).
  String? _projectDoc(Uri uri) {
    if (uri.hasScheme || uri.hasAuthority || uri.path.isEmpty || uri.path.startsWith('/')) return null;
    final List<String> segments;
    try {
      segments = uri.pathSegments;
    } on FormatException {
      return null;
    }
    final parts = (_open?.entry.rel ?? '').split('/')..removeLast();
    for (final s in segments) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(s);
      }
    }
    final rel = parts.join('/');
    final listing = _listing;
    if (listing == null || !rel.endsWith('.md')) return null;
    final known = [...listing.artifacts, ...listing.details].any((e) => e.rel == rel);
    return known ? rel : null;
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
    if (refreshFailed) return const Center(child: Muted('não foi possível ler os artefatos', size: 13));
    final listing = _listing;
    if (listing == null) return const SizedBox.shrink();
    if (listing.artifacts.isEmpty && listing.details.isEmpty) {
      return const Center(child: Muted('nenhum artefato', size: 13));
    }
    final open = _open;
    final selected = open != null && open.entry.rel == widget.doc ? open : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ArtifactList(listing: listing, selected: widget.doc, onSelect: (rel) => context.go(_location(rel))),
        Expanded(
          child: switch (selected) {
            null => const SizedBox.shrink(),
            (:final entry, :final text) => DocBody(
              text,
              storageKey: PageStorageKey('artifact-${entry.rel}'),
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
              onLink: _onLink,
            ),
          },
        ),
      ],
    );
  }
}

class _ArtifactList extends StatelessWidget {
  const _ArtifactList({required this.listing, required this.selected, required this.onSelect});

  final DocsListing listing;
  final String? selected;
  final void Function(String rel) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget header(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 6), child: Muted(t, size: 10));
    return Container(
      width: 260,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          if (listing.artifacts.isNotEmpty) header('WORKFLOW'),
          for (final e in listing.artifacts)
            _ArtifactTile(label: e.rel, rel: e.rel, selected: e.rel == selected, onSelect: onSelect),
          if (listing.details.isNotEmpty) header('DETALHAMENTOS'),
          for (final e in listing.details)
            _ArtifactTile(label: _detailName(e.rel), rel: e.rel, selected: e.rel == selected, onSelect: onSelect),
        ],
      ),
    );
  }

  static String _detailName(String rel) {
    final base = rel.split('/').last;
    return base.endsWith('.md') ? base.substring(0, base.length - 3) : base;
  }
}

class _ArtifactTile extends StatelessWidget {
  const _ArtifactTile({required this.label, required this.rel, required this.selected, required this.onSelect});

  final String label;
  final String rel;
  final bool selected;
  final void Function(String rel) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: selected ? c.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: c.hover,
          onTap: () => onSelect(rel),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Tooltip(
              message: label,
              waitDuration: const Duration(milliseconds: 500),
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? c.textPrimary : c.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
