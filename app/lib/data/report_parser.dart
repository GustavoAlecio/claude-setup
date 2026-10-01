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
  );
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
);

Stage? _stage(Object? v) => v is String ? Stage.values.where((s) => s.name == v).firstOrNull : null;

String? _string(Object? v) => v is String ? v : null;

List<String> _strings(Object? v) => [if (v is List) ...v.whereType<String>()];

Iterable<Map<String, dynamic>> _maps(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => m.cast<String, dynamic>()) : const [];
