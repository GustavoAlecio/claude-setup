import '../data/file_flow_repository.dart';
import '../data/http_sessions_repository.dart';
import '../data/mock_sessions.dart';
import '../data/sessions_repository.dart';
import '../engine/engine_supervisor.dart';
import 'mock_engine_controller.dart';

/// Same `REPO`/`WORKFLOW_ROOT` defines as [repositoryFromEnvironment]; `file` spawns the engine.
({SessionsRepository sessions, EngineController engine}) sessionsFromEnvironment() {
  const repo = String.fromEnvironment('REPO', defaultValue: 'file');
  const root = String.fromEnvironment('WORKFLOW_ROOT');
  const engineDir = String.fromEnvironment('ENGINE_DIR');
  switch (repo) {
    case 'mock':
      return (sessions: MockSessionsRepository(), engine: const MockEngineController());
    case 'file':
      final supervisor = EngineSupervisor(
        workflowRoot: root.isEmpty ? FileFlowRepository.defaultRoot : root,
        engineDirDefine: engineDir,
      );
      return (sessions: HttpSessionsRepository(supervisor.endpoint), engine: supervisor);
    default:
      throw ArgumentError.value(repo, 'REPO', 'use file ou mock');
  }
}
