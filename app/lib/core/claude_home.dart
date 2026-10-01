import 'dart:io';

import '../data/orgs.dart';

const _claudeHomeDefine = String.fromEnvironment('CLAUDE_HOME');
const _workflowRootDefine = String.fromEnvironment('WORKFLOW_ROOT');
const kEngineDirDefine = String.fromEnvironment('ENGINE_DIR');

/// `CLAUDE_HOME`, else the parent of `WORKFLOW_ROOT` when defined, else `$HOME/.claude`.
String resolveClaudeHome({required String claudeHomeDefine, required String workflowRootDefine, String? home}) {
  if (claudeHomeDefine.isNotEmpty) return claudeHomeDefine;
  if (workflowRootDefine.isNotEmpty) return parentPath(workflowRootDefine);
  return '${home ?? ''}/.claude';
}

String claudeHome() => resolveClaudeHome(
  claudeHomeDefine: _claudeHomeDefine,
  workflowRootDefine: _workflowRootDefine,
  home: Platform.environment['HOME'],
);

String workflowRootFromEnvironment() =>
    _workflowRootDefine.isNotEmpty ? _workflowRootDefine : '${claudeHome()}/workflow';

/// What the Config tab shows as effective; built here because only `app/` reads defines and the environment.
class EffectivePaths {
  const EffectivePaths({this.home, required this.workflowRoot, this.engineDirDefine = ''});

  factory EffectivePaths.fromEnvironment() => EffectivePaths(
    home: Platform.environment['HOME'],
    workflowRoot: workflowRootFromEnvironment(),
    engineDirDefine: kEngineDirDefine,
  );

  final String? home;
  final String workflowRoot;
  final String engineDirDefine;
}
