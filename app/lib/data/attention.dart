import '../engine/engine_config.dart';
import 'flow_aggregates.dart';
import 'models.dart';
import 'orgs.dart';
import 'session_models.dart';
import 'session_reducer.dart';

/// Something that wants the user: a pending permission or question, a stopped cycle, a finished turn. [key] changes
/// when there is something new to say, so a notification fires once per occurrence.
class AttentionItem {
  const AttentionItem({required this.key, required this.title, required this.body, required this.route});

  final String key;
  final String title;
  final String body;
  final String route;
}

String sessionRoute(SessionSummary s) =>
    s.isOrgSession ? orgSessionsLocation(s.org!, session: s.id) : '/p/${s.project}/sessions/${s.id}';

String _where(SessionSummary s) => s.isOrgSession ? s.org! : s.project;

/// What is waiting on the user right now: sessions with pending requests and projects stopped on a decision.
List<AttentionItem> pendingAttention(List<SessionSummary> sessions, List<Project> projects) => [
  for (final s in sessions)
    if (pendingOf(s) > 0)
      AttentionItem(
        key: 'pending:${s.id}:${s.pendingPermissions}',
        title: 'Aguardando você · ${_where(s)}',
        body: s.title,
        route: sessionRoute(s),
      ),
  for (final p in projects)
    if (!p.hidden)
      if (blockedDecision(p) case final decision?)
        AttentionItem(
          key: 'blocked:${p.name}:${decision.run.id}:${decision.task.id}',
          title: 'Ciclo parado · ${p.name}',
          body: '${decision.task.id} · ${decision.task.title}: o diagnóstico espera a sua decisão',
          route: decisionLocation(p.name, decision),
        ),
];

/// Where "próxima pendência" (⌘J) goes from [location]: the item after the one shown there, wrapping around, else
/// the first; `null` when nothing waits.
String? nextAttentionRoute(List<AttentionItem> items, String location) {
  if (items.isEmpty) return null;
  final path = Uri.parse(location).path;
  final at = items.indexWhere((i) => Uri.parse(i.route).path == path);
  return items[(at + 1) % items.length].route;
}

/// Sessions whose turn just ended (running → idle/done) between [before] and [now].
List<AttentionItem> finishedTurns(Map<String, SessionStatus> before, List<SessionSummary> now) => [
  for (final s in now)
    if (before[s.id] == SessionStatus.running && (s.status == SessionStatus.idle || s.status == SessionStatus.done))
      AttentionItem(
        key: 'done:${s.id}:${DateTime.now().microsecondsSinceEpoch}',
        title: 'Turno concluído · ${_where(s)}',
        body: s.title,
        route: sessionRoute(s),
      ),
];

/// Dock badge: everything [pendingAttention] lists.
int attentionCount(List<SessionSummary> sessions, List<Project> projects) =>
    sessions.fold(0, (sum, s) => sum + pendingOf(s)) +
    projects.where((p) => !p.hidden && blockedDecision(p) != null).length;

/// The org at a glance ("Minha fila"): what waits on the user, what is running, cycles in progress, cycles done.
class OrgQueue {
  const OrgQueue({required this.waiting, required this.running, required this.cycles, required this.done});

  final List<AttentionItem> waiting;
  final List<SessionSummary> running;

  /// Projects with a cycle that is neither finished nor stopped on a decision.
  final List<Project> cycles;
  final List<Project> done;

  bool get isEmpty => waiting.isEmpty && running.isEmpty && cycles.isEmpty && done.isEmpty;
}

OrgQueue orgQueue(String org, List<SessionSummary> sessions, List<Project> projects, DashboardConfig? config) {
  final inOrg = [
    for (final s in sessions)
      if (sessionOrg(s, projects, config) == org) s,
  ];
  final orgProjects = [
    for (final p in projectsInOrg(projects, org))
      if (!p.hidden) p,
  ];
  return OrgQueue(
    waiting: pendingAttention(inOrg, orgProjects),
    running: [
      for (final s in inOrg)
        if (s.status == SessionStatus.running && pendingOf(s) == 0) s,
    ],
    cycles: [
      for (final p in orgProjects)
        if (p.cycle case final cycle? when cycle.stage != Stage.complete && blockedDecision(p) == null) p,
    ],
    done: [
      for (final p in orgProjects)
        if (p.cycle?.stage == Stage.complete) p,
    ],
  );
}
