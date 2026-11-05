import 'package:markdown/markdown.dart' as md;

const wikiLinkUnresolvedTag = 'wikilink';

/// `[[alvo|texto]]`. [resolve] recebe o alvo normalizado (último segmento depois de `/`, sem `.md`) e
/// devolve o id do ADR, ou `null`. Resolvido vira link `adr:<id>`; senão um nó que o `MarkdownView`
/// pinta em `textMuted`. Em código inline o `CodeSyntax` consome o trecho antes, então fica literal.
class WikiLinkSyntax extends md.InlineSyntax {
  WikiLinkSyntax(this.resolve) : super(r'\[\[([^\[\]|\n]+)(?:\|([^\[\]\n]*))?\]\]');

  final String? Function(String target) resolve;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final target = normalizeWikiTarget(match[1]!);
    final label = (match[2] ?? '').trim();
    final text = md.Text(label.isEmpty ? match[1]!.trim() : label);
    final id = resolve(target);
    if (id == null) {
      parser.addNode(md.Element(wikiLinkUnresolvedTag, [text]));
    } else {
      parser.addNode(md.Element('a', [text])..attributes['href'] = Uri(scheme: 'adr', path: id).toString());
    }
    return true;
  }
}

String normalizeWikiTarget(String raw) {
  final last = raw.trim().split('/').last.trim();
  return last.endsWith('.md') ? last.substring(0, last.length - 3) : last;
}
