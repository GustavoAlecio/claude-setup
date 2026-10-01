import 'dart:convert';

/// Must match `version` in `engine/package.json`; a mismatch only raises a non-blocking warning.
const kEngineVersion = '0.1.0';

const kEnvSentinel = '\x00__ENV__\x00';

const kMissingEngineDir = 'configure engineDir em ~/.claude/workflow/.dashboard.json';
const kMissingNode = 'node não encontrado: defina nodePath em ~/.claude/workflow/.dashboard.json';
String missingNodeModules(String engineDir) => 'rode: cd $engineDir && npm ci';

/// Read-only view of `~/.claude/workflow/.dashboard.json`; unknown keys are ignored.
class DashboardConfig {
  const DashboardConfig({this.engineDir, this.nodePath, this.paletteSkills, this.cwds = const {}});

  static const empty = DashboardConfig();

  final String? engineDir;
  final String? nodePath;

  /// `null` when the key is absent: the palette then lists every skill.
  final List<String>? paletteSkills;
  final Map<String, String> cwds;

  /// Throws [FormatException] on invalid JSON; a non-object document yields [empty].
  static DashboardConfig parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) return empty;
    final skills = decoded['paletteSkills'];
    final cwds = decoded['cwds'];
    return DashboardConfig(
      engineDir: _nonEmpty(decoded['engineDir']),
      nodePath: _nonEmpty(decoded['nodePath']),
      paletteSkills: skills is List
          ? [
              for (final s in skills)
                if (s is String && s.isNotEmpty) s,
            ]
          : null,
      cwds: cwds is Map
          ? {
              for (final e in cwds.entries)
                if (e.key is String && _nonEmpty(e.value) != null) e.key as String: e.value as String,
            }
          : const {},
    );
  }

  static String? _nonEmpty(Object? value) => value is String && value.isNotEmpty ? value : null;
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

/// Engine dir: `--dart-define=ENGINE_DIR` → `engineDir`. Node: `nodePath` → `PATH` of [env].
EngineLaunchResult resolveEngineLaunch({
  required String engineDirDefine,
  required DashboardConfig config,
  required Map<String, String> env,
  required bool Function(String path) fileExists,
}) {
  final home = env['HOME'];
  String expand(String path) => home != null && path.startsWith('~/') ? '$home${path.substring(1)}' : path;

  final rawDir = engineDirDefine.isNotEmpty ? engineDirDefine : config.engineDir;
  if (rawDir == null) return const EngineLaunchError(kMissingEngineDir);
  final engineDir = _trimSlash(expand(rawDir));

  final node = _resolveNode(config.nodePath == null ? null : expand(config.nodePath!), env['PATH'], fileExists);
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
