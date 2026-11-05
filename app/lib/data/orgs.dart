import '../engine/engine_config.dart';
import 'models.dart';

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

/// Target of "Voltar" in Configurações and Sobre. An org switched there (⌘N) changed `lastOrg`; going back to a
/// project of the old org would make the shell write that org back, so the landing opens the new one instead.
String backTarget(String target, DashboardConfig? config, List<Project>? projects) {
  final project = routeProject(target);
  if (config == null || projects == null || project == null) return target;
  final org = projects.where((p) => p.name == project).firstOrNull?.org;
  return org == null || org == config.lastOrg ? target : '/';
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

/// Whether sessions of [project] belong to [org]: unknown projects (the engine keys sessions by
/// `basename(cwd)`) live in [kNoOrg]; hidden projects belong to none.
bool belongsToOrg(String project, List<Project> projects, String org) {
  final p = projects.where((p) => p.name == project).firstOrNull;
  return p == null ? org == kNoOrg : !p.hidden && p.org == org;
}

/// Pending permissions of the org, with the membership of [belongsToOrg].
int pendingInOrg(Map<String, int> pendingByProject, List<Project> projects, String org) {
  var total = 0;
  for (final e in pendingByProject.entries) {
    if (belongsToOrg(e.key, projects, org)) total += e.value;
  }
  return total;
}

/// Inside the shell the org is the route project's; an unknown or still-loading project keeps `lastOrg`.
String currentOrg(String? routeProject, List<Project> projects, DashboardConfig? config) =>
    projects.where((p) => p.name == routeProject).firstOrNull?.org ?? config?.lastOrg ?? kNoOrg;

/// [kNoOrg] is offered (switcher and landing alike) when it has a visible project or a pending session,
/// so a pending session of an unknown project stays reachable.
bool offersNoOrg(List<Project> projects, Map<String, int> pending) =>
    projectsInOrg(projects, kNoOrg).isNotEmpty || pendingInOrg(pending, projects, kNoOrg) > 0;

/// Orgs offered by the switcher: configured ones in order, plus [kNoOrg] per [offersNoOrg].
List<String> switchableOrgs(DashboardConfig? config, List<Project> projects, Map<String, int> pending) => [
  for (final o in config?.orgs ?? const <OrgConfig>[]) o.name,
  if (offersNoOrg(projects, pending)) kNoOrg,
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
    if (!names.add(name)) return 'já existe uma org chamada "$name"';
    for (final root in org.roots) {
      if (normalizePath(root).isEmpty) return 'informe uma pasta para "$name"';
    }
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
Landing landingFor(DashboardConfig config, List<Project> projects, Map<String, int> pending) {
  if (config.orgs.isEmpty) return const CreateOrgLanding();
  final options = switchableOrgs(config, projects, pending);
  final last = config.lastOrg;
  if (last != null && options.contains(last)) return OpenOrgLanding(last);
  return ChooseOrgLanding(options);
}
