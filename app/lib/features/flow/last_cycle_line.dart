import 'dart:developer';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/metrics_models.dart';
import '../../data/metrics_parser.dart';
import '../../data/metrics_repository.dart';
import '../../data/models.dart';
import 'cycle_report_dialog.dart';

/// "Último ciclo: feature — ver relatório (PR #n)" from the newest archived cycle that has a report;
/// nothing without one.
class LastCycleLine extends StatefulWidget {
  const LastCycleLine({super.key, required this.project});

  final Project project;

  @override
  State<LastCycleLine> createState() => _LastCycleLineState();
}

class _LastCycleLineState extends State<LastCycleLine> {
  CycleMetrics? _cycle;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    try {
      final metrics = await MetricsScope.of(context).loadProject(widget.project);
      if (!mounted) return;
      setState(() => _cycle = lastCycleWithReport(metrics));
    } on Exception catch (e, st) {
      log('cannot load last cycle', name: 'LastCycleLine', error: e, stackTrace: st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cycle = _cycle;
    if (cycle == null) return const SizedBox.shrink();
    final c = context.colors;
    final number = cycle.report?.pr?.number;
    return Row(
      key: const ValueKey('last-cycle'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            'Último ciclo: ${cycle.feature} — ',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: c.textMuted),
          ),
        ),
        TextButton(
          key: const ValueKey('last-cycle-open'),
          style: TextButton.styleFrom(
            foregroundColor: c.accent,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          onPressed: () => showCycleReport(context, cycle),
          child: Text(
            number == null ? 'ver relatório' : 'ver relatório (PR #$number)',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}
