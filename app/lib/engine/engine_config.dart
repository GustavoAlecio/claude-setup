import 'dart:convert';

/// Must match `version` in `engine/package.json`; a mismatch only raises a non-blocking warning.
const kEngineVersion = '0.8.0';

const kEnvSentinel = '\x00__ENV__\x00';

const kMissingEngineDir = 'configure engineDir em ~/.claude/workflow/.dashboard.json';
const kMissingNode = 'node não encontrado: defina nodePath em ~/.claude/workflow/.dashboard.json';
String missingNodeModules(String engineDir) => 'rode: cd $engineDir && npm ci';

/// GitHub login format: also what the engine accepts for `account` and `owner`.
final kGithubLogin = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$');

/// `orgs[].github`: [account] `null` is the `gh` active account; [owners] empty means no filter.
class OrgGithub {
  const OrgGithub({this.account, this.owners = const []});

  final String? account;
  final List<String> owners;

  /// `null` when [value] is not a map. An [account] that is not a login becomes `null`; invalid owners and case-insensitive duplicates are dropped.
  static OrgGithub? fromRaw(Object? value) {
    if (value is! Map) return null;
    final account = value['account'];
    final owners = value['owners'];
    final seen = <String>{};
    return OrgGithub(
      account: account is String && kGithubLogin.hasMatch(account) ? account : null,
      owners: [
        if (owners is List)
          for (final o in owners)
            if (o is String && kGithubLogin.hasMatch(o) && seen.add(o.toLowerCase())) o,
      ],
    );
  }

  Map<String, Object?> toRaw() => {'account': account, 'owners': owners};

  @override
  bool operator ==(Object other) => other is OrgGithub && other.account == account && sameStrings(other.owners, owners);

  @override
  int get hashCode => Object.hash(account, Object.hashAll(owners));
}

/// Modes the engine accepts in `POST /api/sessions` and `/permission-mode`; [wire] is the SDK spelling.
enum PermissionMode {
  defaultMode('default'),
  acceptEdits('acceptEdits'),
  auto('auto'),
  bypassPermissions('bypassPermissions'),
  plan('plan');

  const PermissionMode(this.wire);

  final String wire;

  /// `null` for anything that is not one of the accepted spellings, so the next level applies.
  static PermissionMode? parse(Object? raw) => values.where((m) => m.wire == raw).firstOrNull;

  /// A mode `.dashboard.json` may hold: [plan] only applies to one session, since as a default it would leave the
  /// whole pipeline unable to edit.
  static PermissionMode? parseConfig(Object? raw) => kConfigPermissionModes.where((m) => m.wire == raw).firstOrNull;
}

/// Modes the global and org pickers offer and the config accepts.
const kConfigPermissionModes = [
  PermissionMode.defaultMode,
  PermissionMode.acceptEdits,
  PermissionMode.auto,
  PermissionMode.bypassPermissions,
];

/// Global mode when `.dashboard.json` has no valid `permissionMode`: edits run, commands ask. Bypass is opt-in and
/// confirmed in the pickers ([confirmBypass]).
const kDefaultPermissionMode = PermissionMode.acceptEdits;

/// Who runs a session: the Claude Agent SDK or the Antigravity CLI (`agy`), ADR 0023.
enum AgentProvider {
  anthropic('anthropic', 'Anthropic'),
  antigravity('antigravity', 'Antigravity');

  const AgentProvider(this.wire, this.label);

  final String wire;
  final String label;

  static AgentProvider? parse(Object? raw) => values.where((p) => p.wire == raw).firstOrNull;
}

/// Antigravity account label: also the directory of its shadow HOME in the engine.
final kAgentAccount = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$');

/// Antigravity account that uses the IDE login (macOS Keychain).
const kDefaultAgentAccount = 'default';

/// `orgs[].agent`. [account] only applies to Antigravity (`null` = [kDefaultAgentAccount]); [model] `null` is the
/// provider's default.
class OrgAgent {
  const OrgAgent({this.provider = AgentProvider.anthropic, this.account, this.model});

  static const anthropic = OrgAgent();

  final AgentProvider provider;
  final String? account;
  final String? model;

  /// `null` when [value] is not a map; an unknown provider is Anthropic, an invalid account `null`.
  static OrgAgent? fromRaw(Object? value) {
    if (value is! Map) return null;
    final account = value['account'];
    final model = value['model'];
    return OrgAgent(
      provider: AgentProvider.parse(value['provider']) ?? AgentProvider.anthropic,
      account: account is String && kAgentAccount.hasMatch(account) ? account : null,
      model: model is String && model.trim().isNotEmpty ? model.trim() : null,
    );
  }

  Map<String, Object?> toRaw() => {'provider': provider.wire, 'account': ?account, 'model': ?model};

  /// Same agent with [model]; `null` is the provider default.
  OrgAgent withModel(String? model) => OrgAgent(provider: provider, account: account, model: model);

  @override
  bool operator ==(Object other) =>
      other is OrgAgent && other.provider == provider && other.account == account && other.model == model;

  @override
  int get hashCode => Object.hash(provider, account, model);

  @override
  String toString() => 'OrgAgent(${provider.wire}, $account, $model)';
}

bool sameStrings(List<String> a, List<String> b) =>
    a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

class OrgConfig {
  const OrgConfig({
    required this.name,
    this.roots = const [],
    this.github,
    this.permissionMode,
    this.agent,
    this.cycleBudget,
  });

  final String name;
  final List<String> roots;

  /// `null` when the key is absent: writes then keep whatever the file has.
  final OrgGithub? github;

  /// `null`: inherits [DashboardConfig.permissionMode] (key absent or not an accepted mode).
  final PermissionMode? permissionMode;

  /// `null` when the key is absent: sessions run on Anthropic and writes keep whatever the file has.
  final OrgAgent? agent;

  /// US$ a cycle of this org may cost; `null` inherits [DashboardConfig.cycleBudget].
  final double? cycleBudget;
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
    this.permissionMode = kDefaultPermissionMode,
    this.cycleBudget,
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
  final PermissionMode permissionMode;

  /// US$ a cycle may cost before the Fluxo warns; `null` (absent, zero or invalid) means no budget.
  final double? cycleBudget;

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
          if (_nonEmpty(o['name']) != null)
            OrgConfig(
              name: o['name'] as String,
              roots: _strings(o['roots']),
              github: OrgGithub.fromRaw(o['github']),
              permissionMode: PermissionMode.parseConfig(o['permissionMode']),
              agent: OrgAgent.fromRaw(o['agent']),
              cycleBudget: parseBudget(o['cycleBudget']),
            ),
      ],
      projects: [
        for (final p in _maps(decoded['projects']))
          if (_nonEmpty(p['name']) != null)
            ProjectEntry(name: p['name'] as String, path: _nonEmpty(p['path']), org: _nonEmpty(p['org'])),
      ],
      hidden: _strings(decoded['hidden']),
      lastOrg: _nonEmpty(decoded['lastOrg']),
      permissionMode: PermissionMode.parseConfig(decoded['permissionMode']) ?? kDefaultPermissionMode,
      cycleBudget: parseBudget(decoded['cycleBudget']),
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

/// A positive amount of US$; anything else is no budget.
double? parseBudget(Object? value) => value is num && value > 0 ? value.toDouble() : null;
