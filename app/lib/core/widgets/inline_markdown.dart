import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Enough markdown for assistant turns: paragraphs, `- ` bullets, **bold** and `code`.
class InlineMarkdown extends StatelessWidget {
  const InlineMarkdown(this.source, {super.key, this.style});

  final String source;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = style ?? TextStyle(fontSize: 13, height: 1.5, color: c.textPrimary);
    final lines = source.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          if (line.trim().isEmpty)
            const SizedBox(height: 6)
          else if (line.startsWith('- '))
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: base.copyWith(color: c.textMuted)),
                  Expanded(child: Text.rich(TextSpan(children: _spans(line.substring(2), base, c)))),
                ],
              ),
            )
          else
            Text.rich(TextSpan(children: _spans(line, base, c))),
      ],
    );
  }

  static final _token = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`)');

  List<InlineSpan> _spans(String text, TextStyle base, AppColors c) {
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start), style: base));
      final t = m.group(0)!;
      out.add(
        t.startsWith('**')
            ? TextSpan(
                text: t.substring(2, t.length - 2),
                style: base.copyWith(fontWeight: FontWeight.w600),
              )
            : WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: c.elevated, borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    t.substring(1, t.length - 1),
                    style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.accent),
                  ),
                ),
              ),
      );
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last), style: base));
    return out;
  }
}
