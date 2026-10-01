import '../data/file_flow_repository.dart';
import '../data/flow_repository.dart';
import '../data/mock_flow_repository.dart';

FlowRepository repositoryFromEnvironment() {
  const repo = String.fromEnvironment('REPO', defaultValue: 'file');
  const root = String.fromEnvironment('WORKFLOW_ROOT');
  switch (repo) {
    case 'mock':
      return MockFlowRepository();
    case 'file':
      return FileFlowRepository(root.isEmpty ? FileFlowRepository.defaultRoot : root);
    default:
      throw ArgumentError.value(repo, 'REPO', 'use file ou mock');
  }
}
