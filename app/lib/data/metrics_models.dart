class TraceLine {
  const TraceLine({
    required this.role,
    this.runId,
    this.task,
    this.attempt,
    this.tier,
    this.verdict,
    this.stage,
    this.round,
    this.tokensOut,
    this.persistedAt,
    this.seq,
  });

  final String role;
  final String? runId;
  final String? task;
  final int? attempt;
  final String? tier;
  final String? verdict;
  final String? stage;
  final int? round;
  final int? tokensOut;
  final String? persistedAt;
  final int? seq;
}

class TaskMetrics {
  const TaskMetrics({
    required this.key,
    required this.tier0,
    required this.tierFinal,
    required this.attempts,
    required this.escalated,
    required this.passedTier0,
    required this.blocked,
    required this.tokens,
  });

  final String key;
  final String? tier0;
  final String? tierFinal;
  final int attempts;
  final bool escalated;
  final bool passedTier0;
  final bool blocked;
  final int tokens;
}

class CycleMetrics {
  const CycleMetrics({
    required this.dir,
    required this.date,
    required this.feature,
    required this.status,
    required this.tasksLabel,
    required this.tasks,
    required this.escalations,
    required this.verifyRuns,
    required this.rounds,
    required this.tokensByRole,
    required this.hasTokens,
    required this.tokensMissing,
    required this.ignoredLines,
    required this.runsWithoutTrace,
    required this.warnings,
    required this.current,
    required this.hasTrace,
    this.lastPersistedAt,
  });

  final String dir;
  final String? date;
  final String feature;
  final String status;
  final String? tasksLabel;
  final List<TaskMetrics> tasks;
  final int escalations;
  final int verifyRuns;
  final int rounds;

  /// Sempre com as chaves dev, g0, g1, g2 e outros.
  final Map<String, int> tokensByRole;

  /// Falso quando nenhuma linha trouxe `tokens_out`; a tela mostra "—".
  final bool hasTokens;

  /// Linhas sem `tokens_out` inteiro.
  final int tokensMissing;
  final int ignoredLines;
  final int runsWithoutTrace;
  final List<String> warnings;
  final bool current;
  final bool hasTrace;
  final String? lastPersistedAt;

  int get attempts => tasks.fold(0, (a, t) => a + t.attempts);

  int get tokensTotal => tokensByRole.values.fold(0, (a, b) => a + b);
}

class ProjectMetrics {
  const ProjectMetrics({
    required this.cycles,
    required this.completedCycles,
    required this.tasks,
    required this.passedTier0,
    required this.escalations,
    required this.tokensByRole,
    required this.hasTokens,
  });

  const ProjectMetrics.empty()
    : cycles = const [],
      completedCycles = 0,
      tasks = 0,
      passedTier0 = 0,
      escalations = 0,
      tokensByRole = const {'dev': 0, 'g0': 0, 'g1': 0, 'g2': 0, 'outros': 0},
      hasTokens = false;

  final List<CycleMetrics> cycles;
  final int completedCycles;
  final int tasks;
  final int passedTier0;
  final int escalations;
  final Map<String, int> tokensByRole;
  final bool hasTokens;

  double? get passTier0Percent => tasks == 0 ? null : passedTier0 * 100 / tasks;
}
