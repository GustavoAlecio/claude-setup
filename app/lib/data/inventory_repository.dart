import 'package:flutter/widgets.dart';

import 'inventory_models.dart';
import 'models.dart';

abstract interface class InventoryRepository {
  Future<Inventory> loadInventory();

  /// Projects without a path only get lessons and routing.
  Future<ProjectInventory> loadProject(Project project);
}

class InventoryScope extends InheritedWidget {
  const InventoryScope({super.key, required this.repository, required super.child});

  final InventoryRepository repository;

  static InventoryRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InventoryScope>()!.repository;

  @override
  bool updateShouldNotify(InventoryScope oldWidget) => repository != oldWidget.repository;
}
