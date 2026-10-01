import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import '../engine/engine_config.dart';
import 'config_mutations.dart';
import 'models.dart';
import 'project_scan.dart';

abstract interface class FlowRepository {
  Stream<List<Project>> watchProjects();
  Stream<Project?> watchProject(String name);
  Stream<Run?> watchRun(String project, String runId);
  Future<void> reload();

  /// Files changed in the project's working tree since [checkpoint]; empty when it cannot be computed.
  Future<List<FileStat>> numstat(String project, String checkpoint);

  /// Last valid `.dashboard.json`; an invalid file on disk keeps the previous value.
  Stream<DashboardConfig> watchConfig();

  /// Throws `ConfigWriteException` when the edit is rejected or the file cannot be written.
  Future<void> updateConfig(ConfigMutation mutation);

  Future<ProjectDir> inspectDirectory(String dir);

  /// Folders offered when creating the first org.
  Future<List<String>> suggestedRoots();
}

typedef FolderPicker = Future<String?> Function();

class RepositoryScope extends InheritedWidget {
  const RepositoryScope({
    super.key,
    required this.repository,
    this.pickDirectory = getDirectoryPath,
    required super.child,
  });

  final FlowRepository repository;
  final FolderPicker pickDirectory;

  static FlowRepository of(BuildContext context) => _scope(context).repository;

  static FolderPicker pickerOf(BuildContext context) => _scope(context).pickDirectory;

  static RepositoryScope _scope(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RepositoryScope>()!;

  @override
  bool updateShouldNotify(RepositoryScope oldWidget) =>
      repository != oldWidget.repository || pickDirectory != oldWidget.pickDirectory;
}
