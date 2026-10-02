import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/inline_markdown.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../data/docs_repository.dart';
import '../../data/report_models.dart';

/// Painéis do fechamento do ciclo: roteiro de QA, teste com dados reais e PR. Cada um só aparece com dados.
class ReportExtras extends StatelessWidget {
  const ReportExtras({super.key, required this.report});

  final ReportDoc? report;

  @override
  Widget build(BuildContext context) {
    final report = this.report;
    if (report == null) return const SizedBox.shrink();
    final panels = <Widget>[
      if (report.qa.isNotEmpty) _QaPanel(items: report.qa),
      if (report.hasRealData) _RealDataPanel(report: report),
      if (report.pr case final pr?) _PrPanel(pr: pr),
    ];
    if (panels.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final p in panels) Padding(padding: const EdgeInsets.only(top: 16), child: p)],
    );
  }
}

class _QaPanel extends StatelessWidget {
  const _QaPanel({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Panel(
      key: const ValueKey('flow-qa'),
      title: 'Roteiro de QA',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_box_outline_blank, size: 16, color: c.textMuted),
                  const SizedBox(width: 8),
                  Expanded(child: InlineMarkdown(item)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RealDataPanel extends StatelessWidget {
  const _RealDataPanel({required this.report});

  final ReportDoc report;

  @override
  Widget build(BuildContext context) {
    return Panel(
      key: const ValueKey('flow-real-data'),
      title: 'Teste com dados reais',
      child: switch (report.realDataMarkdown) {
        final md? => MarkdownView(md, onLink: (uri) => DocsScope.openExternal(context, uri, logName: 'ReportExtras')),
        null => Muted(report.realDataStatus ?? 'não executado', size: 13),
      },
    );
  }
}

class _PrPanel extends StatelessWidget {
  const _PrPanel({required this.pr});

  final ReportPr pr;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final uri = Uri.tryParse(pr.url);
    final label = pr.number == null ? 'PR' : 'PR #${pr.number}';
    return Panel(
      key: const ValueKey('flow-pr'),
      title: 'PR',
      child: Row(
        children: [
          if (uri == null || !opensExternally(uri))
            Expanded(child: Mono(pr.url))
          else ...[
            TextButton(
              key: const ValueKey('flow-pr-link'),
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => DocsScope.openExternal(context, uri, logName: 'ReportExtras'),
              child: Text(label, style: const TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(width: 8),
            Expanded(child: Muted(pr.url, size: 11)),
          ],
        ],
      ),
    );
  }
}
