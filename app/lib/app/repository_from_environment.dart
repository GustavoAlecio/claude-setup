import '../data/file_flow_repository.dart';
import '../data/flow_repository.dart';
import '../data/mock_flow_repository.dart';
import '../core/claude_home.dart';

FlowRepository repositoryFromEnvironment() {
  const repo = String.fromEnvironment('REPO', defaultValue: 'file');
  switch (repo) {
    case 'mock':
      return MockFlowRepository();
    case 'file':
      return FileFlowRepository(workflowRootFromEnvironment());
    default:
      throw ArgumentError.value(repo, 'REPO', 'use file ou mock');
  }
}
