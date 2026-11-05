import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../shell/shell_page.dart';

const _planned = {
  AppTab.metrics: (
    'Métricas',
    [
      'Tokens por modelo e por papel (dev/g0/g1/g2)',
      'Taxa de escalada por complexidade × risco',
      'Sugestões de tier0 do routing-stats',
    ],
  ),
  AppTab.adrs: (
    'ADRs',
    ['INDEX.md com status e affects', 'Grafo de supersedes e wikilinks', 'Quais ADRs casaram com os arquivos do ciclo'],
  ),
};

class PlannedPage extends StatelessWidget {
  const PlannedPage({super.key, required this.tab});

  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (title, items) = _planned[tab] ?? (tab.label, const <String>[]);
    return Center(
      child: SizedBox(
        width: 520,
        child: Panel(
          title: title,
          trailing: Pill(label: 'paridade · próxima etapa', color: c.idle, dot: false),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final i in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Muted('•  '),
                      Expanded(
                        child: Text(i, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
