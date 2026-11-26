import 'dart:async';
import 'dart:developer';

import 'package:flutter/widgets.dart';

import 'docs_models.dart';

/// Arquivos acima disso não são lidos (o teto é exclusivo: exatamente o limite ainda é lido).
const kDocSizeLimit = 2 * 1024 * 1024;

typedef LinkOpener = Future<void> Function(Uri uri);

/// Só estes schemes saem para o sistema; `file:`, caminhos e `javascript:` abririam apps ou scripts locais.
bool opensExternally(Uri uri) => switch (uri.scheme) {
  'http' || 'https' => uri.host.isNotEmpty,
  'mailto' => uri.path.isNotEmpty,
  _ => false,
};

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
  /// [project] é o nome do diretório do projeto no workflow. Pasta ausente dá [DocsListing.empty]; erro de IO ao listar
  /// lança, e quem chama decide como mostrar a falha.
  Future<DocsListing> list(String project);

  /// Só `.md`, `.json` e `.diff` contidos no diretório do projeto; o resto vira [DocText.error].
  Future<DocText> read(String project, String rel);

  /// Recusa (com log) tudo que não passa em [opensExternally].
  Future<void> open(Uri uri);

  /// Mostra no Finder um arquivo contido no diretório do projeto (mesma regra de [read]); `false` se recusou.
  Future<bool> reveal(String project, String rel);
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
