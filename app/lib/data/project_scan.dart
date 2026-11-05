import 'dart:developer';
import 'dart:io';

import 'orgs.dart';
import 'project_name.dart';

/// Same list as `SKIP` in `engine/cwd.mjs`; a test compares both.
const kScanSkip = {'node_modules', '.git', 'build', 'dist', 'Pods', '.dart_tool', 'vendor', 'target'};

/// Same `depth` argument as `scan(root, name, 3, found)` in `engine/cwd.mjs`.
const kScanDepth = 3;

/// Directory name → candidate paths under [roots], mirroring `engine/cwd.mjs`: dot and [kScanSkip]
/// entries are skipped, symlinks are not followed and a directory is not a candidate for a name one
/// of its ancestors already matched (the engine stops descending at a match).
Future<Map<String, List<ScanCandidate>>> scanRoots(Iterable<String> roots) async {
  final index = <String, Map<String, int>>{};

  Future<void> walk(String dir, int depth, Set<String> ancestors) async {
    if (depth < 0) return;
    final List<FileSystemEntity> entries;
    try {
      entries = await Directory(dir).list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    for (final entry in entries) {
      final name = entry.path.split('/').last;
      if (entry is! Directory || name.startsWith('.') || kScanSkip.contains(name)) continue;
      if (!ancestors.contains(name)) {
        index.putIfAbsent(name, () => {}).putIfAbsent(entry.path, () => kScanDepth - depth);
      }
      await walk(entry.path, depth - 1, {...ancestors, name});
    }
  }

  for (final root in roots) {
    await walk(normalizePath(root), kScanDepth, const {});
  }
  return {
    for (final e in index.entries) e.key: [for (final c in e.value.entries) ScanCandidate(c.key, c.value)],
  };
}

/// Immediate, non-dot subdirectories of [base], sorted; empty when [base] does not exist.
Future<List<String>> listSubdirectories(String base) async {
  final dir = Directory(base);
  if (!await dir.exists()) return const [];
  final out = <String>[];
  try {
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is Directory && !entry.path.split('/').last.startsWith('.')) out.add(entry.path);
    }
  } on FileSystemException catch (e, st) {
    log('cannot list $base', name: 'project_scan', error: e, stackTrace: st);
    return const [];
  }
  return out..sort();
}

/// A folder picked to become a project: the git root (or the folder itself outside git) and its name.
class ProjectDir {
  const ProjectDir({required this.path, required this.name, this.divergence});

  final String path;
  final String name;

  /// Warning from [projectNameFor] when an older workflow dir under the raw basename wins.
  final String? divergence;
}

/// Resolves [dir] to its git root and names it with [projectNameFor]. In a worktree the raw basename is
/// the main repo's (via `--git-common-dir`), like `bin/get-project.sh`.
Future<ProjectDir> inspectDirectory(String dir, {required bool Function(String name) workflowExists}) async {
  final requested = normalizePath(dir);
  final top = await _git(requested, ['rev-parse', '--path-format=absolute', '--show-toplevel', '--git-common-dir']);
  final lines = top?.split('\n') ?? const <String>[];
  final root = lines.isNotEmpty && lines.first.isNotEmpty ? lines.first : requested;
  var rootBasename = _basename(root);
  if (lines.length > 1) {
    final common = normalizePath(lines[1]);
    if (common != '$root/.git' && common.endsWith('/.git')) rootBasename = _basename(parentPath(common));
  }
  final remote = top == null ? null : await _git(root, ['config', '--get', 'remote.origin.url']);
  final name = projectNameFor(
    rootBasename: rootBasename,
    remoteUrl: remote == null || remote.isEmpty ? null : remote,
    workflowExists: workflowExists,
  );
  return ProjectDir(path: root, name: name.name, divergence: name.divergence);
}

Future<String?> _git(String dir, List<String> args) async {
  try {
    final result = await Process.run('git', ['-C', dir, ...args]);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  } on ProcessException catch (e, st) {
    log('git unavailable for $dir', name: 'project_scan', error: e, stackTrace: st);
    return null;
  }
}

String _basename(String path) => normalizePath(path).split('/').last;
