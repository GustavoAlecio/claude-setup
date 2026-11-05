import 'models.dart';

/// Contrato `report.json` (version 1), escrito só por `bin/wf-report.py`; o app lê um recorte e ignora o resto.
class ReportDoc {
  const ReportDoc({required this.feature, required this.startedAt, required this.stages});

  final String? feature;
  final String? startedAt;

  /// Na ordem do enum [Stage], no máximo uma entrada por etapa.
  final List<StageReport> stages;

  StageReport? stage(Stage s) => stages.where((x) => x.stage == s).firstOrNull;
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
