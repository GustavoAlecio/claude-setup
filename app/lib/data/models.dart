import 'report_models.dart';

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
    this.checkpoint,
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

  /// Tree sha the task started from; lets the UI diff the working tree while the attempt runs.
  final String? checkpoint;

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

class LiveStage {
  const LiveStage(this.label, this.since);

  final String label;
  final DateTime since;
}

class FileStat {
  const FileStat(this.path, this.added, this.deleted);

  final String path;

  /// Null for binary files, which git reports as `-`.
  final int? added;
  final int? deleted;
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
    this.description,
    this.stage,
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
  final String? description;

  /// Only set for a task that is running, derived from the live event stream.
  final LiveStage? stage;

  String? get checkpoint => attempts.map((a) => a.checkpoint).nonNulls.lastOrNull;

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
    this.round,
  });

  final String id;
  final String kind;
  final Verdict status;
  final String startedAt;
  final List<TaskRun> tasks;
  final String? reason;
  final List<GateResult> gates;

  /// Last verify round of the run; `null` for an implement run or a result without round data.
  final int? round;

  int? get tokensOut => _sumKnown(tasks.map((t) => t.tokensOut));

  TaskRun? get blockedTask => tasks.where((t) => t.status == Verdict.blocked).firstOrNull;
}

class Cycle {
  const Cycle({
    required this.stage,
    required this.runs,
    required this.autoMode,
    required this.stageMinutes,
    this.plan = const [],
    this.feature,
    this.tracker,
    this.branch,
    this.report,
  });

  final String? feature;
  final String? tracker;
  final Stage stage;
  final String? branch;
  final List<Run> runs;
  final bool autoMode;
  final Map<Stage, int> stageMinutes;

  /// Planned tasks from current.json in plan order, without attempts.
  final List<TaskRun> plan;

  /// `null` without a valid `report.json` (missing, over the size limit, invalid or `version != 1`).
  final ReportDoc? report;

  Run? get latestRun => runs.isEmpty ? null : runs.first;
}

/// Reserved org name for projects outside every configured root.
const kNoOrg = 'Sem org';

class Project {
  const Project({
    required this.name,
    this.path,
    this.stack,
    this.cycle,
    this.org = kNoOrg,
    this.hidden = false,
    this.registered = false,
  });

  final String name;
  final String? path;
  final String? stack;
  final Cycle? cycle;
  final String org;
  final bool hidden;

  /// Listed in `.dashboard.json` `projects`, as opposed to discovered from a workflow dir.
  final bool registered;

  Project copyWith({String? path, String? org, bool? hidden, bool? registered}) => Project(
    name: name,
    path: path ?? this.path,
    stack: stack,
    cycle: cycle,
    org: org ?? this.org,
    hidden: hidden ?? this.hidden,
    registered: registered ?? this.registered,
  );
}

int? _sumKnown(Iterable<int?> values) {
  final known = values.nonNulls;
  return known.isEmpty ? null : known.fold<int>(0, (sum, n) => sum + n);
}
