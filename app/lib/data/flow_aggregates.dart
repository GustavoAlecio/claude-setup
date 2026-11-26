import 'dart:convert';

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

/// The report's status for [stage] when it has an entry, else [derived]: the timeline and the steps bar agree.
StageState stageStateOf(Stage stage, ReportDoc? report, Map<Stage, StageState> derived) =>
    switch (report?.stage(stage)?.status) {
      ReportStatus.done => StageState.done,
      ReportStatus.running => StageState.current,
      ReportStatus.blocked => StageState.blocked,
      null => derived[stage] ?? StageState.pending,
    };

/// Position (1-based) of the cycle's stage, the stage count and each stage's state, as the timeline reads them.
({int position, int total, Map<Stage, StageState> states}) cycleSteps(Cycle cycle) {
  final derived = derivedStageStates(cycle);
  return (
    position: cycle.stage.index + 1,
    total: Stage.values.length,
    states: {for (final s in Stage.values) s: stageStateOf(s, cycle.report, derived)},
  );
}

enum TaskLineState { done, running, blocked, queued }

/// [run] is the newest run with an attempt of the task; `null` leaves the line without a destination.
typedef CycleTaskLine = ({String id, String title, TaskLineState state, String note, String? run});

List<CycleTaskLine> cycleTaskLines(Cycle cycle) => [
  for (final row in taskTable(cycle))
    (
      id: row.id,
      title: row.title,
      state: switch (row.status) {
        Verdict.pass => TaskLineState.done,
        Verdict.running => TaskLineState.running,
        Verdict.blocked || Verdict.fail => TaskLineState.blocked,
        Verdict.pending || Verdict.inconclusive => TaskLineState.queued,
      },
      note: row.tier0 != row.tierFinal
          ? '${row.tier0.name} → ${row.tierFinal.name}'
          : row.attempts > 1
          ? '${row.attempts} tentativas'
          : '',
      run: cycle.runs.where((r) => r.tasks.any((t) => t.id == row.id && t.attempts.isNotEmpty)).firstOrNull?.id,
    ),
];

const kNeedsYou = 'Precisa de você';

enum CycleNowKind { blocked, gate, request, paused, running, done, idle, next, stalled, waiting }

/// [action] is the button label; [route] is `null` when the action is not a navigation.
typedef CycleNow = ({
  CycleNowKind kind,
  String eyebrow,
  String title,
  String detail,
  String? action,
  String? route,
  String? skill,
});

String pendingRequestsTitle(int n) => n == 1 ? '1 pedido esperando resposta' : '$n pedidos esperando resposta';

/// The cycle's state in one sentence and the one action it asks; the first case that matches wins. Only for a project
/// with a cycle.
CycleNow cycleNow(Project project, List<SessionSummary> sessions) {
  final cycle = project.cycle!;
  final label = cycle.stage.label;
  final report = gateReport(cycle);

  if (blockedDecision(project) case final decision?) {
    return (
      kind: CycleNowKind.blocked,
      eyebrow: kNeedsYou,
      title: 'A task ${decision.task.id} travou',
      detail: '${decision.task.title}: o diagnóstico espera a sua decisão',
      action: 'Decidir',
      route: decisionLocation(project.name, decision),
      skill: null,
    );
  }
  if (cardGate(project)?.gate case final gate?) {
    final summary = gate.summary.trim();
    return (
      kind: CycleNowKind.gate,
      eyebrow: kNeedsYou,
      title: gateTitle(gate.name, gate.questions.length),
      detail: summary.isEmpty ? 'Nada roda antes da sua resposta.' : summary,
      action: 'Decidir',
      route: gateLocation(project.name, gate.name),
      skill: null,
    );
  }
  final pending = pendingProjectSessions(sessions, project.name);
  if (pending.isNotEmpty) {
    return (
      kind: CycleNowKind.request,
      eyebrow: kNeedsYou,
      title: pendingRequestsTitle(pending.fold(0, (n, s) => n + pendingOf(s))),
      detail: pending.first.title,
      action: 'Responder',
      route: sessionLocation(pending.first),
      skill: null,
    );
  }
  if (cycle.pausedAt case final since?) {
    // The parser stores a pause without a readable date as the epoch.
    final local = since.toLocal();
    final when = since.millisecondsSinceEpoch == 0
        ? ''
        : 'Pausado desde ${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}. ';
    return (
      kind: CycleNowKind.paused,
      eyebrow: 'Ciclo pausado',
      title: 'Pausado na etapa $label',
      detail: '${when}Nada roda até você retomar.',
      action: 'Retomar',
      route: null,
      skill: null,
    );
  }
  final live =
      runningStageSession([
        for (final s in sessions)
          if (s.status == SessionStatus.running) s,
      ], project) ??
      runningStageSession(sessions, project);
  if (live != null && live.status == SessionStatus.running) {
    return (
      kind: CycleNowKind.running,
      eyebrow: 'Nada precisa de você',
      title: _runningTitle(cycle, live),
      detail: live.title,
      action: 'Acompanhar a conversa',
      route: sessionLocation(live),
      skill: null,
    );
  }
  if (report?.stage(Stage.complete)?.status == ReportStatus.done) {
    return (
      kind: CycleNowKind.done,
      eyebrow: 'Nada precisa de você',
      title: 'Ciclo concluído',
      detail: 'O relatório e o PR estão nos detalhes do ciclo.',
      action: null,
      route: null,
      skill: null,
    );
  }
  if (live != null) {
    return (
      kind: CycleNowKind.idle,
      eyebrow: kNeedsYou,
      title: 'A conversa da etapa $label está parada',
      detail: live.title,
      action: 'Abrir a conversa',
      route: sessionLocation(live),
      skill: null,
    );
  }
  if (cycle.stage != Stage.complete && report?.stage(cycle.stage)?.status == ReportStatus.done) {
    final next = Stage.values[cycle.stage.index + 1].label;
    return (
      kind: CycleNowKind.next,
      eyebrow: kNeedsYou,
      title: 'Etapa $label concluída',
      detail: 'A próxima é /$next.',
      action: 'Rodar /$next',
      route: null,
      skill: next,
    );
  }
  if (orphanCurrentStage(cycle, null, hasSession: false) != null) {
    return (
      kind: CycleNowKind.stalled,
      eyebrow: kNeedsYou,
      title: 'A etapa $label parou sem terminar',
      detail: 'Nenhuma conversa está rodando esta etapa.',
      action: 'Retomar /$label',
      route: null,
      skill: cycle.stage == Stage.kickoff ? null : label,
    );
  }
  return (
    kind: CycleNowKind.waiting,
    eyebrow: kNeedsYou,
    title: 'Etapa $label',
    detail: 'Nenhuma conversa está rodando. Use a paleta para seguir.',
    action: 'Abrir a paleta',
    route: null,
    skill: null,
  );
}

String _runningTitle(Cycle cycle, SessionSummary session) {
  if (skillOf(session.skill ?? session.command) == '/fix') return 'Correção em andamento (/fix)';
  if (cycle.stage == Stage.implement) {
    final running = cycle.latestRun?.tasks.where((t) => t.status == Verdict.running).firstOrNull;
    final table = taskTable(cycle);
    final at = running == null ? -1 : table.indexWhere((r) => r.id == running.id);
    if (at >= 0) return 'Implementando a task ${at + 1} de ${table.length}';
  }
  return 'Etapa ${cycle.stage.label} em andamento';
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

/// [sessions] minus the one whose stage holds [cardGate]: the Fluxo's cycle card already asks it.
List<SessionSummary> withoutOpenGateSessions(List<SessionSummary> sessions, StageReport? cardGate) => [
  for (final s in sessions)
    if (cardGate == null || s.id != cardGate.sessionId) s,
];

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
    taskLocation(project, decision.run.id, decision.task.id);

/// [showOthers] opens the task with every hypothesis of its diagnosis showing, not only the top one.
String taskLocation(String project, String runId, String taskId, {bool fromRuns = false, bool showOthers = false}) {
  final query = [if (fromRuns) 'from=runs', if (showOthers) 'others=1'].join('&');
  return '/p/$project/runs/$runId/$taskId${query.isEmpty ? '' : '?$query'}';
}

const _blockedReasons = {
  'same_failure_across_tiers':
      'A mesma falha sobreviveu a dois modelos diferentes — não é capacidade, é spec ou plano.',
  'ladder_exhausted': 'A escada chegou ao topo (fable) sem passar nos gates.',
  'max_attempts': 'Limite de 5 tentativas atingido.',
  'agent_failed':
      'Um agente caiu (parado, limite de uso ou erro de API). Não diz nada sobre a task: rode /implement de novo.',
};

/// Why a task stopped, in words; empty for an unknown or missing [reason].
String blockedReasonText(String? reason) => _blockedReasons[reason] ?? '';

String _attemptsCount(int n) => n == 1 ? '1 tentativa' : '$n tentativas';

/// One sentence placing [task] in the cycle: where it is in the table, how it ended and whether it climbed the ladder.
/// The attempt count is the one of the run [task] belongs to.
String taskHeadline(TaskRun task, {int? position, int? total}) {
  final n = task.attempts.length;
  final outcome = switch (task.status) {
    Verdict.blocked => 'travou após ${_attemptsCount(n)}',
    Verdict.pass => n <= 1 ? 'pronta de primeira' : 'pronta na tentativa $n',
    Verdict.running => 'rodando, tentativa ${n < 1 ? 1 : n}',
    Verdict.fail => 'reprovou após ${_attemptsCount(n)}',
    Verdict.pending || Verdict.inconclusive => n > 0 ? 'parou após ${_attemptsCount(n)}' : 'na fila',
  };
  return [
    if (position != null && total != null) 'Task $position de $total',
    outcome,
    if (task.tier0 != task.tier) 'escalou de ${task.tier0.name} para ${task.tier.name}',
  ].join(' · ');
}

typedef AttemptFinding = ({String message, String location, String rule});

typedef TaskAttemptLine = ({
  int ordinal,
  String title,
  String subtitle,
  String message,
  String location,
  String rule,
  List<AttemptFinding> others,
  String note,
});

final _verifyRound = RegExp(r'^r(\d+)\b');

/// One line per attempt of [task], in order. The finding shown is the most severe blocking one (`critical` before
/// `major`, first on a tie); the other blocking findings go in `others`. A failed attempt is "same failure" when any of
/// its blocking findings already blocked an earlier attempt, as the engine's `same_failure_across_tiers` decides.
List<TaskAttemptLine> taskAttemptLines(TaskRun task, {String? root}) {
  final firstSeen = <String, int>{};
  final lines = <TaskAttemptLine>[];
  for (final (i, a) in task.attempts.indexed) {
    final blocking = a.blocking;
    final shown = blocking.where((f) => f.severity == 'critical').firstOrNull ?? blocking.firstOrNull;
    final repeatedFrom = [
      for (final f in blocking) ?firstSeen[f.fingerprint],
    ].fold<int?>(null, (min, k) => min == null || k < min ? k : min);
    for (final f in blocking) {
      firstSeen.putIfAbsent(f.fingerprint, () => a.ordinal);
    }
    final isLast = i == task.attempts.length - 1;
    final outcome = switch (a.verdict) {
      Verdict.pass => 'passou',
      Verdict.running => 'rodando',
      Verdict.fail =>
        repeatedFrom != null
            ? 'mesma falha da tentativa $repeatedFrom'
            : 'reprovada em ${a.gates.firstWhere((g) => g.verdict == Verdict.fail).gate.toUpperCase()}',
      _ => isLast && task.status == Verdict.running ? 'rodando' : 'sem veredito',
    };
    final round = _verifyRound.firstMatch(a.label)?.group(1);
    final note = a.escalatedTo != null
        ? 'Desfez as mudanças e escalou para um modelo maior: ${a.tier.name} → ${a.escalatedTo!.name}'
        : isLast && task.status == Verdict.blocked
        ? blockedReasonText(task.blockedReason)
        : '';
    lines.add((
      ordinal: a.ordinal,
      title: 'Tentativa ${a.ordinal}',
      subtitle: '${round == null ? '' : 'rodada $round · '}${a.tier.name} · $outcome',
      message: shown?.message ?? a.summary ?? '',
      location: shown == null ? '' : findingLocation(shown.file, shown.line, root),
      rule: shown?.ruleRef ?? '',
      others: [
        for (final f in blocking)
          if (!identical(f, shown))
            (message: f.message, location: findingLocation(f.file, f.line, root), rule: f.ruleRef),
      ],
      note: note,
    ));
  }
  return lines;
}

/// Hypotheses by falling confidence; ties keep the order the diagnosis came in.
List<Hypothesis> rankedHypotheses(TaskRun task) {
  final indexed = task.diagnosis.indexed.toList()
    ..sort((a, b) {
      final byConfidence = b.$2.confidence.compareTo(a.$2.confidence);
      return byConfidence != 0 ? byConfidence : a.$1.compareTo(b.$1);
    });
  return [for (final (_, h) in indexed) h];
}

enum DiagnosisKind { inert, answer, busy, launch }

/// What the decision buttons of a blocked task's diagnosis do. [route] is the conversation to answer, only in `answer`.
typedef DiagnosisMode = ({DiagnosisKind kind, String? route});

/// `inert` when [project] is unknown or [task] is not the one [blockedDecision] holds (matched by id, with its run);
/// `answer` when a live pipeline session of the project holds a pending request; `busy` when one is live without a
/// request; `launch` otherwise. A conversation outside the pipeline changes nothing.
DiagnosisMode diagnosisMode(Project? project, TaskRun task, Run run, List<SessionSummary> sessions) {
  final decision = project == null ? null : blockedDecision(project);
  if (project == null || decision == null || decision.run.id != run.id || decision.task.id != task.id) {
    return (kind: DiagnosisKind.inert, route: null);
  }
  final pending = pendingProjectSessions(sessions, project.name).where(isPipelineSession).firstOrNull;
  if (pending != null) {
    return (kind: DiagnosisKind.answer, route: sessionLocation(pending));
  }
  final live = sessions.any(
    (s) => !s.isOrgSession && s.project == project.name && isPipelineSession(s) && isLiveOrStarting(s.status),
  );
  return (kind: live ? DiagnosisKind.busy : DiagnosisKind.launch, route: null);
}

/// What waits in each of [projects] besides its sessions' requests: one per gate without a conversation
/// ([orphanGates]) and one for a [blockedDecision].
Map<String, int> _decisions(List<Project> projects, List<SessionSummary> sessions) {
  final out = <String, int>{};
  for (final (:project, stage: _) in orphanGates(sessions, projects)) {
    out[project.name] = (out[project.name] ?? 0) + 1;
  }
  for (final p in projects) {
    if (!p.hidden && blockedDecision(p) != null) out[p.name] = (out[p.name] ?? 0) + 1;
  }
  return out;
}

/// [pending] (sessions per project) plus one for each gate without a conversation ([orphanGates]) and one for each
/// project whose cycle waits on a [blockedDecision]: all are "aguardando você".
Map<String, int> withDecisions(Map<String, int> pending, List<Project> projects, List<SessionSummary> sessions) => {
  ...pending,
  for (final MapEntry(:key, :value) in _decisions(projects, sessions).entries) key: (pending[key] ?? 0) + value,
};

/// Gates without a conversation and blocked-cycle decisions waiting in [org]'s projects.
int decisionsInOrg(List<Project> projects, String org, List<SessionSummary> sessions) =>
    _decisions(projectsInOrg(projects, org), sessions).values.fold(0, (sum, n) => sum + n);

/// Stage that carries each gate (`GATE_OWNER` in `bin/wf-report.py`).
const kGateOwner = {'spec': Stage.challenge, 'plan': Stage.plan, 'tasks': Stage.tasks, 'pr': Stage.complete};

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

/// The open gate the cycle card shows (`cycleNow` kind `gate`): the first open one, and none while a blocked task takes
/// the card.
StageReport? cardGate(Project? project) {
  final cycle = project?.cycle;
  if (project == null || cycle == null || blockedDecision(project) != null) return null;
  return openGates(gateReport(cycle)).firstOrNull;
}

/// Open gates nobody can answer in the app: the owner stage has no session, or its session is missing from [sessions]
/// or no longer alive. A live owner without a pending request is working, so its gate stays out. Hidden projects and
/// paused cycles ask for nothing.
List<({Project project, StageReport stage})> orphanGates(List<SessionSummary> sessions, List<Project> projects) => [
  for (final p in projects)
    if (!p.hidden && !(p.cycle?.paused ?? false))
      for (final s in openGates(gateReport(p.cycle)))
        if (!sessions.any((x) => x.id == s.sessionId && isLiveOrStarting(x.status))) (project: p, stage: s),
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
  if (gate == 'pr') {
    return switch (questions) {
      0 => 'Abrir o PR?',
      1 => '1 ponto antes do PR',
      _ => '$questions pontos antes do PR',
    };
  }
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
    'pr' => ('PR aprovado', 'PR passou sem decisão', 'PR rejeitado'),
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

/// The block question a request question asks: the text is the only link, as in [matchGateRequest].
GateQuestion? blockQuestion(ReportGate gate, String text) {
  final wanted = _normalized(text);
  return gate.questions.where((q) => _normalized(q.text) == wanted).firstOrNull;
}

/// `RECOMMENDED` in `bin/wf-report.py`: `show` appends it to the label both sides agree on.
const _recommended = ' (Recomendado)';

/// Label, as the request carries it, of the option that asks a change on a `pr` point: the one that reads as the
/// `change` option of [block]. `null` when none does; the point then is an ordinary question.
String? prChangeOption(Question asked, GateQuestion? block) {
  final change = block?.options.where((o) => o.id == 'change').firstOrNull?.label;
  if (change == null) return null;
  String bare(String label) =>
      label.endsWith(_recommended) ? label.substring(0, label.length - _recommended.length) : label;
  return asked.options.where((o) => bare(o.label) == change).firstOrNull?.label;
}

/// Answers of the `pr` points decided so far, by question text. [picked] and [texts] are by question text;
/// [changeLabels] holds the change option of each point that has one. A change sends its trimmed text and stays out
/// while that text is blank; any other label is sent as it came.
Map<String, String> prAnswers(
  List<Question> asked,
  Map<String, String> picked,
  Map<String, String> texts,
  Map<String, String> changeLabels,
) {
  final out = <String, String>{};
  for (final q in asked) {
    final label = picked[q.question];
    if (label == null) continue;
    if (label != changeLabels[q.question]) {
      out[q.question] = label;
      continue;
    }
    final text = (texts[q.question] ?? '').trim();
    if (text.isNotEmpty) out[q.question] = text;
  }
  return out;
}

/// How many `pr` points of [round] became tasks (`P<round>.<n>` in the plan); empty while none did.
String prTaskCountLine(List<TaskRun> plan, int round) {
  final id = RegExp('^P$round\\.\\d+\$');
  final n = plan.where((t) => id.hasMatch(t.id)).length;
  return switch (n) {
    0 => '',
    1 => '1 ponto virou task; o gate reabre depois do verify',
    _ => '$n pontos viraram tasks; o gate reabre depois do verify',
  };
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

const mapMaxColumns = 4;

/// Column and row of every node. Depth is the longest path from a source over a forward depth-first walk in `nodes`
/// order (edges in `edges` order); back edges and self edges do not count, so a cycle opens at its first node.
Map<String, ({int col, int row})> mapLayout(List<MapNode> nodes, List<MapEdge> edges) {
  final ids = {for (final n in nodes) n.id};
  final out = <String, List<String>>{};
  for (final e in edges) {
    if (e.from != e.to && ids.contains(e.from) && ids.contains(e.to)) (out[e.from] ??= []).add(e.to);
  }

  final onPath = <String>{};
  final seen = <String>{};
  final incoming = <String, List<String>>{};
  void walk(String id) {
    seen.add(id);
    onPath.add(id);
    for (final to in out[id] ?? const <String>[]) {
      if (onPath.contains(to)) continue;
      (incoming[to] ??= []).add(id);
      if (!seen.contains(to)) walk(to);
    }
    onPath.remove(id);
  }

  for (final n in nodes) {
    if (!seen.contains(n.id)) walk(n.id);
  }

  final depth = <String, int>{};
  int columnOf(String id) => depth[id] ??= [
    0,
    for (final from in incoming[id] ?? const <String>[]) columnOf(from) + 1,
  ].reduce((a, b) => a > b ? a : b);

  final rows = <int, int>{};
  return {
    for (final n in nodes)
      n.id: (() {
        final col = columnOf(n.id).clamp(0, mapMaxColumns - 1);
        final row = rows[col] ?? 0;
        rows[col] = row + 1;
        return (col: col, row: row);
      })(),
  };
}

enum MapTone { neutral, accent, warn, fail }

/// State word and border tone of a node; [muted] dims the text. A node without state has no word and is neutral.
({String? word, MapTone tone, bool muted}) mapNodeLook(MapNode node) {
  final built = node.built;
  if (built != null) {
    return switch (built) {
      BuiltState.planned => (word: 'como planejado', tone: MapTone.neutral, muted: false),
      BuiltState.existing => (word: 'não foi tocada', tone: MapTone.neutral, muted: true),
      BuiltState.unplanned => (word: 'não estava no plano', tone: MapTone.warn, muted: false),
      BuiltState.untouched => (word: 'planejada e não tocada', tone: MapTone.fail, muted: false),
      BuiltState.touched => (word: 'tocada sem estar no plano', tone: MapTone.warn, muted: false),
    };
  }
  return switch (node.state) {
    MapNodeState.added => (word: 'nova', tone: MapTone.accent, muted: false),
    MapNodeState.changed => (word: 'muda', tone: MapTone.warn, muted: false),
    MapNodeState.existing => (word: 'já existe', tone: MapTone.neutral, muted: false),
    null => (word: null, tone: MapTone.neutral, muted: false),
  };
}

/// States present in a plan map, in the order new, changed, existing; empty for a built map.
List<({String word, MapTone tone})> mapLegend(GateMap map) {
  if (map.built) return const [];
  return [
    for (final state in MapNodeState.values)
      if (map.nodes.any((n) => n.state == state))
        (() {
          final look = mapNodeLook(MapNode(id: '', label: '', state: state));
          return (word: look.word!, tone: look.tone);
        })(),
  ];
}

/// Nodes of a built map that came out different from the plan, in map order.
List<MapNode> builtDiffNodes(GateMap map) => [
  for (final n in map.nodes)
    if (n.built == BuiltState.unplanned || n.built == BuiltState.untouched || n.built == BuiltState.touched) n,
];

/// "3 peças como planejado, 2 não foram tocadas"; `null` when both counts are zero.
String? builtSameLine(GateMap map) {
  final planned = map.nodes.where((n) => n.built == BuiltState.planned).length;
  final existing = map.nodes.where((n) => n.built == BuiltState.existing).length;
  final parts = [
    if (planned > 0) '$planned ${planned == 1 ? 'peça' : 'peças'} como planejado',
    if (existing > 0) '$existing ${existing == 1 ? 'não foi tocada' : 'não foram tocadas'}',
  ];
  return parts.isEmpty ? null : parts.join(', ');
}

/// Gates that always stop the cycle, whatever `gates.json` says.
const kAlwaysRequiredGates = {'spec', 'pr'};

/// Same rule as `required_gates` in `wf-report.py`: only an object whose `required` is a list of strings widens the
/// set; anything else leaves [kAlwaysRequiredGates].
Set<String> parseRequiredGates(String? source) {
  if (source == null) return kAlwaysRequiredGates;
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return kAlwaysRequiredGates;
  }
  final required = decoded is Map ? decoded['required'] : null;
  if (required is! List || !required.every((x) => x is String)) return kAlwaysRequiredGates;
  return {...kAlwaysRequiredGates, ...required.cast<String>()};
}

/// When the pipeline stops for the user, given the required gates; names outside spec, pr, plan and tasks are ignored.
List<({String what, String when})> stopRules(Set<String> required) {
  const always = 'param sempre';
  final plan = required.contains('plan');
  final tasks = required.contains('tasks');
  const onlyOnDecision = 'param só quando há uma decisão sua';
  String when(bool on) => on ? always : onlyOnDecision;
  return [
    (what: 'Spec e PR', when: always),
    if (plan == tasks)
      (what: 'Plano e tasks', when: plan ? always : onlyOnDecision)
    else ...[
      (what: 'Plano', when: when(plan)),
      (what: 'Tasks', when: when(tasks)),
    ],
    (what: 'Travou ou bloqueou', when: 'para sempre'),
  ];
}
