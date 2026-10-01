import '../core/claude_home.dart';
import '../data/docs_repository.dart';
import '../data/file_docs_repository.dart';
import '../data/mock_docs_repository.dart';

/// Same `REPO` define as [repositoryFromEnvironment], over the same workflow root.
DocsRepository docsFromEnvironment() {
  const repo = String.fromEnvironment('REPO', defaultValue: 'file');
  switch (repo) {
    case 'mock':
      return MockDocsRepository();
    case 'file':
      return FileDocsRepository(workflowRootFromEnvironment());
    default:
      throw ArgumentError.value(repo, 'REPO', 'use file ou mock');
  }
}
