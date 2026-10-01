import 'package:flutter/widgets.dart';

import 'metrics_models.dart';
import 'models.dart';

/// Teto por arquivo lido (`trace.jsonl`, `metrics.json`, `current.json`).
const kMetricsFileLimit = 2 * 1024 * 1024;

abstract interface class MetricsRepository {
  /// Histórico do projeto mais o ciclo atual, quando ele já tem trace.
  Future<ProjectMetrics> loadProject(Project project);
}

class MetricsScope extends InheritedWidget {
  const MetricsScope({super.key, required this.repository, required super.child});

  final MetricsRepository repository;

  static MetricsRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MetricsScope>()!.repository;

  @override
  bool updateShouldNotify(MetricsScope oldWidget) => repository != oldWidget.repository;
}
