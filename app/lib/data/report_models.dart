import 'models.dart';

/// Contrato `report.json` (version 1), escrito só por `bin/wf-report.py`; o app lê um recorte e ignora o resto.
class ReportDoc {
  const ReportDoc({
    required this.feature,
    required this.startedAt,
    required this.stages,
    this.qa = const [],
    this.realDataMd,
    this.realDataStatus,
    this.pr,
  });

  final String? feature;
  final String? startedAt;

  /// Roteiro de QA manual; vazio = sem painel.
  final List<String> qa;

  /// Evidência do teste com dados reais; `null` com [realDataStatus] = "não executado".
  final String? realDataMd;
  final String? realDataStatus;
  final ReportPr? pr;

  /// [realDataMd] só quando tem conteúdo além de espaço.
  String? get realDataMarkdown => (realDataMd ?? '').trim().isEmpty ? null : realDataMd;

  bool get hasRealData => realDataMarkdown != null || (realDataStatus ?? '').trim().isNotEmpty;

  /// Na ordem do enum [Stage], no máximo uma entrada por etapa.
  final List<StageReport> stages;

  StageReport? stage(Stage s) => stages.where((x) => x.stage == s).firstOrNull;
}

class ReportPr {
  const ReportPr({required this.url, this.number});

  final String url;
  final int? number;
}

enum ReportStatus { running, done, blocked }

class StageReport {
  const StageReport({
    required this.stage,
    required this.status,
    this.attempt = 1,
    this.startedAt,
    this.endedAt,
    this.summaryMd = '',
    this.decisions = const [],
    this.findings = const [],
    this.artifacts = const [],
    this.sessionId,
    this.gate,
  });

  final Stage stage;
  final ReportStatus status;
  final int attempt;
  final String? startedAt;
  final String? endedAt;
  final String summaryMd;
  final List<ReportDecision> decisions;
  final List<ReportFindings> findings;
  final List<String> artifacts;

  /// Engine session that ran the stage; absent when it ran in a terminal.
  final String? sessionId;

  /// Decision brief written by `wf-report.py brief`; the owner stage of `spec` is `challenge`.
  final ReportGate? gate;
}

enum GateStatus { open, revising, approved, passed, rejected }

/// `stages[].gate`. `base` and `tree` are not read.
class ReportGate {
  const ReportGate({
    required this.name,
    required this.status,
    this.round = 1,
    this.summary = '',
    this.risks = const [],
    this.questions = const [],
    this.history = const [],
    this.changes = const [],
    this.cut = const [],
    this.omitted = const GateOmitted(),
    this.artifact,
    this.answer,
    this.map,
    this.decidedAt,
  });

  /// `spec`, `plan`, `tasks` or `pr`.
  final String name;
  final GateStatus status;
  final int round;
  final String summary;
  final List<GateRisk> risks;
  final List<GateQuestion> questions;
  final List<GateRound> history;
  final List<String> changes;
  final List<GateCut> cut;
  final GateOmitted omitted;
  final String? artifact;

  /// Free-text adjust of a block without questions.
  final GateAnswer? answer;

  /// Architecture map of the gate (ADR 0030); `null` keeps the screen as it was before maps.
  final GateMap? map;

  /// ISO UTC written by the script when the block closes; absent in reports from before it.
  final String? decidedAt;
}

/// `ignore` and node `paths` are not read.
class GateMap {
  const GateMap({
    required this.nodes,
    this.summary = '',
    this.edges = const [],
    this.approaches = const [],
    this.gains = const [],
    this.costs = const [],
  });

  final String summary;

  /// Never empty, ids unique.
  final List<MapNode> nodes;

  /// Both ends are ids of [nodes].
  final List<MapEdge> edges;
  final List<MapApproach> approaches;
  final List<String> gains;
  final List<String> costs;

  /// What was built (gate `pr`) rather than what the plan proposes; the screen decides by this, not by the gate name.
  bool get built => nodes.any((n) => n.built != null);
}

/// Plan state of a node; [added] is `new` on the wire.
enum MapNodeState {
  added('new'),
  changed('changed'),
  existing('existing');

  const MapNodeState(this.wire);

  final String wire;
}

/// How a node came out against the plan, computed by `wf-report.py` from the diff.
enum BuiltState { planned, untouched, existing, touched, unplanned }

class MapNode {
  const MapNode({required this.id, required this.label, this.state, this.built, this.note, this.files = const []});

  final String id;
  final String label;
  final MapNodeState? state;
  final BuiltState? built;
  final String? note;

  /// Changed files of the diff that fall in this node.
  final List<String> files;
}

class MapEdge {
  const MapEdge({required this.from, required this.to, this.label});

  final String from;
  final String to;
  final String? label;
}

class MapApproach {
  const MapApproach({required this.label, required this.text, this.chosen = false});

  final String label;
  final String text;
  final bool chosen;
}

class GateRisk {
  const GateRisk({required this.id, required this.text, this.source});

  final String id;
  final String text;

  /// `author` or `critic`.
  final String? source;
}

class GateQuestion {
  const GateQuestion({
    required this.id,
    required this.text,
    this.header,
    this.options = const [],
    this.assumed,
    this.prefers = const {},
    this.answer,
    this.why,
    this.anchor,
  });

  final String id;
  final String text;
  final String? header;
  final List<GateOption> options;

  /// Option id taken when the user just approves.
  final String? assumed;

  /// Option id each side prefers, by side (`author`, `critic`).
  final Map<String, String> prefers;
  final GateAnswer? answer;
  final String? why;

  /// Lines of the new file in the diff the question points at.
  final GateAnchor? anchor;
}

class GateAnchor {
  const GateAnchor({required this.path, required this.start, required this.end});

  final String path;
  final int start;
  final int end;

  String get label => '$path:$start-$end';
}

class GateOption {
  const GateOption({required this.id, required this.label, this.consequence = ''});

  final String id;
  final String label;
  final String consequence;
}

/// An option, free text, or both (the `change` adjust of gate `pr`).
class GateAnswer {
  const GateAnswer({this.optionId, this.text});

  final String? optionId;
  final String? text;
}

class GateRound {
  const GateRound({required this.round, this.questions = const [], this.answer});

  final int round;
  final List<GateQuestion> questions;

  /// Free-text adjust of that round when it had no questions.
  final GateAnswer? answer;
}

class GateCut {
  const GateCut({required this.id, required this.text});

  final String id;
  final String text;
}

class GateOmitted {
  const GateOmitted({this.risks = 0, this.questions = 0, this.candidates = 0});

  final int risks;
  final int questions;
  final int candidates;
}

enum DecisionKind { decision, mistake }

class ReportDecision {
  const ReportDecision({
    required this.id,
    required this.by,
    required this.textMd,
    this.alternativeMd,
    this.kind = DecisionKind.decision,
  });

  final String id;

  /// `orchestrator`, `challenger`, `user` ou `agent:<task>`.
  final String by;
  final String textMd;
  final String? alternativeMd;
  final DecisionKind kind;
}

/// Decisão com a etapa de origem, para o painel que junta todas.
class StageDecision {
  const StageDecision(this.stage, this.decision);

  final Stage stage;
  final ReportDecision decision;
}

class AcceptedFinding {
  const AcceptedFinding({required this.id, required this.severity, required this.textMd});

  final String id;
  final String severity;
  final String textMd;
}

class RejectedFinding {
  const RejectedFinding({required this.id, required this.textMd, required this.reasonMd});

  final String id;
  final String textMd;
  final String reasonMd;
}

class ReportFindings {
  const ReportFindings({required this.source, this.accepted = const [], this.rejected = const []});

  final String source;
  final List<AcceptedFinding> accepted;
  final List<RejectedFinding> rejected;
}
