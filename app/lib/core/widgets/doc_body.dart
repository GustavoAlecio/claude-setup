import 'package:flutter/material.dart';

import '../../data/docs_repository.dart';
import 'markdown_view.dart';
import 'primitives.dart';

/// Conteúdo de um documento já lido: markdown rolável, ou o aviso de arquivo grande/erro.
class DocBody extends StatelessWidget {
  const DocBody(this.doc, {super.key, required this.storageKey, required this.padding, required this.onLink});

  final DocText doc;
  final PageStorageKey<String> storageKey;
  final EdgeInsets padding;
  final void Function(Uri) onLink;

  @override
  Widget build(BuildContext context) => switch (doc) {
    DocText(:final String text) => SingleChildScrollView(
      key: storageKey,
      padding: padding,
      child: MarkdownView(text, onLink: onLink),
    ),
    DocText(tooLarge: true) => const Center(child: Muted('arquivo grande demais', size: 13)),
    DocText(:final error) => Center(child: Muted(error ?? 'não foi possível ler', size: 13)),
  };
}
