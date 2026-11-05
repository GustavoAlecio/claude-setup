import '../../data/models.dart';

class CycleTask {
  const CycleTask(this.task, this.lastRunId);

  final TaskRun task;

  /// Run holding the task's most recent attempt; null when the task never ran.
  final String? lastRunId;
}

/// One row per task, in plan order, with the attempts of every run of the cycle in chronological order.
List<CycleTask> consolidateCycle(Cycle cycle) {
  // Cycle.runs is newest first.
  final runs = cycle.runs.reversed.toList();
  final ids = <String>[for (final t in cycle.plan) t.id];
  final known = ids.toSet();
  for (final run in runs) {
    for (final t in run.tasks) {
      if (known.add(t.id)) ids.add(t.id);
    }
  }

  final out = <CycleTask>[];
  for (final id in ids) {
    final planned = cycle.plan.where((t) => t.id == id).firstOrNull;
    final withAttempts = <(int, Run, TaskRun)>[];
    TaskRun? lastSeen;
    TaskRun? firstSeen;
    for (var i = 0; i < runs.length; i++) {
      final t = runs[i].tasks.where((t) => t.id == id).firstOrNull;
      if (t == null) continue;
      firstSeen ??= t;
      lastSeen = t;
      if (t.attempts.isNotEmpty) withAttempts.add((i, runs[i], t));
    }
    final base = withAttempts.lastOrNull?.$3 ?? lastSeen ?? planned!;
    final multi = withAttempts.length > 1;
    var ordinal = 0;
    final attempts = [
      for (final (index, _, t) in withAttempts)
        for (final a in t.attempts)
          Attempt(
            number: a.number,
            ordinal: ++ordinal,
            label: multi ? 'R${index + 1} ${a.label}' : a.label,
            tier: a.tier,
            gates: a.gates,
            tokensOut: a.tokensOut,
            summary: a.summary,
            escalatedTo: a.escalatedTo,
            checkpoint: a.checkpoint,
          ),
    ];
    out.add(
      CycleTask(
        TaskRun(
          id: id,
          title: planned?.title ?? base.title,
          complexity: planned?.complexity ?? base.complexity,
          risk: planned?.risk ?? base.risk,
          tier0: planned?.tier0 ?? firstSeen?.tier0 ?? base.tier0,
          status: withAttempts.isNotEmpty ? base.status : planned?.status ?? base.status,
          attempts: attempts,
          files: base.files,
          blockedReason: base.blockedReason,
          diagnosis: base.diagnosis,
          description: planned?.description ?? base.description,
          stage: base.stage,
        ),
        withAttempts.lastOrNull?.$2.id,
      ),
    );
  }
  return out;
}
