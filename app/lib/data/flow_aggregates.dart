import 'models.dart';

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
