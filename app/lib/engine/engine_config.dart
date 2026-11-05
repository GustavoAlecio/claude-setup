import 'dart:convert';

/// Must match `version` in `engine/package.json`; a mismatch only raises a non-blocking warning.
const kEngineVersion = '0.2.0';

const kEnvSentinel = '\x00__ENV__\x00';

const kMissingEngineDir = 'configure engineDir em ~/.claude/workflow/.dashboard.json';
const kMissingNode = 'node não encontrado: defina nodePath em ~/.claude/workflow/.dashboard.json';
String missingNodeModules(String engineDir) => 'rode: cd $engineDir && npm ci';

class OrgConfig {
  const OrgConfig({required this.name, this.roots = const []});

  final String name;
  final List<String> roots;
}

class ProjectEntry {
  const ProjectEntry({required this.name, this.path, this.org});

  final String name;
  final String? path;
  final String? org;
}

/// Read-only view of `~/.claude/workflow/.dashboard.json`; unknown keys are ignored.
class DashboardConfig {
  const DashboardConfig({
    this.engineDir,
    this.nodePath,
    this.paletteSkills,
    this.cwds = const {},
    this.orgs = const [],
    this.projects = const [],
    this.hidden = const [],
    this.lastOrg,
  });

  static const empty = DashboardConfig();

  final String? engineDir;
  final String? nodePath;

  /// `null` when the key is absent: the palette then lists every skill.
  final List<String>? paletteSkills;
  final Map<String, String> cwds;
  final List<OrgConfig> orgs;
  final List<ProjectEntry> projects;
  final List<String> hidden;
  final String? lastOrg;

  /// Throws [FormatException] on invalid JSON; a non-object document yields [empty].
  static DashboardConfig parse(String source) {
    final decoded = jsonDecode(source);
    return decoded is Map ? fromMap(decoded) : empty;
  }

  static DashboardConfig fromMap(Map<Object?, Object?> decoded) {
    final skills = decoded['paletteSkills'];
    final cwds = decoded['cwds'];
    return DashboardConfig(
      engineDir: _nonEmpty(decoded['engineDir']),
      nodePath: _nonEmpty(decoded['nodePath']),
      paletteSkills: skills is List ? _strings(skills) : null,
      cwds: cwds is Map
          ? {
              for (final e in cwds.entries)
                if (e.key is String && _nonEmpty(e.value) != null) e.key as String: e.value as String,
            }
          : const {},
      orgs: [
        for (final o in _maps(decoded['orgs']))
          if (_nonEmpty(o['name']) != null) OrgConfig(name: o['name'] as String, roots: _strings(o['roots'])),
      ],
      projects: [
        for (final p in _maps(decoded['projects']))
          if (_nonEmpty(p['name']) != null)
            ProjectEntry(name: p['name'] as String, path: _nonEmpty(p['path']), org: _nonEmpty(p['org'])),
      ],
      hidden: _strings(decoded['hidden']),
      lastOrg: _nonEmpty(decoded['lastOrg']),
    );
  }

  static String? _nonEmpty(Object? value) => value is String && value.isNotEmpty ? value : null;

  static List<String> _strings(Object? value) => [
    if (value is List)
      for (final s in value)
        if (s is String && s.isNotEmpty) s,
  ];

  static List<Map<Object?, Object?>> _maps(Object? value) => [
    if (value is List)
      for (final e in value)
        if (e is Map) e,
  ];
}

/// Parses the output of `printf '\0__ENV__\0'; env -0`. Everything before the sentinel is
/// rc-file noise (instant prompts, compinit warnings) and is dropped; `null` if the sentinel never came.
Map<String, String>? parseEnv0(String output) {
  final start = output.indexOf(kEnvSentinel);
  if (start < 0) return null;
  final env = <String, String>{};
  for (final entry in output.substring(start + kEnvSentinel.length).split('\x00')) {
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    env[entry.substring(0, eq)] = entry.substring(eq + 1);
  }
  return env;
}

final _readyLine = RegExp(r'^ENGINE_READY (\{.*\})$');

({int port, int pid})? parseReadyLine(String line) {
  final match = _readyLine.firstMatch(line.trimRight());
  if (match == null) return null;
  try {
    final decoded = jsonDecode(match.group(1)!);
    if (decoded is! Map) return null;
    final port = decoded['port'];
    final pid = decoded['pid'];
    if (port is! int || pid is! int) return null;
    return (port: port, pid: pid);
  } on FormatException {
    return null;
  }
}

sealed class EngineLaunchResult {
  const EngineLaunchResult();
}

class EngineLaunch extends EngineLaunchResult {
  const EngineLaunch({required this.node, required this.engineDir});

  final String node;
  final String engineDir;

  String get script => '$engineDir/index.mjs';
}

class EngineLaunchError extends EngineLaunchResult {
  const EngineLaunchError(this.message);

  final String message;
}

/// Define beats config; `~/` expands against [home] and a trailing slash is dropped. `null` when neither is set.
String? effectiveEngineDir({required String engineDirDefine, required DashboardConfig config, required String? home}) {
  final raw = engineDirDefine.isNotEmpty ? engineDirDefine : config.engineDir;
  return raw == null ? null : _trimSlash(_expandHome(raw, home));
}

String _expandHome(String path, String? home) =>
    home != null && path.startsWith('~/') ? '$home${path.substring(1)}' : path;

/// Engine dir: `--dart-define=ENGINE_DIR` → `engineDir`. Node: `nodePath` → `PATH` of [env].
EngineLaunchResult resolveEngineLaunch({
  required String engineDirDefine,
  required DashboardConfig config,
  required Map<String, String> env,
  required bool Function(String path) fileExists,
}) {
  final home = env['HOME'];
  final engineDir = effectiveEngineDir(engineDirDefine: engineDirDefine, config: config, home: home);
  if (engineDir == null) return const EngineLaunchError(kMissingEngineDir);

  final node = _resolveNode(
    config.nodePath == null ? null : _expandHome(config.nodePath!, home),
    env['PATH'],
    fileExists,
  );
  if (node == null) return const EngineLaunchError(kMissingNode);

  if (!fileExists('$engineDir/node_modules')) return EngineLaunchError(missingNodeModules(engineDir));
  return EngineLaunch(node: node, engineDir: engineDir);
}

String? _resolveNode(String? nodePath, String? path, bool Function(String) fileExists) {
  if (nodePath != null) return fileExists(nodePath) ? nodePath : null;
  for (final dir in (path ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final candidate = '${_trimSlash(dir)}/node';
    if (fileExists(candidate)) return candidate;
  }
  return null;
}

String _trimSlash(String path) => path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
