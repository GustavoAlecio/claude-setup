import 'models.dart';
import 'orgs.dart';
import 'report_models.dart';
import 'session_models.dart';
import 'session_reducer.dart';

/// Uma linha da tabela de tasks: o plano do `current.json` somado ao que os runs (`result.json`) registraram.
class TaskRow {
  const TaskRow({
    required this.id,
    required this.title,
    required this.complexity,
    required this.risk,
    required this.tier0,
    required this.tierFinal,
    required this.attempts,
    required this.escalations,
    required this.status,
  });

  final String id;
  final String title;
  final Complexity complexity;
  final bool risk;
  final Tier tier0;
  final Tier tierFinal;
  final int attempts;
  final int escalations;
  final Verdict status;
}

/// Tasks do plano na ordem do plano; sem plano, as tasks dos runs de implement. Tentativas e escaladas somam
/// todos os runs; tier final e status vêm do run mais recente com a task (`cycle.runs` é do mais novo para o mais velho).
List<TaskRow> taskTable(Cycle cycle) {
  final byId = <String, List<TaskRun>>{};
  for (final run in cycle.runs) {
    for (final t in run.tasks) {
      byId.putIfAbsent(t.id, () => []).add(t);
    }
  }
  final base = cycle.plan.isNotEmpty
      ? cycle.plan
      : [
          for (final run in cycle.runs.reversed.where((r) => r.kind == 'implement'))
            for (final t in run.tasks) t,
        ];
  final seen = <String>{};
  return [
    for (final planned in base)
      if (seen.add(planned.id))
        () {
          final seenRuns = byId[planned.id] ?? const <TaskRun>[];
          final latest = seenRuns.firstOrNull;
          return TaskRow(
            id: planned.id,
            title: planned.title,
            complexity: planned.complexity,
            risk: planned.risk,
            tier0: planned.tier0,
            tierFinal: latest?.tier ?? planned.tier0,
            attempts: seenRuns.fold(0, (n, t) => n + t.attempts.length),
            escalations: seenRuns.fold(0, (n, t) => n + t.escalations),
            status: latest?.status ?? planned.status,
          );
        }(),
  ];
}

/// Uma rodada de verify: um run `verify-*`.
class VerifyRoundSummary {
  const VerifyRoundSummary({
    required this.runId,
    required this.round,
    required this.status,
    required this.reason,
    required this.gates,
    required this.blocking,
    required this.fixTasks,
  });

  final String runId;
  final int? round;
  final Verdict status;
  final String? reason;

  /// Veredito por gate da última rodada do run.
  final List<GateResult> gates;

  /// Achados `critical`/`major` dos gates da última rodada.
  final List<Finding> blocking;

  /// Tasks de correção do verify (`V<n>`).
  final List<TaskRun> fixTasks;
}

final _fixTaskId = RegExp(r'^V\d+$');

/// Do run mais antigo para o mais novo.
List<VerifyRoundSummary> verifySummary(List<Run> runs) => [
  for (final run in runs.reversed.where((r) => r.kind == 'verify'))
    VerifyRoundSummary(
      runId: run.id,
      round: run.round,
      status: run.status,
      reason: run.reason,
      gates: run.gates,
      blocking: [
        for (final g in run.gates) ...g.findings.where((f) => f.severity == 'critical' || f.severity == 'major'),
      ],
      fixTasks: run.tasks.where((t) => _fixTaskId.hasMatch(t.id)).toList(),
    ),
];

enum StageState { done, current, blocked, pending }

/// Estado de cada etapa a partir do `current.json`, para as etapas sem entrada no relatório.
Map<Stage, StageState> derivedStageStates(Cycle cycle) {
  final blocked = cycle.latestRun?.status == Verdict.blocked;
  return {
    for (final s in Stage.values)
      s: s.index < cycle.stage.index
          ? StageState.done
          : s == cycle.stage
          ? (blocked ? StageState.blocked : StageState.current)
          : StageState.pending,
  };
}

/// The stage the side panel shows ([selected], else the cycle's) when it reads "em andamento" with no session to
/// show; `null` otherwise. The panel then points to the palette instead of a bare placeholder.
Stage? orphanCurrentStage(Cycle? cycle, Stage? selected, {required bool hasSession}) {
  if (cycle == null || hasSession) return null;
  final stage = selected ?? cycle.stage;
  final state = switch (cycle.report?.stage(stage)?.status) {
    ReportStatus.running => StageState.current,
    null => derivedStageStates(cycle)[stage],
    _ => null,
  };
  return state == StageState.current ? stage : null;
}

/// A `running` stage whose session the engine already ended (done, stopped, error or detached). A session missing from
/// [sessions] is not reported: the list may still be loading.
class EndedStageSession {
  const EndedStageSession(this.stage, this.session);

  final Stage stage;
  final SessionSummary session;
}

bool _ended(SessionStatus status) => status != SessionStatus.starting && !isLive(status);

List<EndedStageSession> endedStageSessions(ReportDoc? report, List<SessionSummary> sessions) => [
  for (final s in report?.stages ?? const <StageReport>[])
    if (s.status == ReportStatus.running)
      if (sessions.where((x) => x.id == s.sessionId).firstOrNull case final session?)
        if (_ended(session.status)) EndedStageSession(s.stage, session),
];

/// Session the Fluxo side panel shows. [stage] is `?stage=`: the session that stage reported; a `running` stage without
/// one falls back to [runningStage] (the project's live pipeline session); any other stage without a session is `null`
/// (the panel then shows the placeholder). Without `?stage=`, [runningStage], else the session of the report's
/// `running` stage.
String? flowPanelSessionId({required Stage? stage, required SessionSummary? runningStage, required ReportDoc? report}) {
  if (stage != null) {
    final entry = report?.stage(stage);
    if (entry?.sessionId case final id?) return id;
    return entry?.status == ReportStatus.running ? runningStage?.id : null;
  }
  return runningStage?.id ??
      report?.stages.where((s) => s.status == ReportStatus.running && s.sessionId != null).firstOrNull?.sessionId;
}

/// The stage banner's "abrir sessão" is redundant only when the same session is already on screen in the split panel;
/// in the drawer it stays hidden until opened.
bool stageBannerShowsOpenLink({
  required bool split,
  required bool hasSidePanel,
  required String? shownSessionId,
  required String stageSessionId,
}) => !(split && hasSidePanel && shownSessionId == stageSessionId);

/// "Aguardando você" items: [pending] minus the session the side panel already shows below the card.
List<SessionSummary> awaitingSessions(List<SessionSummary> pending, String? shownSessionId) => [
  for (final s in pending)
    if (s.id != shownSessionId) s,
];

/// [sessions] minus those whose stage holds an open gate of [gates]: the Fluxo's "Decidir" row already asks it.
List<SessionSummary> withoutOpenGateSessions(List<SessionSummary> sessions, ReportDoc? gates) {
  final ids = {for (final s in openGates(gates)) s.sessionId};
  return [
    for (final s in sessions)
      if (!ids.contains(s.id)) s,
  ];
}

/// Ended stage sessions for the awaiting card, minus the one the side panel already shows with its Retomar button.
List<EndedStageSession> awaitingEnded(List<EndedStageSession> ended, String? shownSessionId) => [
  for (final e in ended)
    if (e.session.id != shownSessionId) e,
];

/// Without a cycle, a session to show, a `?stage=` or pending permissions the Fluxo drops the side panel, so the empty
/// state is the only Kickoff on screen.
bool showsFlowSidePanel({
  required bool hasCycle,
  required bool hasShownSession,
  required Stage? stage,
  required int pending,
}) => hasCycle || hasShownSession || stage != null || pending > 0;

/// Without a cycle only a `/kickoff` session means a cycle is being born; `/complete` or `/fix` sessions stay alive
/// after the archive and must not hide "Novo kickoff".
bool isKickoffSession(SessionSummary session) => session.command.trimLeft().split(RegExp(r'\s+')).first == '/kickoff';

/// `file:line` for a finding, relative to [root] when the agent reported an absolute path under it.
String findingLocation(String file, int? line, String? root) {
  final base = root == null ? '' : (root.endsWith('/') ? root : '$root/');
  final shown = base.isNotEmpty && file.startsWith(base) ? file.substring(base.length) : file;
  return line == null ? shown : '$shown:$line';
}

/// Task blocked in the project's latest run with its diagnosis ready: the cycle stops until the user decides.
/// A paused cycle asks for nothing: its decision waits until the user resumes it.
({Run run, TaskRun task})? blockedDecision(Project project) {
  if (project.cycle?.paused ?? false) return null;
  final run = project.cycle?.latestRun;
  final task = run?.blockedTask;
  return run == null || task == null ? null : (run: run, task: task);
}

/// Where the blocked task's diagnosis (and its decision buttons) lives.
String decisionLocation(String project, ({Run run, TaskRun task}) decision) =>
    '/p/$project/runs/${decision.run.id}/${decision.task.id}';

/// [pending] (sessions per project) plus one for each project whose cycle waits on a [blockedDecision]: both are
/// "aguardando você".
Map<String, int> withDecisions(Map<String, int> pending, List<Project> projects) => {
  ...pending,
  for (final p in projects)
    if (!p.hidden && blockedDecision(p) != null) p.name: (pending[p.name] ?? 0) + 1,
};

/// Blocked-cycle decisions waiting in [org]'s projects.
int decisionsInOrg(List<Project> projects, String org) =>
    projectsInOrg(projects, org).where((p) => !p.hidden && blockedDecision(p) != null).length;

/// Stage that carries each gate the app decides (`GATE_OWNER` in `bin/wf-report.py`); `pr` is not decided here.
const kGateOwner = {'spec': Stage.challenge, 'plan': Stage.plan, 'tasks': Stage.tasks};

/// The report the gates read: only one from this cycle (`Cycle.reportIsCurrent`), the identity `wf-report.py` uses.
ReportDoc? gateReport(Cycle? cycle) => cycle != null && cycle.reportIsCurrent ? cycle.report : null;

/// Gate blocks on their owner stage, in pipeline order.
Iterable<StageReport> _ownedGates(ReportDoc? report) => [...?report?.stages]
  ..retainWhere((s) => s.gate != null && kGateOwner[s.gate!.name] == s.stage)
  ..sort((a, b) => a.stage.index.compareTo(b.stage.index));

/// Stages whose gate waits on the user, in pipeline order.
List<StageReport> openGates(ReportDoc? report) => [
  for (final s in _ownedGates(report))
    if (s.gate!.status == GateStatus.open) s,
];

/// Stages whose gate passed without asking ("Passou sem você"), in pipeline order.
List<StageReport> passedGates(ReportDoc? report) => [
  for (final s in _ownedGates(report))
    if (s.gate!.status == GateStatus.passed) s,
];

/// Open gate of session [sessionId]: one session runs several stages, so the first in pipeline order wins.
ReportGate? sessionGate(ReportDoc? report, String sessionId) =>
    openGates(report).where((s) => s.sessionId == sessionId).firstOrNull?.gate;

String gateLocation(String project, String gate) => Uri(pathSegments: ['', 'p', project, 'gate', gate]).toString();

String _normalized(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

const _approvalPrefixes = ['aprovar', 'ajustar', 'rejeitar'];

bool _isApprovalRequest(QuestionRequest r) =>
    r.questions.length == 1 &&
    _approvalPrefixes.every(
      (prefix) => r.questions.single.options.any((o) => o.label.trim().toLowerCase().startsWith(prefix)),
    );

/// The pending `AskUserQuestion` of the stage session that asks [gate]. The question text is the only link: the
/// question id does not survive `AskUserQuestion`. With questions, the request must carry the unanswered ones in
/// order; without, it is the session's only pending question, with Aprovar, Ajustar and Rejeitar. Expired requests
/// never match; among several matches the highest `seq` wins.
QuestionRequest? matchGateRequest(ReportGate gate, SessionDetail detail) {
  if (gate.status != GateStatus.open) return null;
  final asked = [
    for (final r in pendingRequests(detail))
      if (r is QuestionRequest) r,
  ];
  if (gate.questions.isEmpty) {
    return asked.length == 1 && _isApprovalRequest(asked.single) ? asked.single : null;
  }
  final open = [
    for (final q in gate.questions)
      if (q.answer == null) _normalized(q.text),
  ];
  if (open.isEmpty) return null;
  QuestionRequest? best;
  for (final r in asked) {
    final texts = [for (final q in r.questions) _normalized(q.question)];
    if (texts.length == open.length && Iterable.generate(open.length).every((i) => texts[i] == open[i])) {
      if (best == null || r.seq > best.seq) best = r;
    }
  }
  return best;
}

/// What the gate screen answered in this visit.
typedef GateSent = ({int round, String requestId});

enum GateScreenState { deciding, sent, revising, reading, waiting }

/// The screen state of [gate] given the request that asks it ([matched]) and what this visit sent. A send of the
/// current round reads as sent while no other request asks: the skill writes one answer at a time, so a partially
/// recorded gate no longer matches the request it just answered. A send of an older round is ignored.
GateScreenState gateScreenState(ReportGate gate, QuestionRequest? matched, GateSent? sent) {
  switch (gate.status) {
    case GateStatus.revising:
      return GateScreenState.revising;
    case GateStatus.approved || GateStatus.passed || GateStatus.rejected:
      return GateScreenState.reading;
    case GateStatus.open:
      final current = sent != null && sent.round == gate.round ? sent : null;
      if (current != null && (matched == null || matched.requestId == current.requestId)) return GateScreenState.sent;
      return matched != null ? GateScreenState.deciding : GateScreenState.waiting;
  }
}

/// [questions] is the count of the matched request.
String gateTitle(String gate, int questions) {
  final (before, approve) = switch (gate) {
    'spec' => ('planejar', 'Aprovar a spec?'),
    'plan' => ('gerar as tasks', 'Aprovar o plano?'),
    'tasks' => ('implementar', 'Aprovar as tasks?'),
    _ => (null, 'Aprovar?'),
  };
  if (questions == 0) return approve;
  final count = questions == 1 ? '1 decisão' : '$questions decisões';
  return before == null ? count : '$count antes de $before';
}

/// Title of the gate screen: a decided gate names its outcome instead of asking again; open and revising keep
/// [gateTitle].
String gateReadingTitle(String gate, GateStatus status, int questions) {
  final (approved, passed, rejected) = switch (gate) {
    'spec' => ('Spec aprovada', 'Spec passou sem decisão', 'Spec rejeitada'),
    'plan' => ('Plano aprovado', 'Plano passou sem decisão', 'Plano rejeitado'),
    'tasks' => ('Tasks aprovadas', 'Tasks passaram sem decisão', 'Tasks rejeitadas'),
    _ => (null, null, null),
  };
  final title = switch (status) {
    GateStatus.approved => approved,
    GateStatus.passed => passed,
    GateStatus.rejected => rejected,
    GateStatus.open || GateStatus.revising => null,
  };
  return title ?? gateTitle(gate, questions);
}

/// `challenger:<id>` → revisão adversarial, `critic` → crítico, `author` → autor; anything else as written.
String? riskSourceLabel(String? source) => switch (source) {
  null => null,
  'critic' => 'crítico',
  'author' => 'autor',
  final s when s.startsWith('challenger:') => 'revisão adversarial',
  final s => s,
};

enum GateWaitReason { otherRequest, sessionEnded, terminal, notArrived }

/// Why an open gate has no request to answer. [sessionId] is the owner stage's session (`null`: it ran in a
/// terminal); [detail] is that session's stream, `null` while it loads.
GateWaitReason gateWaitReason(String? sessionId, SessionDetail? detail) {
  if (sessionId == null) return GateWaitReason.terminal;
  if (detail == null) return GateWaitReason.notArrived;
  if (_ended(detail.summary.status)) return GateWaitReason.sessionEnded;
  return pendingRequests(detail).isEmpty ? GateWaitReason.notArrived : GateWaitReason.otherRequest;
}

/// Where the gate screen goes once its send is approved: the pending route of the same project after the gate's own
/// (wrapping), never the gate itself nor another project's or an org's, else the project's Fluxo.
String afterGateRoute(List<String> pendingRoutes, String gateRoute, String project) {
  final own = Uri.parse(gateRoute).path;
  final prefix = Uri(pathSegments: ['', 'p', project, '']).path;
  final inProject = [
    for (final r in pendingRoutes)
      if (Uri.parse(r).path.startsWith(prefix)) r,
  ];
  final at = inProject.indexWhere((r) => Uri.parse(r).path == own);
  final others = [
    for (final r in inProject)
      if (Uri.parse(r).path != own) r,
  ];
  if (others.isEmpty) return Uri(pathSegments: ['', 'p', project, 'flow']).toString();
  return others[at < 0 ? 0 : at % others.length];
}
