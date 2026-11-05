import '../engine/engine_config.dart';
import 'models.dart';
import 'session_models.dart';
import 'session_reducer.dart';

/// Resolves symlinks for an existing path and returns the input unchanged when it does not exist.
typedef Canonical = String Function(String path);

/// Trailing slashes are dropped so `/a/b/` and `/a/b` compare equal; `/` stays `/`.
String normalizePath(String path) {
  var end = path.length;
  while (end > 1 && path[end - 1] == '/') {
    end--;
  }
  return path.substring(0, end);
}

/// `/a/b/` → `/a`; the parent of a top-level entry is `/`.
String parentPath(String path) {
  final p = normalizePath(path);
  final i = p.lastIndexOf('/');
  return i <= 0 ? '/' : p.substring(0, i);
}

/// Project name of a `/p/<name>/...` location; `null` for any other route.
String? routeProject(String location) {
  final segments = Uri.parse(location).pathSegments;
  return segments.length >= 2 && segments.first == 'p' ? segments[1] : null;
}

/// `/p/<project>/…` and `/o/<org>/…`: the routes the shell wraps.
bool isShellLocation(String location) {
  final segments = Uri.parse(location).pathSegments;
  return segments.length >= 2 && (segments.first == 'p' || segments.first == 'o');
}

/// Config entry of [org]; `null` for [kNoOrg] and for a name the config does not have.
OrgConfig? orgConfigOf(DashboardConfig? config, String org) => config?.orgs.where((o) => o.name == org).firstOrNull;

/// Org of a shell location: `/p/<project>` → the project's org (`null` while it is unknown), `/o/<org>` → `<org>`;
/// `null` for any other route.
String? routeOrg(String location, List<Project> projects) {
  if (!isShellLocation(location)) return null;
  final segments = Uri.parse(location).pathSegments;
  return switch (segments.first) {
    'p' => projects.where((p) => p.name == segments[1]).firstOrNull?.org,
    'o' => segments[1],
    _ => null,
  };
}

/// `/o/<org>/sessions[/<session>]`, encoded segment by segment: org names may carry spaces and accents.
String orgSessionsLocation(String org, {String? session}) =>
    Uri(pathSegments: ['', 'o', org, 'sessions', ?session]).toString();

/// Where an org opens: its first visible project, else its activities when it has roots; `null` when it has
/// neither, so the caller keeps the landing.
String? orgHome(String org, List<Project> projects, DashboardConfig? config) {
  if (projectsInOrg(projects, org).firstOrNull case final first?) return '/p/${first.name}/flow';
  final roots = config?.orgs.where((o) => o.name == org).firstOrNull?.roots ?? const <String>[];
  return roots.isEmpty ? null : orgSessionsLocation(org);
}

/// Target of "Voltar" in Configurações and Sobre. An org switched there (⌘N) changed `lastOrg`; going back to a
/// shell route of the old org would make the shell write that org back, so the landing opens the new one instead.
String backTarget(String target, DashboardConfig? config, List<Project>? projects) {
  if (config == null || projects == null) return target;
  final org = routeOrg(target, projects);
  return org == null || org == config.lastOrg ? target : '/';
}

/// Org sessions of [org], resolved by [sessionOrg]: what its "Atividades da org" counts and lists.
List<SessionSummary> orgActivities(
  List<SessionSummary> sessions,
  List<Project> projects,
  DashboardConfig? config,
  String org,
) => [
  for (final s in sessions)
    if (s.isOrgSession && sessionOrg(s, projects, config) == org) s,
];

/// First pending session of [org], as a label name and the route that lists it (the page auto-selects the pending
/// one): its project's sessions for a project session, the org's activities for an org session. `null` when nothing of the org waits.
({String name, String location})? firstPendingInOrg(
  List<SessionSummary> sessions,
  List<Project> projects,
  DashboardConfig? config,
  String org,
) {
  for (final s in sessions) {
    if (pendingOf(s) == 0 || sessionOrg(s, projects, config) != org) continue;
    return s.isOrgSession
        ? (name: org, location: orgSessionsLocation(org))
        : (name: s.project, location: '/p/${s.project}/sessions');
  }
  return null;
}

/// Org the palette's "Nova atividade" (⌘⇧K and the shell menu item) targets from [location]: the route's org
/// inside the shell (an unknown project keeps `lastOrg`, as the shell shows), the landing's org on `/`;
/// `null` elsewhere (Settings, About, the org chooser).
String? paletteOrg(
  String location,
  DashboardConfig config,
  List<Project> projects, {
  List<SessionSummary> sessions = const [],
}) {
  if (Uri.parse(location).path == '/') {
    return switch (landingFor(config, projects, sessions)) {
      OpenOrgLanding(:final org) => org,
      _ => null,
    };
  }
  if (!isShellLocation(location)) return null;
  final project = routeProject(location);
  return project != null ? currentOrg(project, projects, config) : routeOrg(location, projects);
}

/// Segment-wise prefix: `/dev/r10` contains `/dev/r10/app` but not `/dev/r10x`.
bool containsPath(String root, String path) {
  final r = normalizePath(root);
  final p = normalizePath(path);
  return p == r || (r == '/' ? p.startsWith('/') : p.startsWith('$r/'));
}

bool overlaps(String a, String b) => containsPath(a, b) || containsPath(b, a);

/// `explicit` wins when it names a known org (or [kNoOrg]); otherwise the first org whose root contains the path.
String orgOf(String? path, {String? explicit, required List<OrgConfig> orgs, required Canonical canonical}) {
  if (explicit != null && (explicit == kNoOrg || orgs.any((o) => o.name == explicit))) return explicit;
  if (path == null) return kNoOrg;
  final target = canonical(path);
  for (final org in orgs) {
    for (final root in org.roots) {
      if (containsPath(canonical(root), target)) return org.name;
    }
  }
  return kNoOrg;
}

/// A directory found by the root scan; [depth] counts segments below the scanned root (`<root>/x` is 0).
class ScanCandidate {
  const ScanCandidate(this.path, this.depth);

  final String path;
  final int depth;
}

/// `projects[].path` → `current.json.project_path` → `cwds[name]` → shallowest scan candidate, `null`
/// when several share the shallowest depth. Same rule as `resolveCwd` in `engine/cwd.mjs`.
String? resolvePath({
  required String name,
  String? registeredPath,
  String? projectPath,
  Map<String, String> cwds = const {},
  Map<String, List<ScanCandidate>> scanIndex = const {},
}) {
  if (registeredPath != null) return registeredPath;
  if (projectPath != null) return projectPath;
  final cwd = cwds[name];
  if (cwd != null) return cwd;
  final candidates = scanIndex[name];
  if (candidates == null || candidates.isEmpty) return null;
  final shallowest = candidates.map((c) => c.depth).reduce((a, b) => a < b ? a : b);
  final best = [
    for (final c in candidates)
      if (c.depth == shallowest) c.path,
  ];
  return best.length == 1 ? best.single : null;
}

/// Union of the workflow-dir projects ([raw], whose `path` is `project_path`) and the registered ones,
/// each with path, org, hidden and registered filled in. Hidden projects stay in the list, flagged.
List<Project> annotateProjects(
  List<Project> raw,
  DashboardConfig config, {
  required Canonical canonical,
  Map<String, List<ScanCandidate>> scanIndex = const {},
}) {
  final entries = {for (final e in config.projects) e.name: e};
  final hidden = config.hidden.toSet();

  Project annotate(Project p, ProjectEntry? entry) {
    final path = resolvePath(
      name: p.name,
      registeredPath: entry?.path,
      projectPath: p.path,
      cwds: config.cwds,
      scanIndex: scanIndex,
    );
    return p.copyWith(
      path: path,
      org: orgOf(path, explicit: entry?.org, orgs: config.orgs, canonical: canonical),
      hidden: hidden.contains(p.name),
      registered: entry != null,
    );
  }

  final seen = <String>{};
  return [
    for (final p in raw)
      if (seen.add(p.name)) annotate(p, entries[p.name]),
    for (final e in config.projects)
      if (seen.add(e.name)) annotate(Project(name: e.name), e),
  ];
}

List<Project> projectsInOrg(List<Project> projects, String org) => [
  for (final p in projects)
    if (!p.hidden && p.org == org) p,
];

/// Org a session belongs to; `null` for a session of a hidden project, which belongs to none.
///
/// Project session: unknown projects (the engine keys sessions by `basename(cwd)`) live in [kNoOrg].
/// Org session: its `org` while the config still has it, else the org whose root holds its `cwd`, so a
/// renamed org keeps its sessions; [kNoOrg] once no org claims it.
String? sessionOrg(SessionSummary session, List<Project> projects, DashboardConfig? config) {
  final orgs = config?.orgs ?? const <OrgConfig>[];
  if (session.org case final org?) {
    if (orgs.any((o) => o.name == org)) return org;
    return orgOf(session.cwd, orgs: orgs, canonical: normalizePath);
  }
  final p = projects.where((p) => p.name == session.project).firstOrNull;
  if (p == null) return kNoOrg;
  return p.hidden ? null : p.org;
}

/// Pending permissions of the org's sessions, project and org sessions alike, with the membership of [sessionOrg].
int pendingInOrg(List<SessionSummary> sessions, List<Project> projects, DashboardConfig? config, String org) {
  var total = 0;
  for (final s in sessions) {
    if (sessionOrg(s, projects, config) == org) total += pendingOf(s);
  }
  return total;
}

/// `cwd` and `additionalDirectories` of an org session: the first root and the others, in config order;
/// `null` when the org has no roots.
(String, List<String>)? orgSessionDirs(OrgConfig org) =>
    org.roots.isEmpty ? null : (org.roots.first, org.roots.sublist(1));

const _pipelineCommands = {
  '/kickoff', '/specify', '/challenge-spec', '/plan', '/tasks', '/implement', '/verify', '/complete', '/fix', //
};

/// Newest live session of [project] (not an org session) whose command starts with a pipeline skill; it is the
/// stage in progress when the project has no cycle yet.
SessionSummary? runningStageSession(List<SessionSummary> sessions, Project project) {
  SessionSummary? best;
  DateTime? bestAt;
  for (final s in sessions) {
    if (s.isOrgSession || s.project != project.name) continue;
    if (s.status != SessionStatus.running &&
        s.status != SessionStatus.idle &&
        s.status != SessionStatus.waitingPermission) {
      continue;
    }
    final command = s.command.trimLeft().split(RegExp(r'\s'));
    if (!_pipelineCommands.contains(command.first)) continue;
    final at = DateTime.tryParse(s.createdAt);
    if (best == null || (at != null && (bestAt == null || at.isAfter(bestAt)))) {
      best = s;
      bestAt = at;
    }
  }
  return best;
}

/// Sessions of [project] (not of an org) holding a request the user can still answer, oldest first.
List<SessionSummary> pendingProjectSessions(List<SessionSummary> sessions, String project) {
  final out = [
    for (final s in sessions)
      if (pendingOf(s) > 0 && !s.isOrgSession && s.project == project) s,
  ];
  return out..sort((a, b) => a.createdAt.compareTo(b.createdAt));
}

/// Inside the shell the org is the route project's; an unknown or still-loading project keeps `lastOrg`.
String currentOrg(String? routeProject, List<Project> projects, DashboardConfig? config) =>
    projects.where((p) => p.name == routeProject).firstOrNull?.org ?? config?.lastOrg ?? kNoOrg;

/// [kNoOrg] is offered (switcher and landing alike) when it has a visible project or a pending session,
/// so a pending session of an unknown project stays reachable.
bool offersNoOrg(List<Project> projects, List<SessionSummary> sessions, DashboardConfig? config) =>
    projectsInOrg(projects, kNoOrg).isNotEmpty || pendingInOrg(sessions, projects, config, kNoOrg) > 0;

/// Orgs offered by the switcher: configured ones in order, plus [kNoOrg] per [offersNoOrg].
List<String> switchableOrgs(DashboardConfig? config, List<Project> projects, List<SessionSummary> sessions) => [
  for (final o in config?.orgs ?? const <OrgConfig>[]) o.name,
  if (offersNoOrg(projects, sessions, config)) kNoOrg,
];

enum ConfigChange {
  /// Only presentation changed (`lastOrg`, `hidden`, org names/assignments, engine keys).
  reemit,

  /// The set of roots changed: rescan paths without re-reading `current.json`/runs.
  rescan,

  /// A project's `name`/`path` or `cwds` changed: full reload.
  reload,
}

ConfigChange diffConfig(DashboardConfig before, DashboardConfig after) {
  if (!_sameCwds(before.cwds, after.cwds) || !_sameProjects(before.projects, after.projects)) {
    return ConfigChange.reload;
  }
  final rootsBefore = {for (final o in before.orgs) ...o.roots.map(normalizePath)};
  final rootsAfter = {for (final o in after.orgs) ...o.roots.map(normalizePath)};
  if (rootsBefore.length != rootsAfter.length || !rootsBefore.containsAll(rootsAfter)) return ConfigChange.rescan;
  return ConfigChange.reemit;
}

bool _sameCwds(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// `org` is left out: it only feeds [annotateProjects], so re-emitting is enough.
bool _sameProjects(List<ProjectEntry> a, List<ProjectEntry> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].name != b[i].name || a[i].path != b[i].path) return false;
  }
  return true;
}

/// First violation as an inline message, or `null` when the list is valid.
String? validateOrgs(List<OrgConfig> orgs) {
  final names = <String>{};
  for (final org in orgs) {
    final name = org.name.trim();
    if (name.isEmpty) return 'informe um nome para a org';
    if (name == kNoOrg) return '"$kNoOrg" é um nome reservado';
    if (name.contains('/')) return 'o nome da org não pode ter "/"';
    if (!names.add(name)) return 'já existe uma org chamada "$name"';
    for (final root in org.roots) {
      if (normalizePath(root).isEmpty) return 'informe uma pasta para "$name"';
    }
    final account = org.github?.account;
    if (account != null && !kGithubLogin.hasMatch(account)) return 'conta do GitHub inválida: "$account" em "$name"';
    if (validateOwners(org.github?.owners ?? const []) case final error?) return '$error em "$name"';
  }
  for (var i = 0; i < orgs.length; i++) {
    for (var j = i + 1; j < orgs.length; j++) {
      for (final a in orgs[i].roots) {
        for (final b in orgs[j].roots) {
          if (overlaps(a, b)) return 'a pasta $a de "${orgs[i].name}" sobrepõe $b de "${orgs[j].name}"';
        }
      }
    }
  }
  return null;
}

/// First invalid or repeated (ignoring case) GitHub owner, as an inline message; `null` when all are valid.
String? validateOwners(List<String> owners) {
  final seen = <String>{};
  for (final owner in owners) {
    if (!kGithubLogin.hasMatch(owner)) return 'org do GitHub inválida: "$owner"';
    if (!seen.add(owner.toLowerCase())) return 'org do GitHub repetida: "$owner"';
  }
  return null;
}

/// GitHub account and owners an org's PRs, inbox and sessions run with.
class GithubScope {
  const GithubScope({this.account, this.owners = const []});

  static const none = GithubScope();

  /// `null`: the `gh` active account.
  final String? account;

  /// Empty: no `--owner` filter.
  final List<String> owners;

  @override
  bool operator ==(Object other) =>
      other is GithubScope && other.account == account && sameStrings(other.owners, owners);

  @override
  int get hashCode => Object.hash(account, Object.hashAll(owners));

  @override
  String toString() => 'GithubScope($account, $owners)';
}

/// [GithubScope.none] for [kNoOrg], for an org the config does not have and for one without `github`.
GithubScope githubFor(String? orgName, DashboardConfig? config) {
  final github = orgName == null ? null : orgConfigOf(config, orgName)?.github;
  return github == null ? GithubScope.none : GithubScope(account: github.account, owners: github.owners);
}

/// Mode a new session is created with: [sessionChoice] > the org's `permissionMode` > the global one. [kNoOrg], an
/// org the config does not have and a `null` config fall through to the next level.
PermissionMode effectivePermissionMode(PermissionMode? sessionChoice, String? orgName, DashboardConfig? config) =>
    sessionChoice ??
    (orgName == null ? null : orgConfigOf(config, orgName)?.permissionMode) ??
    config?.permissionMode ??
    kDefaultPermissionMode;

/// Org and permission mode of a [cwd] for launching a session (Resolver, Revisar): the org of the known project
/// at that path (if its path exactly matches), else the org whose root holds it, else [kNoOrg]. The mode is the
/// effective one for that org and config.
({String org, PermissionMode mode}) launchOrg(String cwd, List<Project> projects, DashboardConfig? config) {
  final here = normalizePath(cwd);
  final project = projects.where((p) => p.path != null && normalizePath(p.path!) == here).firstOrNull;
  final org = project?.org ?? orgOf(cwd, orgs: config?.orgs ?? const [], canonical: normalizePath);
  return (org: org, mode: effectivePermissionMode(null, org, config));
}

sealed class Landing {
  const Landing();
}

/// No org configured: the landing shows the "Criar org" form.
class CreateOrgLanding extends Landing {
  const CreateOrgLanding();
}

class OpenOrgLanding extends Landing {
  const OpenOrgLanding(this.org);

  final String org;
}

class ChooseOrgLanding extends Landing {
  const ChooseOrgLanding(this.options);

  final List<String> options;
}

/// [projects] must already be annotated; the options are [switchableOrgs].
Landing landingFor(DashboardConfig config, List<Project> projects, List<SessionSummary> sessions) {
  if (config.orgs.isEmpty) return const CreateOrgLanding();
  final options = switchableOrgs(config, projects, sessions);
  final last = config.lastOrg;
  if (last != null && options.contains(last)) return OpenOrgLanding(last);
  return ChooseOrgLanding(options);
}
