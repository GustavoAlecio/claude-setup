import 'github_models.dart';
import 'models.dart';
import 'orgs.dart';
import 'project_name.dart';

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<String> _strings(Object? v) => [if (v is List) ...v.whereType<String>()];

ReviewThread parseReviewThread(Object? json) {
  final m = json is Map ? json : const {};
  final line = m['line'];
  return ReviewThread(
    path: _str(m['path']),
    line: line is int ? line : null,
    author: m['author'] is String ? m['author'] as String : '',
    body: m['body'] is String ? m['body'] as String : '',
  );
}

PullRequest parsePullRequest(Object? json) {
  final m = json is Map ? json : const {};
  final number = m['pr_number'];
  final ado = m['ado_id'];
  final checks = m['checks'];
  return PullRequest(
    number: number is int ? number : null,
    adoId: ado is int ? '$ado' : _str(ado),
    branch: _str(m['branch']),
    target: _str(m['target']),
    title: m['title'] is String ? m['title'] as String : '',
    url: _str(m['url']),
    stage: m['stage'] is String ? m['stage'] as String : '',
    openedAt: _date(m['opened_at']),
    repo: _str(m['repo']),
    nameWithOwner: _str(m['nameWithOwner']),
    cwd: _str(m['cwd']),
    cwdCandidates: _strings(m['cwdCandidates']),
    cwdReason: _str(m['cwdReason']),
    live: m['live'] == true,
    liveError: _str(m['liveError']),
    checks: PrChecks.values.where((c) => c.name == checks).firstOrNull,
    unresolved: [if (m['unresolved'] is List) ...(m['unresolved'] as List).map(parseReviewThread)],
    updatedAt: _date(m['updatedAt']),
    mergedAt: _date(m['mergedAt']),
  );
}

/// Body of `GET /api/projects/:name/prs`.
List<PullRequest> parsePullRequests(Object? json) {
  final prs = json is Map ? json['prs'] : null;
  return [if (prs is List) ...prs.whereType<Map<Object?, Object?>>().map(parsePullRequest)];
}

/// Items without an integer `number` are dropped: they cannot be reviewed.
Inbox parseInbox(Object? json) {
  final m = json is Map ? json : const {};
  final items = m['items'];
  return Inbox(
    login: _str(m['login']),
    items: [
      if (items is List)
        for (final raw in items.whereType<Map<Object?, Object?>>())
          if (raw['number'] is int)
            InboxItem(
              number: raw['number'] as int,
              title: raw['title'] is String ? raw['title'] as String : '',
              url: _str(raw['url']),
              repo: raw['repo'] is String ? raw['repo'] as String : '',
              nameWithOwner: raw['nameWithOwner'] is String ? raw['nameWithOwner'] as String : '',
              author: raw['author'] is String ? raw['author'] as String : '',
              updatedAt: _date(raw['updatedAt']),
              isDraft: raw['isDraft'] == true,
              cwd: _str(raw['cwd']),
              cwdCandidates: _strings(raw['cwdCandidates']),
              cwdReason: _str(raw['cwdReason']),
            ),
    ],
  );
}

/// "agora" < 60 s, then minutes, hours and days (< 30 d), then `dd/MM/aaaa`; `null` is "—".
String relativeAge(DateTime? then, DateTime now) {
  if (then == null) return '—';
  final diff = now.difference(then);
  if (diff.inSeconds < 60) return 'agora';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'há ${diff.inHours} h';
  if (diff.inDays < 30) return 'há ${diff.inDays} d';
  final d = then.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// `merged`, `closed`, `closed_*` and `deployed_*`; an unknown stage is not closed.
bool isClosedStage(String stage) =>
    stage == 'merged' || stage == 'closed' || stage.startsWith('closed_') || stage.startsWith('deployed_');

bool canResolve(PullRequest pr) => pr.unresolved.isNotEmpty && !isClosedStage(pr.stage);

enum StageColorRole { accent, warn, pass, idle }

String stageLabel(String stage) => switch (stage) {
  'awaiting_review' => 'aguardando review',
  'changes_requested' => 'mudanças pedidas',
  'approved' => 'aprovado',
  'merged' => 'mergeado',
  'draft' => 'rascunho',
  'closed' => 'fechado',
  _ => stage,
};

StageColorRole stageColorRole(String stage) => switch (stage) {
  'awaiting_review' => StageColorRole.accent,
  'changes_requested' => StageColorRole.warn,
  'approved' || 'merged' => StageColorRole.pass,
  _ => StageColorRole.idle,
};

/// The app's path for a project named like the repo, only when it is the `cwd` the engine validated by
/// remote. `cwdCandidates` are never remote-checked (ambiguous scan, or the one whose remote diverged),
/// so a known path among them does not count.
String? _validatedCwd(String? repo, String? cwd, List<Project> projects) {
  if (cwd == null || repo == null || repo.isEmpty) return cwd;
  final dashed = repo.replaceAll('_', '-');
  final here = normalizePath(cwd);
  final known = projects.where((p) => p.name == repo || p.name == dashed).firstOrNull?.path;
  return known != null && normalizePath(known) == here ? known : cwd;
}

String? prCwd(PullRequest pr, List<Project> projects) => _validatedCwd(pr.repo, pr.cwd, projects);

String? inboxCwd(InboxItem item, List<Project> projects) => _validatedCwd(item.repo, item.cwd, projects);

/// `owner/repo` when the owner differs from the first row's or another row has the same `repo` under
/// another owner; otherwise just `repo`. [all] holds the `(repo, nameWithOwner)` of every row.
String repoLabel(String? repo, String? nameWithOwner, Iterable<(String?, String?)> all) {
  String? nonEmpty(String? v) => v == null || v.isEmpty ? null : v;
  final full = nonEmpty(nameWithOwner);
  final short = nonEmpty(repo) ?? full ?? '—';
  if (full == null) return short;
  String? owner(String? nwo) => nonEmpty(nwo)?.split('/').first.toLowerCase();
  final firstOwner = owner(all.firstOrNull?.$2);
  final clash = all.any((o) => o.$1 == repo && nonEmpty(o.$2) != null && o.$2!.toLowerCase() != full.toLowerCase());
  return firstOwner != owner(full) || clash ? full : short;
}

/// Repos without a usable checkout, split into none at all and several candidates.
({List<String> missing, List<(String, int)> ambiguous}) inboxFooter(List<InboxItem> items, List<Project> projects) {
  final missing = <String>[];
  final ambiguous = <String, int>{};
  for (final item in items) {
    if (inboxCwd(item, projects) != null) continue;
    final name = item.repo.isEmpty ? item.nameWithOwner : item.repo;
    if (item.cwdCandidates.length > 1) {
      ambiguous[name] = item.cwdCandidates.length;
    } else if (!missing.contains(name)) {
      missing.add(name);
    }
  }
  return (missing: missing, ambiguous: [for (final e in ambiguous.entries) (e.key, e.value)]);
}

/// Known project whose canonical path equals the item's `cwd`; otherwise the naming rule of [projectNameFor].
String reviewProjectName(
  InboxItem item,
  List<Project> projects, {
  Canonical canonical = normalizePath,
  bool Function(String name)? workflowExists,
}) {
  final cwd = inboxCwd(item, projects);
  if (cwd != null) {
    final here = canonical(cwd);
    for (final p in projects) {
      final path = p.path;
      if (path != null && canonical(path) == here) return p.name;
    }
  }
  final basename = cwd == null ? item.repo : normalizePath(cwd).split('/').last;
  return projectNameFor(
    rootBasename: basename.isEmpty ? item.repo : basename,
    remoteUrl: item.nameWithOwner.isEmpty ? null : 'https://github.com/${item.nameWithOwner}',
    workflowExists: workflowExists ?? (name) => projects.any((p) => p.name == name),
  ).name;
}
