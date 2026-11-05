import 'dart:convert';

import 'models.dart';
import 'report_models.dart';

final runIdPattern = RegExp(r'^(?:impl|verify)-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$');

sealed class WatchScope {
  const WatchScope();
}

class RootScope extends WatchScope {
  const RootScope();
}

/// `.dashboard.json` changed; `diffConfig` decides whether to re-emit, rescan or reload.
class ConfigScope extends WatchScope {
  const ConfigScope();
}

class ProjectScope extends WatchScope {
  const ProjectScope(this.project);

  final String project;
}

class RunScope extends WatchScope {
  const RunScope(this.project, this.runId);

  final String project;
  final String runId;
}

/// For a move event, pass the destination: `current.tmp -> current.json` only surfaces as a move of the tmp file.
WatchScope? classify(String root, String path, {String? destination}) {
  final target = destination ?? path;
  final base = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
  if (target != base && !target.startsWith('$base/')) return null;
  final segments = target.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length == 1 && segments[0] == '.dashboard.json') return const ConfigScope();
  for (final s in segments) {
    if (s.startsWith('.') || s.endsWith('.tmp') || s.endsWith('.lock')) return null;
  }
  if (segments.length <= 1) return const RootScope();
  if (segments.length >= 3 && segments[1] == 'runs') return RunScope(segments[0], segments[2]);
  return ProjectScope(segments[0]);
}

List<Map<String, dynamic>> decodeJsonl(String text, {void Function(String line, Object error)? onInvalid}) {
  final out = <Map<String, dynamic>>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) throw const FormatException('not a JSON object');
      out.add(decoded);
    } on FormatException catch (e) {
      onInvalid?.call(line, e);
    }
  }
  return out;
}

DateTime? runStart(String runId) {
  final m = runIdPattern.firstMatch(runId);
  if (m == null) return null;
  final n = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5]);
}

String formatStartedAt(DateTime utc, DateTime now) {
  final local = utc.toLocal();
  final today = now.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  final sameDay = local.year == today.year && local.month == today.month && local.day == today.day;
  return sameDay ? time : '${two(local.day)}/${two(local.month)} $time';
}

Stage stageOf(String? status, bool challenge, Map<String, dynamic> phases) {
  switch (status) {
    case 'triaged':
      return Stage.kickoff;
    case 'specifying':
      return Stage.specify;
    case 'spec_approved':
      return challenge ? Stage.plan : Stage.challenge;
    case 'planning' || 'plan_approved':
      return Stage.plan;
    case 'tasking':
      return Stage.tasks;
    case 'implementing' || 'implemented':
      return Stage.implement;
    case 'verifying':
      return Stage.verify;
    case 'verified' || 'completed':
      return Stage.complete;
  }
  for (final s in Stage.values.reversed) {
    if (_phaseTime(phases, s, 'end') != null) return s;
  }
  return Stage.kickoff;
}

List<FileStat> parseNumstat(String out) {
  final stats = <FileStat>[];
  for (final line in const LineSplitter().convert(out)) {
    final parts = line.split('\t');
    if (parts.length < 3) continue;
    stats.add(FileStat(parts.sublist(2).join('\t'), int.tryParse(parts[0]), int.tryParse(parts[1])));
  }
  return stats;
}

Map<Stage, int> stageMinutes(Map<String, dynamic> phases) {
  final out = <Stage, int>{};
  for (final s in Stage.values) {
    final start = _phaseTime(phases, s, 'start');
    final end = _phaseTime(phases, s, 'end');
    if (start != null && end != null) out[s] = end.difference(start).inMinutes;
  }
  return out;
}

DateTime? _phaseTime(Map<String, dynamic> phases, Stage s, String key) {
  final phase = phases[s.label];
  if (phase is! Map) return null;
  final v = phase[key];
  return v is String ? DateTime.tryParse(v) : null;
}

Map<String, String> taskTitles(Map<String, dynamic> current) {
  final tasks = current['tasks'];
  final items = tasks is Map ? tasks['items'] : null;
  final out = <String, String>{};
  if (items is List) {
    for (final i in items) {
      if (i is Map && i['id'] is String && i['title'] is String) out[i['id'] as String] = i['title'] as String;
    }
  }
  return out;
}

class TaskMeta {
  const TaskMeta({
    required this.id,
    required this.title,
    required this.complexity,
    required this.tier0,
    this.risk = false,
    this.done = false,
    this.description,
  });

  final String id;
  final String title;
  final Complexity complexity;
  final Tier tier0;
  final bool risk;
  final bool done;
  final String? description;
}

/// Planned tasks from current.json, in plan order.
List<TaskMeta> taskMetas(Map<String, dynamic> current) {
  final tasks = current['tasks'];
  return [
    for (final i in _maps(tasks is Map ? tasks['items'] : null))
      if (i['id'] is String)
        TaskMeta(
          id: i['id'] as String,
          title: i['title'] is String ? i['title'] as String : i['id'] as String,
          complexity: _complexity(i['complexity']),
          tier0: _tier(i['tier0']) ?? _tier(i['tier']) ?? Tier.sonnet,
          risk: i['risk'] == 'high',
          done: i['status'] == 'done',
          description: i['description'] is String && (i['description'] as String).isNotEmpty
              ? i['description'] as String
              : null,
        ),
  ];
}

Cycle parseCycle(
  Map<String, dynamic> current, {
  required String projectName,
  String? branch,
  bool autoMode = false,
  List<Run> runs = const [],
  List<TaskMeta> plan = const [],
  ReportDoc? report,
}) {
  final phasesRaw = current['phases'];
  final phases = phasesRaw is Map<String, dynamic> ? phasesRaw : <String, dynamic>{};
  final ado = current['ado_id'];
  final linear = current['linear_key'];
  final feature = current['feature'];
  return Cycle(
    feature: feature is String && feature.isNotEmpty ? feature : projectName,
    tracker: ado != null
        ? '#$ado'
        : (linear is String && linear.isNotEmpty ? linear : (current['tracker'] == 'manual' ? 'manual' : null)),
    stage: stageOf(current['status'] as String?, current['challenge'] != null, phases),
    branch: branch == null || branch.isEmpty ? null : branch,
    runs: runs,
    autoMode: autoMode,
    stageMinutes: stageMinutes(phases),
    report: report,
    plan: [
      for (final m in plan)
        TaskRun(
          id: m.id,
          title: m.title,
          complexity: m.complexity,
          risk: m.risk,
          tier0: m.tier0,
          status: m.done ? Verdict.pass : Verdict.pending,
          description: m.description,
        ),
    ],
  );
}

Run parseResultRun(String runId, Map<String, dynamic> result, Map<String, String> titles, {DateTime? now}) {
  final isVerify = runId.startsWith('verify');
  final trace = _maps(result['trace']);
  final tasksRaw = _maps(result['tasks']);
  final blockedId = result['blocked_task'] as String?;
  final status = result['status'] as String?;

  final groups = <String, _Group>{};
  final byTask = <String, List<_Group>>{};
  for (final e in trace) {
    final task = e['task'];
    if (task is! String) continue;
    final round = e['round'] is int ? e['round'] as int : null;
    final attempt = e['attempt'] is int ? e['attempt'] as int : 1;
    final g = groups.putIfAbsent('$task|$round|$attempt', () {
      final created = _Group(round, attempt);
      byTask.putIfAbsent(task, () => []).add(created);
      return created;
    });
    g.add(e);
  }

  final tasks = <TaskRun>[];
  for (final t in tasksRaw) {
    final id = t['id'];
    if (id is! String) continue;
    final tier0 = _tier(t['tier0']) ?? Tier.haiku;
    final taskGroups = byTask[id] ?? const <_Group>[];
    final escalations = _maps(t['escalations']);
    final lastRound = taskGroups.map((g) => g.round).nonNulls.fold<int?>(null, (m, r) => m == null || r > m ? r : m);
    final attempts = <Attempt>[];
    for (var i = 0; i < taskGroups.length; i++) {
      final g = taskGroups[i];
      final isLast = i == taskGroups.length - 1;
      final eligible = !isVerify || g.round == lastRound;
      final esc = eligible ? escalations.where((x) => x['at_attempt'] == g.attempt).firstOrNull : null;
      attempts.add(
        Attempt(
          number: g.attempt,
          ordinal: i + 1,
          label: isVerify && g.round != null ? 'r${g.round} #${g.attempt}' : null,
          tier: g.tier ?? tier0,
          gates: g.gates,
          tokensOut: g.tokensOut,
          summary: isLast ? (t['summary'] as String? ?? g.devBlockedSummary) : g.devBlockedSummary,
          escalatedTo: esc == null ? null : _tier(esc['to']),
        ),
      );
    }
    final isBlockedTask = id == blockedId;
    tasks.add(
      TaskRun(
        id: id,
        title: _title(id, titles),
        complexity: _complexity(t['complexity']),
        risk: t['risk'] == 'high',
        tier0: tier0,
        status: switch (t['status']) {
          'done' => Verdict.pass,
          'blocked' || 'backtrack' => Verdict.blocked,
          _ => Verdict.pending,
        },
        attempts: attempts,
        files: [
          for (final f in _list(t['files_changed']))
            if (f is String) f,
        ],
        blockedReason: isBlockedTask ? result['reason'] as String? : null,
        diagnosis: isBlockedTask ? _diagnosis(result['diagnosis']) : const [],
      ),
    );
  }

  final taskless = trace.where((e) => e['task'] is! String && _isReviewRole(e['role']));
  final maxRound = taskless
      .map((e) => e['round'])
      .whereType<int>()
      .fold<int?>(null, (m, r) => m == null || r > m ? r : m);
  final runGates = <String, GateResult>{};
  for (final e in taskless) {
    if (maxRound != null && e['round'] != maxRound) continue;
    final role = e['role'] as String;
    runGates[role] = GateResult(role, _verdict(e['verdict']), _findings(role, e['findings']));
  }

  return Run(
    id: runId,
    kind: isVerify ? 'verify' : 'implement',
    status: switch (status) {
      'done' || 'verified' => Verdict.pass,
      'blocked' || 'backtrack' => Verdict.blocked,
      _ => Verdict.inconclusive,
    },
    startedAt: _startedAt(runId, now),
    reason: status == 'backtrack' ? 'backtrack' : result['reason'] as String?,
    tasks: tasks,
    gates: runGates.values.toList(),
    round: isVerify ? _roundOf(result['report']) ?? maxRound : null,
  );
}

int? _roundOf(Object? report) => report is Map && report['round'] is int ? report['round'] as int : null;

Run parseEventsRun(String runId, List<Map<String, dynamic>> events, {List<TaskMeta> tasks = const [], DateTime? now}) {
  final order = <String>[];
  final attemptsByTask = <String, List<_LiveAttempt>>{};
  String? lastTouched;

  _LiveAttempt? last(String task) => attemptsByTask[task]?.lastOrNull;

  _LiveAttempt attemptFor(String task, int? number, Tier? tier) {
    final list = attemptsByTask.putIfAbsent(task, () {
      order.add(task);
      return [];
    });
    final n = number ?? list.lastOrNull?.number ?? 1;
    final existing = list.where((a) => a.number == n).firstOrNull;
    if (existing != null) return existing;
    final created = _LiveAttempt(n, tier ?? list.lastOrNull?.tier ?? Tier.haiku);
    list
      ..add(created)
      ..sort((a, b) => a.number.compareTo(b.number));
    return created;
  }

  for (final e in events) {
    final task = e['task'];
    if (task is! String) continue;
    final role = e['role'];
    final attempt = e['attempt'] is int ? e['attempt'] as int : null;
    final tier = _tier(e['tier']);
    final ts = e['ts'] is String ? DateTime.tryParse(e['ts'] as String) : null;
    switch (role) {
      case 'dev':
        final a = attemptFor(task, attempt, tier);
        if (tier != null) a.tier = tier;
        if (e['verdict'] == 'blocked') a.summary = 'dev declarou blocked';
        if (e['verdict'] == 'start') a.devStart = ts;
        final cp = e['checkpoint'];
        if (cp is String && cp.isNotEmpty) a.checkpoint = cp;
        lastTouched = task;
      case 'g0' || 'g1':
        final a = attempt == null && last(task) != null ? last(task)! : attemptFor(task, attempt, tier);
        a.gates[role as String] = GateResult(role, _verdict(e['verdict']));
        a.gateTimes[role] = ts;
        lastTouched = task;
      case 'escalate':
        final a = attempt == null ? last(task) : attemptFor(task, attempt, null);
        if (a != null && tier != null) a.escalatedTo = tier;
        lastTouched = task;
    }
  }

  TaskRun build(String id, TaskMeta? meta) {
    final live = attemptsByTask[id] ?? const <_LiveAttempt>[];
    final attempts = [
      for (var i = 0; i < live.length; i++)
        Attempt(
          number: live[i].number,
          ordinal: i + 1,
          tier: live[i].tier,
          gates: live[i].gates.values.toList(),
          summary: live[i].summary,
          escalatedTo: live[i].escalatedTo,
          checkpoint: live[i].checkpoint,
        ),
    ];
    final running = id == lastTouched;
    return TaskRun(
      id: id,
      title: meta?.title ?? _title(id, const {}),
      complexity: meta?.complexity ?? Complexity.m,
      risk: meta?.risk ?? false,
      tier0: meta?.tier0 ?? (attempts.isEmpty ? Tier.sonnet : attempts.first.tier),
      description: meta?.description,
      status: attempts.isEmpty
          ? (meta?.done == true ? Verdict.pass : Verdict.pending)
          : running
          ? Verdict.running
          : (attempts.last.verdict == Verdict.pass ? Verdict.pass : Verdict.pending),
      attempts: attempts,
      stage: running ? live.last.stage : null,
    );
  }

  final metaById = {for (final m in tasks) m.id: m};
  final ids = [...metaById.keys, ...order.where((id) => !metaById.containsKey(id))];

  return Run(
    id: runId,
    kind: runId.startsWith('verify') ? 'verify' : 'implement',
    status: Verdict.running,
    startedAt: _startedAt(runId, now),
    tasks: [for (final id in ids) build(id, metaById[id])],
  );
}

class _Group {
  _Group(this.round, this.attempt);

  final int? round;
  final int attempt;
  Tier? tier;
  int? tokensOut;
  String? devBlockedSummary;
  final Map<String, GateResult> _gates = {};

  List<GateResult> get gates => _gates.values.toList();

  void add(Map<String, dynamic> e) {
    final role = e['role'];
    final t = e['tokens_out'];
    if (t is int) tokensOut = (tokensOut ?? 0) + t;
    if (role == 'dev') {
      tier = _tier(e['tier']) ?? tier;
      if (e['verdict'] == 'blocked') devBlockedSummary = 'dev declarou blocked';
    } else {
      tier ??= _tier(e['tier']);
    }
    if (role == 'g0' || role == 'g1') {
      _gates[role as String] = GateResult(role, _verdict(e['verdict']), _findings(role, e['findings']));
    }
  }
}

class _LiveAttempt {
  _LiveAttempt(this.number, this.tier);

  final int number;
  Tier tier;
  Tier? escalatedTo;
  String? summary;
  String? checkpoint;
  DateTime? devStart;
  final Map<String, GateResult> gates = {};
  final Map<String, DateTime?> gateTimes = {};

  /// Events only mark completions, so each stage is "since" the previous event of the attempt.
  LiveStage? get stage {
    final g1 = gates['g1'];
    final g0 = gates['g0'];
    if (g1 != null) {
      final at = gateTimes['g1'];
      if (at == null) return null;
      return LiveStage(g1.verdict == Verdict.pass ? 'G1 aprovou' : 'G1 reprovou', at);
    }
    if (g0 != null) {
      final at = gateTimes['g0'];
      if (at == null) return null;
      return LiveStage(g0.verdict == Verdict.pass ? 'G1 revisando' : 'G0 reprovou', at);
    }
    final at = devStart;
    if (at == null) return null;
    return LiveStage(summary == null ? 'implementando' : 'dev bloqueou', at);
  }
}

bool _isReviewRole(Object? role) => role is String && (role.startsWith('g1') || role.startsWith('g2'));

String _startedAt(String runId, DateTime? now) {
  final start = runStart(runId);
  return start == null ? '' : formatStartedAt(start, now ?? DateTime.now());
}

String _title(String id, Map<String, String> titles) {
  final title = titles[id];
  if (title != null) return title;
  final v = RegExp(r'^V(\d+)$').firstMatch(id);
  return v == null ? id : 'Correções transversais do verify r${v.group(1)}';
}

Tier? _tier(Object? v) => v is String ? Tier.values.where((t) => t.name == v).firstOrNull : null;

Complexity _complexity(Object? v) => switch (v) {
  'S' || 's' => Complexity.s,
  'L' || 'l' => Complexity.l,
  _ => Complexity.m,
};

Verdict _verdict(Object? v) => switch (v) {
  'pass' || 'done' || 'verified' || 'ok' => Verdict.pass,
  'fail' || 'agent_failed' => Verdict.fail,
  'inconclusive' => Verdict.inconclusive,
  'blocked' || 'backtrack' => Verdict.blocked,
  'running' || 'start' => Verdict.running,
  _ => Verdict.pending,
};

List<Finding> _findings(String gate, Object? raw) {
  return [
    for (final f in _maps(raw))
      Finding(
        gate: gate,
        severity: f['severity'] as String? ?? 'major',
        file: f['file'] as String? ?? '',
        line: f['line'] is int && (f['line'] as int) > 0 ? f['line'] as int : null,
        ruleRef: (f['rule_ref'] as String?) ?? (f['id'] as String?) ?? '',
        message: f['message'] as String? ?? '',
      ),
  ];
}

List<Hypothesis> _diagnosis(Object? raw) {
  final list = [
    for (final h in _maps(raw))
      Hypothesis(
        lens: h['lens'] as String? ?? '',
        hypothesis: h['hypothesis'] as String? ?? '',
        confidence: (h['confidence'] as num?)?.toDouble() ?? 0,
        evidence: [
          for (final e in _list(h['evidence']))
            if (e is String) e,
        ],
        action: h['recommended_action'] as String? ?? '',
      ),
  ];
  list.sort((a, b) => b.confidence.compareTo(a.confidence));
  return list;
}

List<Object?> _list(Object? v) => v is List ? v : const [];

List<Map<String, dynamic>> _maps(Object? v) => [
  for (final e in _list(v))
    if (e is Map<String, dynamic>) e,
];
