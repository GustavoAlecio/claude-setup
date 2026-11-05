import 'package:flutter/widgets.dart';

import 'models.dart';
import 'session_models.dart';

abstract interface class FlowRepository {
  Stream<List<Project>> watchProjects();
  Stream<Project?> watchProject(String name);
  Stream<Run?> watchRun(String project, String runId);
  List<SessionSummary> sessions();
  SessionSummary? session(String id);
  Future<void> reload();
}

class RepositoryScope extends InheritedWidget {
  const RepositoryScope({super.key, required this.repository, required super.child});

  final FlowRepository repository;

  static FlowRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RepositoryScope>()!.repository;

  @override
  bool updateShouldNotify(RepositoryScope oldWidget) => repository != oldWidget.repository;
}
