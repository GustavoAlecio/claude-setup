import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/inline_markdown.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/session_launcher.dart';
import '../../data/flow_aggregates.dart';
import '../../data/models.dart';
import '../../data/report_models.dart';

/// As 8 etapas com o relatório de cada uma colapsável. [project] `null` é o modo leitura (histórico): os
/// artefatos aparecem sem link para a aba Artefatos.
class StageTimeline extends StatefulWidget {
  const StageTimeline({
    super.key,
    required this.report,
    this.derived = const {},
    this.stageMinutes = const {},
    this.project,
  });

  final ReportDoc? report;
  final Map<Stage, StageState> derived;
  final Map<Stage, int> stageMinutes;
  final String? project;

  @override
  State<StageTimeline> createState() => _StageTimelineState();
}

class _StageTimelineState extends State<StageTimeline> with SessionLauncher<StageTimeline> {
  final _expanded = <Stage>{};

  @override
  String get logName => 'StageTimeline';

  StageState _state(Stage s, StageReport? entry) => switch (entry?.status) {
    ReportStatus.done => StageState.done,
    ReportStatus.running => StageState.current,
    ReportStatus.blocked => StageState.blocked,
    null => widget.derived[s] ?? StageState.pending,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Panel(
      title: 'Linha do tempo',
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in Stage.values) ...[
            if (s != Stage.values.first) Divider(height: 1, color: c.border),
            _stage(context, s, widget.report?.stage(s)),
          ],
        ],
      ),
    );
  }

  Widget _stage(BuildContext context, Stage s, StageReport? entry) {
    final c = context.colors;
    final state = _state(s, entry);
    final expanded = entry != null && _expanded.contains(s);
    final minutes = widget.stageMinutes[s];
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          _StageDot(state),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: Mono(s.label, size: 12, color: state == StageState.pending ? c.textMuted : c.textPrimary),
          ),
          SizedBox(
            width: 100,
            child: Muted(switch (state) {
              StageState.current => 'em andamento',
              StageState.blocked => 'bloqueada',
              StageState.done when minutes != null => '${minutes}m',
              StageState.done => 'concluída',
              StageState.pending => '—',
            }, size: 11),
          ),
          if (entry != null && entry.attempt > 1) Pill(label: 'tentativa ${entry.attempt}', color: c.warn, dot: false),
          const Spacer(),
          if (entry == null)
            const Muted('sem relatório desta etapa', size: 11)
          else
            Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: c.textMuted),
        ],
      ),
    );
    return Column(
      key: ValueKey('timeline-stage-${s.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (entry == null)
          header
        else
          InkWell(
            onTap: () => setState(() {
              if (!_expanded.remove(s)) _expanded.add(s);
            }),
            child: header,
          ),
        if (expanded) _body(context, entry),
      ],
    );
  }

  Widget _body(BuildContext context, StageReport entry) {
    final c = context.colors;
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.textMuted),
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
    final project = widget.project;
    return Padding(
      key: ValueKey('timeline-report-${entry.stage.name}'),
      padding: const EdgeInsets.fromLTRB(50, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entry.summaryMd.trim().isEmpty)
            const Muted('sem resumo')
          else
            MarkdownView(entry.summaryMd, onLink: openLink),
          Padding(padding: const EdgeInsets.only(top: 10), child: Muted('${entry.attempt} tentativa(s)', size: 11)),
          for (final f in entry.findings)
            if (f.accepted.isNotEmpty || f.rejected.isNotEmpty)
              section('Achados · ${f.source}', [
                for (final a in f.accepted) _AcceptedRow(a),
                for (final r in f.rejected) _RejectedRow(r),
              ]),
          if (entry.decisions.isNotEmpty)
            section('Decisões', [for (final d in entry.decisions) DecisionTile(decision: d)]),
          if (entry.artifacts.isNotEmpty)
            section('Artefatos', [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final rel in entry.artifacts)
                    if (project == null)
                      Mono(rel)
                    else
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: c.accent),
                        onPressed: () => context.go(
                          Uri(pathSegments: ['', 'p', project, 'artifacts'], queryParameters: {'doc': rel}).toString(),
                        ),
                        child: Text(rel, style: const TextStyle(fontSize: 12)),
                      ),
                ],
              ),
            ]),
        ],
      ),
    );
  }
}

class _StageDot extends StatelessWidget {
  const _StageDot(this.state);

  final StageState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (state) {
      StageState.done => c.pass,
      StageState.current => c.running,
      StageState.blocked => c.fail,
      StageState.pending => c.idle,
    };
    final icon = switch (state) {
      StageState.done => Icons.check,
      StageState.current => Icons.more_horiz,
      StageState.blocked => Icons.priority_high,
      StageState.pending => null,
    };
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: state == StageState.pending ? null : color.withValues(alpha: 0.16),
        border: Border.all(color: color, width: 1.5),
      ),
      child: icon == null ? null : Icon(icon, size: 12, color: color),
    );
  }
}

class _AcceptedRow extends StatelessWidget {
  const _AcceptedRow(this.finding);

  final AcceptedFinding finding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pill(label: 'aceito', color: c.pass, dot: false),
          const SizedBox(width: 6),
          if (finding.severity.isNotEmpty) ...[
            Pill(label: finding.severity, color: c.warn, dot: false),
            const SizedBox(width: 6),
          ],
          Mono(finding.id, color: c.textPrimary),
          const SizedBox(width: 8),
          Expanded(child: InlineMarkdown(finding.textMd)),
        ],
      ),
    );
  }
}

class _RejectedRow extends StatelessWidget {
  const _RejectedRow(this.finding);

  final RejectedFinding finding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pill(label: 'rejeitado', color: c.idle, dot: false),
          const SizedBox(width: 6),
          Mono(finding.id, color: c.textPrimary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InlineMarkdown(finding.textMd),
                if (finding.reasonMd.isNotEmpty)
                  InlineMarkdown(
                    'motivo: ${finding.reasonMd}',
                    style: TextStyle(fontSize: 12, height: 1.5, color: c.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Color decisionAuthorColor(AppColors c, String by) => switch (by) {
  'orchestrator' => c.accent,
  'challenger' => c.warn,
  'user' => c.pass,
  _ => c.running,
};

/// Uma decisão com o selo do autor; `mistake` destacado com a cor `fail`. [stage] aparece no painel que junta
/// as decisões de todas as etapas.
class DecisionTile extends StatelessWidget {
  const DecisionTile({super.key, required this.decision, this.stage});

  final ReportDecision decision;
  final Stage? stage;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mistake = decision.kind == DecisionKind.mistake;
    return Container(
      key: ValueKey('decision-${decision.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: BoxDecoration(
        color: mistake ? c.fail.withValues(alpha: 0.06) : null,
        border: Border(left: BorderSide(color: mistake ? c.fail : c.border, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (stage case final stage?) ...[Mono(stage.label, size: 11), const SizedBox(width: 8)],
              Flexible(
                child: Pill(label: decision.by, color: decisionAuthorColor(c, decision.by), mono: true, dot: false),
              ),
              if (mistake) ...[const SizedBox(width: 6), Pill(label: 'erro', color: c.fail, dot: false)],
            ],
          ),
          const SizedBox(height: 4),
          InlineMarkdown(
            decision.textMd,
            style: TextStyle(fontSize: 13, height: 1.5, color: mistake ? c.fail : c.textPrimary),
          ),
          if (decision.alternativeMd case final alternative?)
            InlineMarkdown(
              'alternativa: $alternative',
              style: TextStyle(fontSize: 12, height: 1.5, color: c.textSecondary),
            ),
        ],
      ),
    );
  }
}
