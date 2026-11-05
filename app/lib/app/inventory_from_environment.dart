import '../data/file_inventory_repository.dart';
import '../data/inventory_repository.dart';
import '../data/mock_inventory_repository.dart';
import '../core/claude_home.dart';

/// Same `REPO` define as [repositoryFromEnvironment]; the real root is [claudeHome].
InventoryRepository inventoryFromEnvironment() {
  const repo = String.fromEnvironment('REPO', defaultValue: 'file');
  switch (repo) {
    case 'mock':
      return MockInventoryRepository();
    case 'file':
      return FileInventoryRepository(claudeHome());
    default:
      throw ArgumentError.value(repo, 'REPO', 'use file ou mock');
  }
}
