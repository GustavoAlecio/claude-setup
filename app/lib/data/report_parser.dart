import 'dart:convert';

import 'models.dart';
import 'report_models.dart';

const kReportFileLimit = 2 * 1024 * 1024;

/// `null` para JSON inválido, raiz que não é objeto ou `version != 1`: o app trata como sem relatório.
/// Decisões sem `id` ou `text_md` são descartadas. Entradas de etapa malformadas, repetidas ou fora do enum são descartadas; campos desconhecidos, ignorados.
ReportDoc? parseReport(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['version'] != 1) return null;
  final cycle = decoded['cycle'];
  final byStage = <Stage, StageReport>{};
  for (final raw in _maps(decoded['stages'])) {
    final stage = _stage(raw['stage']);
    if (stage == null || byStage.containsKey(stage)) continue;
    byStage[stage] = _parseStage(stage, raw);
  }
  return ReportDoc(
    feature: cycle is Map ? _string(cycle['feature']) : null,
    startedAt: cycle is Map ? _string(cycle['started_at']) : null,
    stages: [for (final s in Stage.values) ?byStage[s]],
    qa: [
      for (final item in _strings(decoded['qa']))
        if (item.trim().isNotEmpty) item,
    ],
    realDataMd: _string(decoded['real_data_md']),
    realDataStatus: _string(decoded['real_data_status']),
    pr: _parsePr(decoded['pr']),
  );
}

ReportPr? _parsePr(Object? raw) {
  if (raw is! Map) return null;
  final url = _string(raw['url']);
  if (url == null || url.isEmpty) return null;
  return ReportPr(url: url, number: raw['number'] is int ? raw['number'] as int : null);
}

/// Decisões de todas as etapas na ordem das etapas e, dentro de cada uma, na ordem gravada.
/// [by] filtra pelo autor exato.
List<StageDecision> allDecisions(ReportDoc? report, {String? by}) => [
  for (final s in report?.stages ?? const <StageReport>[])
    for (final d in s.decisions)
      if (by == null || d.by == by) StageDecision(s.stage, d),
];

/// Autores distintos na ordem da primeira aparição.
List<String> decisionAuthors(ReportDoc? report) => {for (final d in allDecisions(report)) d.decision.by}.toList();

/// The stage a session reported last: one session may chain several stages, and the newest `started_at` wins
/// (later stage on a tie). `null` without a match.
StageReport? stageOfSession(ReportDoc? report, String sessionId) {
  StageReport? best;
  for (final s in report?.stages ?? const <StageReport>[]) {
    if (s.sessionId != sessionId) continue;
    if (best == null || (s.startedAt ?? '').compareTo(best.startedAt ?? '') >= 0) best = s;
  }
  return best;
}

StageReport _parseStage(Stage stage, Map<String, dynamic> raw) => StageReport(
  stage: stage,
  status: switch (raw['status']) {
    'done' => ReportStatus.done,
    'blocked' => ReportStatus.blocked,
    _ => ReportStatus.running,
  },
  attempt: raw['attempt'] is int ? raw['attempt'] as int : 1,
  startedAt: _string(raw['started_at']),
  endedAt: _string(raw['ended_at']),
  summaryMd: _string(raw['summary_md']) ?? '',
  decisions: [
    for (final d in _maps(raw['decisions']))
      if (_string(d['text_md']) != null && _string(d['id']) != null)
        ReportDecision(
          id: d['id'] as String,
          by: _string(d['by']) ?? 'orchestrator',
          textMd: d['text_md'] as String,
          alternativeMd: _string(d['alternative_md']),
          kind: d['kind'] == 'mistake' ? DecisionKind.mistake : DecisionKind.decision,
        ),
  ],
  findings: [
    for (final f in _maps(raw['findings']))
      ReportFindings(
        source: _string(f['source']) ?? '',
        accepted: [
          for (final a in _maps(f['accepted']))
            AcceptedFinding(
              id: _string(a['id']) ?? '',
              severity: _string(a['severity']) ?? '',
              textMd: _string(a['text_md']) ?? '',
            ),
        ],
        rejected: [
          for (final r in _maps(f['rejected']))
            RejectedFinding(
              id: _string(r['id']) ?? '',
              textMd: _string(r['text_md']) ?? '',
              reasonMd: _string(r['reason_md']) ?? '',
            ),
        ],
      ),
  ],
  artifacts: _strings(raw['artifacts']),
  sessionId: _string(raw['session_id']),
  gate: _parseGate(raw['gate']),
);

/// `null` without `name` or a known `status`; malformed items inside are dropped, never thrown.
ReportGate? _parseGate(Object? raw) {
  if (raw is! Map) return null;
  final name = _string(raw['name']);
  final status = GateStatus.values.where((s) => s.name == raw['status']).firstOrNull;
  if (name == null || name.isEmpty || status == null) return null;
  final omitted = raw['omitted'];
  return ReportGate(
    name: name,
    status: status,
    round: _int(raw['round']) ?? 1,
    summary: _string(raw['summary']) ?? '',
    risks: [
      for (final r in _maps(raw['risks']))
        if (_string(r['id']) != null && _string(r['text']) != null)
          GateRisk(id: r['id'] as String, text: r['text'] as String, source: _string(r['source'])),
    ],
    questions: _questions(raw['questions']),
    history: [
      for (final h in _maps(raw['history']))
        if (_int(h['round']) != null)
          GateRound(
            round: _int(h['round'])!,
            questions: _questions(h['questions']),
            answer: _answer(h['answer'], null),
          ),
    ],
    changes: _strings(raw['changes']),
    cut: [
      for (final c in _maps(raw['cut']))
        if (_string(c['id']) != null && _string(c['text']) != null)
          GateCut(id: c['id'] as String, text: c['text'] as String),
    ],
    omitted: omitted is Map
        ? GateOmitted(
            risks: _int(omitted['risks']) ?? 0,
            questions: _int(omitted['questions']) ?? 0,
            candidates: _int(omitted['candidates']) ?? 0,
          )
        : const GateOmitted(),
    artifact: _string(raw['artifact']),
    answer: _answer(raw['answer'], null),
    map: _parseMap(raw['map']),
  );
}

/// `null` when not an object or without a readable node. Nodes need a non-empty `id` and `label` (a repeated id is
/// dropped), an unknown `state`/`built` becomes `null`, and an edge must link two read nodes.
GateMap? _parseMap(Object? raw) {
  if (raw is! Map) return null;
  final nodes = <String, MapNode>{};
  for (final n in _maps(raw['nodes'])) {
    final id = _string(n['id']);
    final label = _string(n['label']);
    if (id == null || id.isEmpty || label == null || label.isEmpty || nodes.containsKey(id)) continue;
    nodes[id] = MapNode(
      id: id,
      label: label,
      state: MapNodeState.values.where((s) => s.wire == n['state']).firstOrNull,
      built: BuiltState.values.where((s) => s.name == n['built']).firstOrNull,
      note: _string(n['note']),
      files: _strings(n['files']),
    );
  }
  if (nodes.isEmpty) return null;
  return GateMap(
    summary: _string(raw['summary']) ?? '',
    nodes: nodes.values.toList(),
    edges: [
      for (final e in _maps(raw['edges']))
        if (nodes.containsKey(e['from']) && nodes.containsKey(e['to']))
          MapEdge(from: e['from'] as String, to: e['to'] as String, label: _string(e['label'])),
    ],
    approaches: [
      for (final a in _maps(raw['approaches']))
        if (_string(a['label']) != null && _string(a['text']) != null)
          MapApproach(label: a['label'] as String, text: a['text'] as String, chosen: a['chosen'] == true),
    ],
    gains: _strings(raw['gains']),
    costs: _strings(raw['costs']),
  );
}

List<GateQuestion> _questions(Object? raw) => [
  for (final q in _maps(raw))
    if (_string(q['id']) != null && _string(q['text']) != null)
      GateQuestion(
        id: q['id'] as String,
        text: q['text'] as String,
        header: _string(q['header']),
        options: [
          for (final o in _maps(q['options']))
            if (_string(o['id']) != null && _string(o['label']) != null)
              GateOption(
                id: o['id'] as String,
                label: o['label'] as String,
                consequence: _string(o['consequence']) ?? '',
              ),
        ],
        assumed: _string(q['assumed']),
        prefers: {
          if (q['prefers'] is Map)
            for (final e in (q['prefers'] as Map).entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        },
        answer: _answer(q['answer'], _string(q['answer_text'])),
        why: _string(q['why']),
        anchor: _anchor(q['anchor']),
      ),
];

GateAnchor? _anchor(Object? raw) {
  if (raw is! Map) return null;
  final path = _string(raw['path']);
  final start = _int(raw['start']);
  final end = _int(raw['end']);
  if (path == null || path.isEmpty || start == null || end == null || start < 1 || start > end) return null;
  return GateAnchor(path: path, start: start, end: end);
}

/// `wf-report.py` records an option id as a bare string and free text as `{text}`; `answer_text` rides along an option.
GateAnswer? _answer(Object? raw, String? note) {
  if (raw is String) return GateAnswer(optionId: raw, text: note);
  if (raw is Map && raw['text'] is String) return GateAnswer(text: raw['text'] as String);
  return null;
}

Stage? _stage(Object? v) => v is String ? Stage.values.where((s) => s.name == v).firstOrNull : null;

String? _string(Object? v) => v is String ? v : null;

int? _int(Object? v) => v is int ? v : null;

List<String> _strings(Object? v) => [if (v is List) ...v.whereType<String>()];

Iterable<Map<String, dynamic>> _maps(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => m.cast<String, dynamic>()) : const [];
