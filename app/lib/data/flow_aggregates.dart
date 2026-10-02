import 'models.dart';
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
