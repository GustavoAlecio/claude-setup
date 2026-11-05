import 'package:claude_flow/core/theme/app_theme.dart';
import 'package:claude_flow/core/widgets/markdown_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _synthetic = '''# Titulo um
## Titulo dois
### Titulo tres
#### Titulo quatro
##### Titulo cinco
###### Titulo seis

Setext um
=========

Setext dois
-----------

- [ ] pendente
- [x] feito
  - aninhado a
    - aninhado b

Veja https://example.com/nua agora, **negrito**, *italico*, ~~tachado~~ e `codigo`.

| Nome | Valor | Nota |
|------|-------|------|
| a \\| b | 1 | x |
| c | 2 | y |

a < b && c

<div>html cru</div> e <span>inline</span>

> citacao

---
''';

Widget _host(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

String _plain(WidgetTester tester) {
  final b = StringBuffer();
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    b.writeln(w.textSpan?.toPlainText() ?? w.data ?? '');
  }
  return b.toString();
}

void main() {
  testWidgets('renders the synthetic source without raw markers or entities', (tester) async {
    await tester.pumpWidget(_host(MarkdownView(_synthetic, onLink: (_) {})));
    final text = _plain(tester);
    for (final raw in ['#', '**', '|---', '`', '[ ]', '[x]', '&lt;', '&amp;', '~~']) {
      expect(text.contains(raw), isFalse, reason: 'found "$raw" in:\n$text');
    }
    expect(text, contains('a < b && c'));
    expect(text, contains('<div>html cru</div>'));
    expect(text, contains('a | b'));
    expect(find.textContaining('☐'), findsOneWidget);
    expect(find.textContaining('☑'), findsOneWidget);
    expect(text, contains('https://example.com/nua'));
  });

  testWidgets('bare URL is a link that calls onLink', (tester) async {
    final calls = <Uri>[];
    await tester.pumpWidget(_host(MarkdownView(_synthetic, onLink: calls.add)));
    final rich = tester.widgetList<Text>(find.byType(Text)).map((t) => t.textSpan).whereType<TextSpan>();
    TapGestureRecognizer? found;
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.recognizer is TapGestureRecognizer && s.toPlainText().contains('example.com')) {
          found = s.recognizer as TapGestureRecognizer;
        }
        s.children?.forEach(walk);
      }
    }

    rich.forEach(walk);
    expect(found, isNotNull);
    found!.onTap!();
    expect(calls, [Uri.parse('https://example.com/nua')]);
  });

  testWidgets('three-column table', (tester) async {
    await tester.pumpWidget(_host(MarkdownView(_synthetic, onLink: (_) {})));
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(3));
    expect(table.children.first.children, hasLength(3));
  });

  testWidgets('two list levels render markers for each level', (tester) async {
    await tester.pumpWidget(_host(MarkdownView('- a\n  - b\n    - c\n', onLink: (_) {})));
    expect(find.text('•'), findsNWidgets(3));
    expect(find.textContaining('c'), findsWidgets);
  });

  testWidgets('mermaid block is labelled', (tester) async {
    await tester.pumpWidget(_host(MarkdownView('```mermaid\ngraph TD\nA-->B\n```\n', onLink: (_) {})));
    expect(find.text('mermaid'), findsOneWidget);
    expect(find.textContaining('A-->B'), findsOneWidget);
  });

  testWidgets('inline link and image alt', (tester) async {
    final calls = <Uri>[];
    await tester.pumpWidget(_host(MarkdownView('[doc](details/a.md) ![alt txt](x.png)', onLink: calls.add)));
    expect(_plain(tester), contains('alt txt'));
    expect(_plain(tester), isNot(contains('x.png')));
    final t = tester.widget<Text>(find.byType(Text).first);
    TapGestureRecognizer? r;
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.recognizer is TapGestureRecognizer) r = s.recognizer as TapGestureRecognizer;
        s.children?.forEach(walk);
      }
    }

    walk(t.textSpan!);
    r!.onTap!();
    expect(calls, [Uri.parse('details/a.md')]);
  });

  testWidgets('renders everything it receives, even a body that looks like front-matter', (tester) async {
    await tester.pumpWidget(_host(MarkdownView('---\nfoo bar\n---\ncorpo final', onLink: (_) {})));
    final text = _plain(tester);
    expect(text, contains('foo bar'));
    expect(text, contains('corpo final'));
  });

  testWidgets('wrapped in a SelectionArea', (tester) async {
    await tester.pumpWidget(_host(MarkdownView('texto', onLink: (_) {})));
    expect(find.byType(SelectionArea), findsOneWidget);
  });
}
