enum Tier { haiku, sonnet, opus, fable }

enum Verdict { pass, fail, running, blocked, inconclusive, pending }

enum Complexity { s, m, l }

enum Stage { kickoff, specify, challenge, plan, tasks, implement, verify, complete }

extension StageLabel on Stage {
  String get label => switch (this) {
    Stage.kickoff => 'kickoff',
    Stage.specify => 'specify',
    Stage.challenge => 'challenge-spec',
    Stage.plan => 'plan',
    Stage.tasks => 'tasks',
    Stage.implement => 'implement',
    Stage.verify => 'verify',
    Stage.complete => 'complete',
  };
}

class Finding {
  const Finding({
    required this.gate,
    required this.severity,
    required this.file,
    required this.ruleRef,
    required this.message,
    this.line,
  });

  final String gate;
  final String severity;
  final String file;
  final int? line;
  final String ruleRef;
  final String message;

  String get fingerprint => '$gate:$file:$ruleRef';
}

class GateResult {
  const GateResult(this.gate, this.verdict, [this.findings = const []]);

  final String gate;
  final Verdict verdict;
  final List<Finding> findings;
}

class Attempt {
  const Attempt({
    required this.number,
    required this.ordinal,
    required this.tier,
    required this.gates,
    this.tokensOut,
    this.summary,
    this.escalatedTo,
    String? label,
  }) : label = label ?? '#$number';

  final int number;

  /// 1..N within the task across verify rounds, where [number] restarts each round.
  final int ordinal;
  final String label;
  final Tier tier;
  final List<GateResult> gates;
  final int? tokensOut;
  final String? summary;
  final Tier? escalatedTo;

  Verdict get verdict {
    if (gates.any((g) => g.verdict == Verdict.running)) return Verdict.running;
    if (gates.any((g) => g.verdict == Verdict.fail)) return Verdict.fail;
    return gates.isEmpty ? Verdict.pending : Verdict.pass;
  }

  List<Finding> get blocking => [
    for (final g in gates) ...g.findings.where((f) => f.severity == 'critical' || f.severity == 'major'),
  ];
}

class Hypothesis {
  const Hypothesis({
    required this.lens,
    required this.hypothesis,
    required this.confidence,
    required this.evidence,
    required this.action,
  });

  final String lens;
  final String hypothesis;
  final double confidence;
  final List<String> evidence;
  final String action;
}

class TaskRun {
  const TaskRun({
    required this.id,
    required this.title,
    required this.complexity,
    required this.tier0,
    required this.status,
    this.risk = false,
    this.attempts = const [],
    this.files = const [],
    this.blockedReason,
    this.diagnosis = const [],
  });

  final String id;
  final String title;
  final Complexity complexity;
  final bool risk;
  final Tier tier0;
  final Verdict status;
  final List<Attempt> attempts;
  final List<String> files;
  final String? blockedReason;
  final List<Hypothesis> diagnosis;

  Tier get tier => attempts.isEmpty ? tier0 : attempts.last.tier;
  int get escalations => attempts.where((a) => a.escalatedTo != null).length;
  int? get tokensOut => _sumKnown(attempts.map((a) => a.tokensOut));
}

class Run {
  const Run({
    required this.id,
    required this.kind,
    required this.status,
    required this.startedAt,
    required this.tasks,
    this.reason,
    this.gates = const [],
  });

  final String id;
  final String kind;
  final Verdict status;
  final String startedAt;
  final List<TaskRun> tasks;
  final String? reason;
  final List<GateResult> gates;

  int? get tokensOut => _sumKnown(tasks.map((t) => t.tokensOut));

  TaskRun? get blockedTask => tasks.where((t) => t.status == Verdict.blocked).firstOrNull;
}

class Cycle {
  const Cycle({
    required this.stage,
    required this.runs,
    required this.autoMode,
    required this.stageMinutes,
    this.feature,
    this.tracker,
    this.branch,
  });

  final String? feature;
  final String? tracker;
  final Stage stage;
  final String? branch;
  final List<Run> runs;
  final bool autoMode;
  final Map<Stage, int> stageMinutes;

  Run? get latestRun => runs.isEmpty ? null : runs.first;
}

class Project {
  const Project({required this.name, this.path, this.stack, this.cycle});

  final String name;
  final String? path;
  final String? stack;
  final Cycle? cycle;
}

int? _sumKnown(Iterable<int?> values) {
  final known = values.nonNulls;
  return known.isEmpty ? null : known.fold<int>(0, (sum, n) => sum + n);
}
