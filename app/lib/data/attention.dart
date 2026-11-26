import '../engine/engine_config.dart';
import 'flow_aggregates.dart';
import 'github_models.dart';
import 'models.dart';
import 'orgs.dart';
import 'session_models.dart';
import 'session_reducer.dart';

/// What an [AttentionItem] is about: a request on an open gate, any other pending request, a cycle stopped on a
/// decision, a turn that just ended.
enum AttentionKind { gate, request, blocked, finished }

/// Something that wants the user: a pending permission or question, a stopped cycle, a finished turn. [key] changes
/// when there is something new to say, so a notification fires once per occurrence.
class AttentionItem {
  const AttentionItem({
    required this.key,
    required this.title,
    required this.body,
    required this.route,
    required this.kind,
    this.project,
    this.sessionId,
    this.pending = 0,
    this.gate,
  });

  final String key;
  final String title;
  final String body;
  final String route;
  final AttentionKind kind;

  /// `null` for an org session.
  final String? project;

  /// `null` for [AttentionKind.blocked] and for a gate without a conversation ([isOrphanGate]).
  final String? sessionId;

  /// Pending requests of the session in [AttentionKind.gate] and [AttentionKind.request]; 0 otherwise.
  final int pending;

  /// Gate name when [kind] is [AttentionKind.gate].
  final String? gate;

  /// An open gate whose conversation is not open in the app: it counts and shows in the inbox, but there is nothing
  /// to answer, so it neither notifies nor plays the alert.
  bool get isOrphanGate => kind == AttentionKind.gate && sessionId == null;
}

String sessionRoute(SessionSummary s) =>
    s.isOrgSession ? orgSessionsLocation(s.org!, session: s.id) : '/p/${s.project}/sessions/${s.id}';

String _where(SessionSummary s) => s.isOrgSession ? s.org! : s.project;

/// A session stopped on an open gate is answered on the gate screen; any other request stays in the session.
({String? gate, String route}) _pendingRoute(SessionSummary s, List<Project> projects) {
  if (!s.isOrgSession) {
    final report = gateReport(projects.where((p) => p.name == s.project).firstOrNull?.cycle);
    if (sessionGate(report, s.id) case final gate?) return (gate: gate.name, route: gateLocation(s.project, gate.name));
  }
  return (gate: null, route: sessionRoute(s));
}

/// What is waiting on the user right now: sessions with pending requests, open gates without a conversation and
/// projects stopped on a decision.
List<AttentionItem> pendingAttention(List<SessionSummary> sessions, List<Project> projects) => [
  for (final s in sessions)
    if (pendingOf(s) > 0)
      if (_pendingRoute(s, projects) case final target)
        AttentionItem(
          key: 'pending:${s.id}:${s.pendingPermissions}',
          title: 'Aguardando você · ${_where(s)}',
          body: s.title,
          route: target.route,
          kind: target.gate == null ? AttentionKind.request : AttentionKind.gate,
          project: s.isOrgSession ? null : s.project,
          sessionId: s.id,
          pending: s.pendingPermissions,
          gate: target.gate,
        ),
  for (final (:project, :stage) in orphanGates(sessions, projects))
    AttentionItem(
      key: 'gate:${project.name}:${stage.gate!.name}:${stage.gate!.round}',
      title: 'Gate aberto · ${project.name}',
      body: 'A conversa deste gate não está aberta no app.',
      route: gateLocation(project.name, stage.gate!.name),
      kind: AttentionKind.gate,
      project: project.name,
      gate: stage.gate!.name,
    ),
  for (final p in projects)
    if (!p.hidden)
      if (blockedDecision(p) case final decision?)
        AttentionItem(
          key: 'blocked:${p.name}:${decision.run.id}:${decision.task.id}',
          title: 'Ciclo parado · ${p.name}',
          body: '${decision.task.id} · ${blockedTaskText(decision.task).detail}',
          route: decisionLocation(p.name, decision),
          kind: AttentionKind.blocked,
          project: p.name,
        ),
];

/// Pending requests per session id and the keys of the blocked items; finished turns and gates without a
/// conversation do not count.
class AttentionSnapshot {
  const AttentionSnapshot({required this.pending, required this.blocked});

  factory AttentionSnapshot.of(List<AttentionItem> items) {
    final pending = <String, int>{};
    final blocked = <String>{};
    for (final item in items) {
      switch (item.kind) {
        case AttentionKind.gate || AttentionKind.request:
          if (item.sessionId case final id?) pending[id] = item.pending;
        case AttentionKind.blocked:
          blocked.add(item.key);
        case AttentionKind.finished:
          break;
      }
    }
    return AttentionSnapshot(pending: pending, blocked: blocked);
  }

  final Map<String, int> pending;
  final Set<String> blocked;
}

/// Minimum gap between two alert sounds; a new item inside it is dropped, not queued.
const kSoundInterval = Duration(seconds: 3);

/// Whether the alert sound plays for [items] given the [before] snapshot: a new block or a session whose pending
/// count rose. `null` [before] is the first load; a `null` [lastSound] never blocks.
bool shouldSound(AttentionSnapshot? before, List<AttentionItem> items, {DateTime? lastSound, required DateTime at}) {
  if (before == null) return false;
  if (lastSound != null && at.difference(lastSound) < kSoundInterval) return false;
  final now = AttentionSnapshot.of(items);
  return now.blocked.any((k) => !before.blocked.contains(k)) ||
      now.pending.entries.any((e) => e.value > (before.pending[e.key] ?? 0));
}

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
        kind: AttentionKind.finished,
        project: s.isOrgSession ? null : s.project,
        sessionId: s.id,
      ),
];

/// Dock badge: everything [pendingAttention] lists.
int attentionCount(List<SessionSummary> sessions, List<Project> projects) =>
    sessions.fold(0, (sum, s) => sum + pendingOf(s)) +
    orphanGates(sessions, projects).length +
    projects.where((p) => !p.hidden && blockedDecision(p) != null).length;

/// The org at a glance (the inbox footer and its next-item walk): what waits on the user, what is running, cycles in progress, cycles done.
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

/// One line of the inbox "Precisa de você" section.
typedef InboxRow = ({String context, String title, String detail, String action, String route});

/// `<where> · <feature>`, or just [where] without a feature.
String featureLabel(String where, String? feature) => feature == null || feature.isEmpty ? where : '$where · $feature';

/// Lines of "Precisa de você": [waiting] in order, then the PRs with review comments. Every text comes from typed
/// fields and [projects], never from an item's `key` or `title`.
List<InboxRow> inboxRows(
  String org,
  List<AttentionItem> waiting,
  List<(String project, PullRequest pr)> prs,
  List<Project> projects,
) {
  Project? projectOf(String? name) => projects.where((p) => p.name == name).firstOrNull;
  final rows = <InboxRow>[];
  for (final item in waiting) {
    final project = projectOf(item.project);
    switch (item.kind) {
      case AttentionKind.finished:
        break;
      case AttentionKind.gate:
        final block = openGates(gateReport(project?.cycle)).map((s) => s.gate!).where((g) => g.name == item.gate);
        final gate = block.firstOrNull;
        final summary = gate?.summary.trim() ?? '';
        rows.add((
          context: featureLabel(item.project!, project?.cycle?.feature),
          title: gateTitle(item.gate!, gate?.questions.length ?? 0),
          detail: summary.isNotEmpty
              ? summary
              : (gate != null && item.sessionId != null ? kGateWaitsDetail : item.body),
          action: 'Decidir',
          route: item.route,
        ));
      case AttentionKind.request:
        final feature = project?.cycle?.feature;
        rows.add((
          context: item.project == null ? '$org · conversa' : featureLabel(item.project!, feature ?? 'conversa'),
          title: pendingRequestsTitle(item.pending),
          detail: item.body,
          action: 'Responder',
          route: item.route,
        ));
      case AttentionKind.blocked:
        final decision = project == null ? null : blockedDecision(project);
        if (decision == null) break;
        final text = blockedTaskText(decision.task);
        rows.add((
          context: featureLabel(item.project!, project?.cycle?.feature),
          title: text.title,
          detail: text.detail,
          action: text.action,
          route: item.route,
        ));
    }
  }
  for (final (project, pr) in prs) {
    rows.add((
      context: '$project · PR #${pr.number ?? '?'}',
      title: 'Comentários de revisão esperando resposta',
      detail: pr.title.isEmpty ? '—' : pr.title,
      action: 'Resolver',
      route: '/p/$project/prs',
    ));
  }
  return rows;
}
