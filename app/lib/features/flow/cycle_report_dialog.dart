import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/metrics_models.dart';
import 'report_extras.dart';
import 'stage_timeline.dart';

/// Relatório arquivado no mesmo componente do Fluxo, em modo leitura.
Future<void> showCycleReport(BuildContext context, CycleMetrics cycle) => showDialog<void>(
  context: context,
  builder: (context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: context.colors.canvas,
      child: SizedBox(
        width: 820,
        height: size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(child: Text(cycle.feature, style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(
                    tooltip: 'Fechar',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StageTimeline(key: const ValueKey('metrics-report-timeline'), report: cycle.report),
                    ReportExtras(report: cycle.report),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  },
);
