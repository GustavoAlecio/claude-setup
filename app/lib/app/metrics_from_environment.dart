import '../core/claude_home.dart';
import '../data/file_metrics_repository.dart';
import '../data/metrics_repository.dart';
import '../data/mock_metrics_repository.dart';

/// Same `REPO` define as [repositoryFromEnvironment]; history under [claudeHome], current cycle under the workflow root.
MetricsRepository metricsFromEnvironment() {
  const repo = String.fromEnvironment('REPO', defaultValue: 'file');
  switch (repo) {
    case 'mock':
      return MockMetricsRepository.sample();
    case 'file':
      return FileMetricsRepository(claudeHome(), workflowRootFromEnvironment());
    default:
      throw ArgumentError.value(repo, 'REPO', 'use file ou mock');
  }
}
