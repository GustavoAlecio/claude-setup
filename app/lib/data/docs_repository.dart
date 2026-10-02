import 'dart:async';
import 'dart:developer';

import 'package:flutter/widgets.dart';

import 'docs_parser.dart';

/// Arquivos acima disso não são lidos (o teto é exclusivo: exatamente o limite ainda é lido).
const kDocSizeLimit = 2 * 1024 * 1024;

typedef LinkOpener = Future<void> Function(Uri uri);

/// Só estes schemes saem para o sistema; `file:`, caminhos e `javascript:` abririam apps ou scripts locais.
bool opensExternally(Uri uri) => switch (uri.scheme) {
  'http' || 'https' => uri.host.isNotEmpty,
  'mailto' => uri.path.isNotEmpty,
  _ => false,
};

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

class DocText {
  const DocText.content(String this.text) : tooLarge = false, error = null;

  const DocText.tooLarge() : text = null, tooLarge = true, error = null;

  const DocText.error(String this.error) : text = null, tooLarge = false;

  final String? text;
  final bool tooLarge;
  final String? error;

  DocText mapText(String Function(String) f) => switch (text) {
    final t? => DocText.content(f(t)),
    _ => this,
  };
}

abstract interface class DocsRepository {
  /// [project] é o nome do diretório do projeto no workflow; diretório inexistente → [DocsListing.empty].
  Future<DocsListing> list(String project);

  /// Só `.md`, `.json` e `.diff` contidos no diretório do projeto; o resto vira [DocText.error].
  Future<DocText> read(String project, String rel);

  /// Recusa (com log) tudo que não passa em [opensExternally].
  Future<void> open(Uri uri);
}

class DocsScope extends InheritedWidget {
  const DocsScope({super.key, required this.repository, required this.opener, required super.child});

  final DocsRepository repository;
  final LinkOpener opener;

  static DocsRepository of(BuildContext context) => _scope(context).repository;

  static LinkOpener openerOf(BuildContext context) => _scope(context).opener;

  /// Abre [uri] no sistema se passar em [opensExternally]; senão só registra em [logName].
  static void openExternal(BuildContext context, Uri uri, {required String logName}) {
    if (opensExternally(uri)) {
      unawaited(openerOf(context)(uri));
    } else {
      log('link ignored: $uri', name: logName);
    }
  }

  static DocsScope _scope(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DocsScope>()!;

  @override
  bool updateShouldNotify(DocsScope oldWidget) => repository != oldWidget.repository || opener != oldWidget.opener;
}
