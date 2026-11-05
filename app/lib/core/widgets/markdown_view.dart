import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Renders GitHub-flavored markdown as selectable widgets. Raw HTML and unknown nodes render as literal
/// text; the caller decides what each link tap does.
class MarkdownView extends StatefulWidget {
  const MarkdownView(this.source, {super.key, required this.onLink, this.style});

  final String source;
  final void Function(Uri) onLink;
  final TextStyle? style;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  late List<md.Node> _nodes = _parse(widget.source);
  final _recognizers = <TapGestureRecognizer>[];

  static List<md.Node> _parse(String source) {
    final doc = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false);
    return doc.parseLines(source.split(RegExp(r'\r?\n')));
  }

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _nodes = _parse(widget.source);
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final c = context.colors;
    final base = widget.style ?? TextStyle(fontSize: 13, height: 1.5, color: c.textPrimary);
    final builder = _Builder(c, base, widget.onLink, _recognizers);
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: builder.flow(_nodes)),
    );
  }
}

class _Builder {
  _Builder(this.c, this.base, this.onLink, this.recognizers);

  final AppColors c;
  final TextStyle base;
  final void Function(Uri) onLink;
  final List<TapGestureRecognizer> recognizers;

  static const _inlineTags = {'strong', 'em', 'del', 'code', 'a', 'img', 'br', 'input'};

  static bool _isInline(md.Node n) => n is md.Text || (n is md.Element && _inlineTags.contains(n.tag));

  Widget _gap(Widget child, [double bottom = 10]) => Padding(
    padding: EdgeInsets.only(bottom: bottom),
    child: child,
  );

  List<Widget> flow(List<md.Node> nodes, {double gap = 10}) {
    final out = <Widget>[];
    final run = <md.Node>[];
    void flush() {
      if (run.isEmpty) return;
      final spans = inline(run, base);
      if (spans.isNotEmpty) out.add(_gap(Text.rich(TextSpan(children: spans, style: base)), gap));
      run.clear();
    }

    for (final n in nodes) {
      if (_isInline(n)) {
        run.add(n);
      } else {
        flush();
        out.add(_gap(block(n as md.Element), gap));
      }
    }
    flush();
    return out;
  }

  Widget block(md.Element e) {
    switch (e.tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        return heading(e);
      case 'p':
        return Text.rich(TextSpan(children: inline(e.children ?? const [], base), style: base));
      case 'ul':
      case 'ol':
        return list(e);
      case 'pre':
        return codeBlock(e);
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.borderStrong, width: 3)),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: c.textSecondary),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: flow(e.children ?? const [], gap: 6)),
          ),
        );
      case 'hr':
        return Container(height: 1, color: c.border);
      case 'table':
        return table(e);
      default:
        return Text(e.textContent, style: base);
    }
  }

  Widget heading(md.Element e) {
    final level = int.parse(e.tag.substring(1));
    final size = switch (level) {
      1 => 22.0,
      2 => 18.0,
      3 => 15.0,
      _ => 13.0,
    };
    final style = base.copyWith(fontSize: size, fontWeight: FontWeight.w600, height: 1.3);
    return Padding(
      padding: EdgeInsets.only(top: level <= 2 ? 6 : 2),
      child: Text.rich(TextSpan(children: inline(e.children ?? const [], style), style: style)),
    );
  }

  Widget list(md.Element e) {
    final ordered = e.tag == 'ol';
    var index = int.tryParse(e.attributes['start'] ?? '') ?? 1;
    final items = <Widget>[];
    for (final li in (e.children ?? const <md.Node>[]).whereType<md.Element>()) {
      final marker = ordered ? '${index++}.' : '•';
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: ordered ? 26 : 18,
                child: Text(marker, style: base.copyWith(color: c.textMuted)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: flow(li.children ?? const [], gap: 3),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: items),
    );
  }

  Widget codeBlock(md.Element pre) {
    final code = pre.children?.whereType<md.Element>().firstOrNull;
    final lang = (code?.attributes['class'] ?? '').replaceFirst('language-', '').trim();
    final text = pre.textContent.replaceFirst(RegExp(r'\n$'), '');
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lang == 'mermaid')
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Text(
                'mermaid',
                style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: c.textMuted),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            child: Text(
              text,
              style: TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.45, color: c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget table(md.Element e) {
    final rows = <List<md.Element>>[];
    final headerRows = <bool>[];
    for (final section in (e.children ?? const <md.Node>[]).whereType<md.Element>()) {
      for (final tr in (section.children ?? const <md.Node>[]).whereType<md.Element>()) {
        rows.add((tr.children ?? const <md.Node>[]).whereType<md.Element>().toList());
        headerRows.add(section.tag == 'thead');
      }
    }
    final columns = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    if (columns == 0) return const SizedBox.shrink();
    Widget cell(md.Element? td, bool header) {
      final style = header ? base.copyWith(fontWeight: FontWeight.w600) : base;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text.rich(TextSpan(children: inline(td?.children ?? const [], style), style: style)),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: c.border),
        children: [
          for (var i = 0; i < rows.length; i++)
            TableRow(
              decoration: headerRows[i] ? BoxDecoration(color: c.elevated) : null,
              children: [for (var j = 0; j < columns; j++) cell(j < rows[i].length ? rows[i][j] : null, headerRows[i])],
            ),
        ],
      ),
    );
  }

  List<InlineSpan> inline(List<md.Node> nodes, TextStyle style) {
    final out = <InlineSpan>[];
    for (final n in nodes) {
      if (n is md.Text) {
        out.add(TextSpan(text: n.text, style: style));
        continue;
      }
      final e = n as md.Element;
      final kids = e.children ?? const <md.Node>[];
      switch (e.tag) {
        case 'strong':
          out.addAll(inline(kids, style.copyWith(fontWeight: FontWeight.w600)));
        case 'em':
          out.addAll(inline(kids, style.copyWith(fontStyle: FontStyle.italic)));
        case 'del':
          out.addAll(inline(kids, style.copyWith(decoration: TextDecoration.lineThrough)));
        case 'code':
          out.add(
            TextSpan(
              text: e.textContent,
              style: style.copyWith(
                fontFamily: monoFamily,
                fontSize: (style.fontSize ?? 13) - 1,
                color: c.accent,
                backgroundColor: c.elevated,
              ),
            ),
          );
        case 'a':
          final uri = Uri.tryParse(e.attributes['href'] ?? '');
          final linkStyle = style.copyWith(color: c.accent, decoration: TextDecoration.underline);
          if (uri == null) {
            out.addAll(inline(kids, style));
          } else {
            final recognizer = TapGestureRecognizer()..onTap = () => onLink(uri);
            recognizers.add(recognizer);
            out.add(TextSpan(children: inline(kids, linkStyle), recognizer: recognizer, style: linkStyle));
          }
        case 'img':
          out.add(TextSpan(text: e.attributes['alt'] ?? '', style: style));
        case 'br':
          out.add(TextSpan(text: '\n', style: style));
        case 'input':
          out.add(TextSpan(text: e.attributes.containsKey('checked') ? '☑ ' : '☐ ', style: style));
        default:
          out.add(TextSpan(text: e.textContent, style: style));
      }
    }
    return out;
  }
}
