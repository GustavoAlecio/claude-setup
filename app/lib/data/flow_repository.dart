import 'package:flutter/widgets.dart';

import 'models.dart';

abstract interface class FlowRepository {
  Stream<List<Project>> watchProjects();
  Stream<Project?> watchProject(String name);
  Stream<Run?> watchRun(String project, String runId);
  Future<void> reload();

  /// Files changed in the project's working tree since [checkpoint]; empty when it cannot be computed.
  Future<List<FileStat>> numstat(String project, String checkpoint);
}

class RepositoryScope extends InheritedWidget {
  const RepositoryScope({super.key, required this.repository, required super.child});

  final FlowRepository repository;

  static FlowRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RepositoryScope>()!.repository;

  @override
  bool updateShouldNotify(RepositoryScope oldWidget) => repository != oldWidget.repository;
}
