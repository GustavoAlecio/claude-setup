import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/flow_aggregates.dart';
import '../../data/models.dart';
import '../../data/report_models.dart';
import '../../data/report_parser.dart';
import '../../data/session_models.dart';
import '../sessions/session_labels.dart';
import '../sessions/session_view.dart';
import 'stage_timeline.dart';

/// Sessão do projeto rodando uma skill do pipeline; vem das sessões, não do relatório.
class StageBanner extends StatelessWidget {
  const StageBanner({super.key, required this.session, this.showOpenLink = true});

  final SessionSummary session;
  final bool showOpenLink;

  @override
  Widget build(BuildContext context) => LiveSessionSummary(session: session, builder: _banner);

  Widget _banner(BuildContext context, SessionSummary session) {
    final c = context.colors;
    return Container(
      key: const ValueKey('stage-banner'),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: c.running.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.running.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.play_circle_outline, size: 18, color: c.running),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Etapa em andamento: ${session.command} (${sessionStatusLabel(session)})',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: c.textPrimary),
            ),
          ),
          if (showOpenLink)
            TextButton(
              onPressed: () => context.go('/p/${session.project}/sessions/${session.id}'),
              child: Text('abrir sessão', style: TextStyle(color: c.running, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

const _taskColumns = <(String, double?)>[
  ('Task', 48),
  ('Título', null),
  ('Compl.', 64),
  ('Tier0 → final', 210),
  ('Tentativas', 80),
  ('Escaladas', 76),
  ('Status', 110),
];

class TasksPanel extends StatelessWidget {
  const TasksPanel({super.key, required this.cycle});

  final Cycle cycle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = taskTable(cycle);
    Widget cell(Widget child, double width) => SizedBox(width: width, child: child);
    Widget text(String s) => Text(s, style: TextStyle(fontSize: 12, color: c.textSecondary));
    return Panel(
      key: const ValueKey('flow-tasks'),
      title: 'Tasks',
      child: rows.isEmpty
          ? const Muted('sem tasks neste ciclo')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TableHeaderRow(_taskColumns),
                for (final t in rows)
                  Container(
                    key: ValueKey('flow-task-${t.id}'),
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.border)),
                    ),
                    child: Row(
                      children: [
                        cell(Mono(t.id, color: c.textPrimary), 48),
                        Expanded(
                          child: Text(t.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                        ),
                        cell(
                          Align(
                            alignment: Alignment.centerLeft,
                            child: ComplexityTag(t.complexity, risk: t.risk),
                          ),
                          64,
                        ),
                        cell(
                          Row(
                            children: [
                              Flexible(child: TierChip(t.tier0)),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                child: Icon(Icons.arrow_forward, size: 12, color: c.textMuted),
                              ),
                              Flexible(child: TierChip(t.tierFinal)),
                            ],
                          ),
                          210,
                        ),
                        cell(text('${t.attempts}'), 80),
                        cell(text('${t.escalations}'), 76),
                        cell(Align(alignment: Alignment.centerLeft, child: VerdictBadge(t.status)), 110),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class VerifyPanel extends StatelessWidget {
  const VerifyPanel({super.key, required this.runs});

  final List<Run> runs;

  @override
  Widget build(BuildContext context) {
    final rounds = verifySummary(runs);
    return Panel(
      key: const ValueKey('flow-verify'),
      title: 'Verify',
      child: rounds.isEmpty
          ? const Muted('nenhum verify rodou neste ciclo')
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final r in rounds) _VerifyRound(r)]),
    );
  }
}

class _VerifyRound extends StatelessWidget {
  const _VerifyRound(this.round);

  final VerifyRoundSummary round;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: ValueKey('flow-verify-${round.runId}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Mono(round.runId, color: c.textPrimary),
              const SizedBox(width: 10),
              if (round.round case final n?) ...[Muted('rodada $n'), const SizedBox(width: 10)],
              VerdictBadge(round.status),
              if (round.reason case final reason?) ...[
                const SizedBox(width: 10),
                Flexible(child: Mono(reason, size: 11)),
              ],
            ],
          ),
          if (round.gates.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final g in round.gates)
                  Pill(label: '${g.gate} ${VerdictBadge.label(g.verdict)}', color: c.verdict(g.verdict), mono: true),
              ],
            ),
          ],
          for (final f in round.blocking)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Pill(label: f.severity, color: c.fail, dot: false),
                  const SizedBox(width: 8),
                  Mono(f.line == null ? f.file : '${f.file}:${f.line}', size: 11),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(f.message, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                  ),
                ],
              ),
            ),
          if (round.fixTasks.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final t in round.fixTasks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(width: 36, child: Mono(t.id, color: c.textPrimary, size: 11)),
                    Expanded(
                      child: Text(t.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    ),
                    VerdictBadge(t.status),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Todas as decisões do relatório, na ordem das etapas, com filtro por autor.
class DecisionsPanel extends StatefulWidget {
  const DecisionsPanel({super.key, required this.report});

  final ReportDoc? report;

  @override
  State<DecisionsPanel> createState() => _DecisionsPanelState();
}

class _DecisionsPanelState extends State<DecisionsPanel> {
  String? _author;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final authors = decisionAuthors(report);
    final author = authors.contains(_author) ? _author : null;
    final decisions = allDecisions(report, by: author);
    return Panel(
      key: const ValueKey('flow-decisions'),
      title: 'Decisões',
      child: report == null
          ? const Muted('sem relatório deste ciclo')
          : authors.isEmpty
          ? const Muted('nenhuma decisão registrada')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _filter(context, null, 'todos', author == null),
                    for (final a in authors) _filter(context, a, a, author == a),
                  ],
                ),
                const SizedBox(height: 8),
                for (final d in decisions) DecisionTile(decision: d.decision, stage: d.stage),
              ],
            ),
    );
  }

  Widget _filter(BuildContext context, String? value, String label, bool selected) => ChoiceChip(
    key: ValueKey('decision-filter-${value ?? '*'}'),
    label: Text(label, style: const TextStyle(fontSize: 11)),
    selected: selected,
    showCheckmark: false,
    visualDensity: VisualDensity.compact,
    onSelected: (_) => setState(() => _author = value),
  );
}
