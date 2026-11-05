import 'dart:convert';

import 'metrics_models.dart';
import 'report_models.dart';

const metricsRoles = ['dev', 'g0', 'g1', 'g2', 'outros'];

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is int ? v : (v is double && v == v.truncateToDouble() ? v.toInt() : null);

String? _stamp(Object? v) => v is String ? v : (v is num ? v.toString() : null);

String roleBucket(String role) {
  if (role == 'g1' || role.startsWith('g1:')) return 'g1';
  return const {'dev', 'g0', 'g2'}.contains(role) ? role : 'outros';
}

TraceLine? parseTraceLine(String line) {
  try {
    final j = jsonDecode(line);
    if (j is! Map) return null;
    final role = _str(j['role']);
    if (role == null) return null;
    return TraceLine(
      role: role,
      runId: _str(j['run_id']),
      task: _str(j['task']),
      attempt: _int(j['attempt']),
      tier: _str(j['tier']),
      verdict: _str(j['verdict']),
      stage: _str(j['stage']),
      round: _int(j['round']),
      tokensOut: _int(j['tokens_out']),
      persistedAt: _stamp(j['persisted_at']),
      seq: _int(j['seq']),
    );
  } on FormatException {
    return null;
  }
}

String? cycleDate(String dir) {
  final m = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(dir);
  return m?.group(1);
}

class _Entry {
  _Entry(this.run, this.line);
  final String run;
  final TraceLine line;
  String get runId => line.runId ?? run;
  String get at => line.persistedAt ?? '';
}

int _compareEntries(_Entry a, _Entry b) {
  final c = a.at.compareTo(b.at);
  if (c != 0) return c;
  final r = a.runId.compareTo(b.runId);
  if (r != 0) return r;
  return (a.line.seq ?? 0).compareTo(b.line.seq ?? 0);
}

/// Uma entrada por `(runId, seq)`: vale a última em ordem de arquivo entre as de maior `at`, para
/// persist repetido no mesmo segundo não contar duas vezes. Linhas sem `seq` passam todas.
List<_Entry> _dedupe(List<_Entry> entries) {
  final best = <String, _Entry>{};
  for (final e in entries) {
    final seq = e.line.seq;
    if (seq == null) continue;
    final k = '${e.runId}\u0000$seq';
    final cur = best[k];
    if (cur == null || e.at.compareTo(cur.at) >= 0) best[k] = e;
  }
  return [
    for (final e in entries)
      if (e.line.seq == null || identical(best['${e.runId}\u0000${e.line.seq}'], e)) e,
  ];
}

bool _isGate(String role) => role == 'g0' || role == 'g1' || role.startsWith('g1:');

class _TaskAcc {
  final dev = <TraceLine>[];
  TraceLine? lastGate;
  int tokens = 0;
}

/// [traces] mapeia o nome do run (diretório) às linhas brutas do seu `trace.jsonl`.
/// [runsWithoutTrace] e [extraWarnings] vêm do IO, que é quem enxerga os diretórios.
CycleMetrics aggregateCycle(
  String dir,
  Map<String, Object?>? metricsJson,
  Map<String, List<String>> traces, {
  bool current = false,
  int runsWithoutTrace = 0,
  List<String> extraWarnings = const [],
  ReportDoc? report,
}) {
  final meta = metricsJson ?? const <String, Object?>{};
  var ignored = 0;
  final entries = <_Entry>[];
  for (final run in traces.entries) {
    for (final raw in run.value) {
      if (raw.trim().isEmpty) continue;
      final line = parseTraceLine(raw);
      if (line == null) {
        ignored++;
      } else {
        entries.add(_Entry(run.key, line));
      }
    }
  }
  final ordered = _dedupe(entries)..sort(_compareEntries);

  final tokensByRole = {for (final r in metricsRoles) r: 0};
  var hasTokens = false;
  var tokensMissing = 0;
  final accs = <String, _TaskAcc>{};
  final verifyRounds = <String, int>{};
  for (final run in traces.keys) {
    if (run.startsWith('verify-')) verifyRounds[run] = 0;
  }

  for (final e in ordered) {
    final l = e.line;
    final out = l.tokensOut;
    if (out == null) {
      tokensMissing++;
    } else {
      hasTokens = true;
      tokensByRole[roleBucket(l.role)] = tokensByRole[roleBucket(l.role)]! + out;
    }
    final round = l.round;
    if (round != null && verifyRounds.containsKey(e.run) && round > verifyRounds[e.run]!) {
      verifyRounds[e.run] = round;
    }
    final task = l.task;
    if (task == null) continue;
    final key = task.startsWith('V') ? '${e.run}/$task' : task;
    final acc = accs.putIfAbsent(key, _TaskAcc.new);
    acc.tokens += out ?? 0;
    if (l.role == 'dev') {
      acc.dev.add(l);
    } else if (_isGate(l.role)) {
      acc.lastGate = l;
    }
  }

  final tasks = [
    for (final a in accs.entries)
      () {
        final tier0 = a.value.dev.isEmpty ? null : a.value.dev.first.tier;
        final tierFinal = a.value.dev.isEmpty ? null : a.value.dev.last.tier;
        final escalated = tier0 != null && tierFinal != null && tier0 != tierFinal;
        final gatePass = a.value.lastGate?.verdict == 'pass';
        return TaskMetrics(
          key: a.key,
          tier0: tier0,
          tierFinal: tierFinal,
          attempts: a.value.dev.length,
          escalated: escalated,
          passedTier0: gatePass && !escalated,
          blocked: !gatePass,
          tokens: a.value.tokens,
        );
      }(),
  ];

  final total = _scalar(meta['tasks_total']);
  final done = _scalar(meta['tasks_completed']);
  final slug = dir.replaceFirst(RegExp(r'^\d{4}-\d{2}-\d{2}_?'), '');
  final lastAt = ordered
      .map((e) => e.at)
      .where((s) => s.isNotEmpty)
      .fold<String?>(null, (m, s) => m == null || s.compareTo(m) > 0 ? s : m);

  return CycleMetrics(
    dir: dir,
    date: cycleDate(dir),
    feature: _str(meta['feature']) ?? (current ? 'ciclo atual' : (slug.isEmpty ? dir : slug)),
    status: current ? 'em andamento' : (_str(meta['status']) ?? 'desconhecido'),
    tasksLabel: total != null && done != null ? '$done/$total' : null,
    tasks: tasks,
    escalations: tasks.where((t) => t.escalated).length,
    verifyRuns: verifyRounds.length,
    rounds: verifyRounds.values.fold(0, (a, b) => a + b),
    tokensByRole: tokensByRole,
    hasTokens: hasTokens,
    tokensMissing: tokensMissing,
    ignoredLines: ignored,
    runsWithoutTrace: runsWithoutTrace,
    warnings: extraWarnings,
    current: current,
    hasTrace: traces.isNotEmpty,
    lastPersistedAt: lastAt,
    report: report,
  );
}

String? _scalar(Object? v) => v is num || (v is String && v.isNotEmpty) ? v.toString() : null;

List<CycleMetrics> orderCycles(List<CycleMetrics> cycles) {
  int cmp(CycleMetrics a, CycleMetrics b) {
    if (a.current != b.current) return a.current ? -1 : 1;
    final d = (b.date ?? '').compareTo(a.date ?? '');
    if (d != 0) return d;
    final p = (b.lastPersistedAt ?? '').compareTo(a.lastPersistedAt ?? '');
    if (p != 0) return p;
    return b.dir.compareTo(a.dir);
  }

  return [...cycles]..sort(cmp);
}

ProjectMetrics projectSummary(List<CycleMetrics> cycles) {
  final tokens = {for (final r in metricsRoles) r: 0};
  var tasks = 0;
  var passed = 0;
  var esc = 0;
  var hasTokens = false;
  for (final c in cycles) {
    tasks += c.tasks.length;
    passed += c.tasks.where((t) => t.passedTier0).length;
    esc += c.escalations;
    hasTokens = hasTokens || c.hasTokens;
    for (final e in c.tokensByRole.entries) {
      tokens[e.key] = (tokens[e.key] ?? 0) + e.value;
    }
  }
  return ProjectMetrics(
    cycles: orderCycles(cycles),
    completedCycles: cycles.where((c) => !c.current && c.status == 'completed').length,
    tasks: tasks,
    passedTier0: passed,
    escalations: esc,
    tokensByRole: tokens,
    hasTokens: hasTokens,
  );
}

/// Ciclo arquivado mais recente com `report.json`; o ciclo atual não conta (o Fluxo já o mostra).
CycleMetrics? lastCycleWithReport(ProjectMetrics metrics) =>
    metrics.cycles.where((c) => !c.current && c.report != null).firstOrNull;
