import '../data/http_sessions_repository.dart';
import '../data/mock_sessions.dart';
import '../data/sessions_repository.dart';
import '../engine/engine_supervisor.dart';
import '../core/claude_home.dart';
import 'mock_engine_controller.dart';

/// Same `REPO` define as [repositoryFromEnvironment]; `file` spawns the engine.
({SessionsRepository sessions, EngineController engine}) sessionsFromEnvironment() {
  const repo = String.fromEnvironment('REPO', defaultValue: 'file');
  switch (repo) {
    case 'mock':
      return (sessions: MockSessionsRepository(), engine: const MockEngineController());
    case 'file':
      final supervisor = EngineSupervisor(
        workflowRoot: workflowRootFromEnvironment(),
        claudeHome: claudeHome(),
        engineDirDefine: kEngineDirDefine,
      );
      return (sessions: HttpSessionsRepository(supervisor.endpoint), engine: supervisor);
    default:
      throw ArgumentError.value(repo, 'REPO', 'use file ou mock');
  }
}
