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
              '${_isSupport(session.command) ? 'Sessão de apoio' : 'Etapa'} em andamento: '
              '${session.command} (${sessionStatusLabel(session)})',
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

/// "Etapa n de 8" over one segment per stage, with the link that opens the timeline below it.
class CycleSteps extends StatelessWidget {
  const CycleSteps({super.key, required this.steps, required this.open, required this.onToggle});

  /// `cycleSteps` of the cycle.
  final ({int position, int total, Map<Stage, StageState> states}) steps;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final current = Stage.values[steps.position - 1];
    Widget segment(Stage s) => Container(
      key: ValueKey('cycle-step-${s.name}'),
      height: 4,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        color: switch (steps.states[s] ?? StageState.pending) {
          StageState.done => c.textSecondary,
          StageState.current => c.textPrimary,
          StageState.blocked => c.fail,
          StageState.pending => c.border,
        },
      ),
    );
    return Column(
      key: const ValueKey('cycle-steps'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Etapa ${steps.position} de ${steps.total}',
                style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
            ),
            TextButton(
              key: const ValueKey('cycle-steps-toggle'),
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: onToggle,
              child: Text(open ? 'ocultar etapas' : 'ver etapas', style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        Row(
          children: [
            for (final s in Stage.values) ...[
              if (s != Stage.values.first) const SizedBox(width: 4),
              Expanded(child: segment(s)),
              if (s == current) ...[const SizedBox(width: 6), Mono(s.label, size: 11, color: c.textPrimary)],
            ],
          ],
        ),
      ],
    );
  }
}

/// The cycle's state in one sentence and its one action; renders [now] as `cycleNow` returned it.
class CycleNowCard extends StatelessWidget {
  const CycleNowCard({super.key, required this.now, required this.onAction});

  final CycleNow now;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final needsYou = now.eyebrow == kNeedsYou;
    final action = now.action;
    return Container(
      key: const ValueKey('cycle-now'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            now.eyebrow,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: needsYou ? c.warn : c.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            now.title,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            now.detail,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: c.textSecondary),
          ),
          if (action != null) ...[
            const SizedBox(height: 16),
            if (needsYou)
              FilledButton(
                key: const ValueKey('cycle-now-action'),
                style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
                onPressed: onAction,
                child: Text(action),
              )
            else
              OutlinedButton(
                key: const ValueKey('cycle-now-action'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  side: BorderSide(color: c.borderStrong),
                ),
                onPressed: onAction,
                child: Text(action),
              ),
          ],
        ],
      ),
    );
  }
}

/// The cycle's tasks, one line each; a line opens the task in its newest run with an attempt. Nothing without tasks.
class CycleTaskList extends StatelessWidget {
  const CycleTaskList({super.key, required this.project, required this.cycle});

  final String project;
  final Cycle cycle;

  @override
  Widget build(BuildContext context) {
    final lines = cycleTaskLines(cycle);
    if (lines.isEmpty) return const SizedBox.shrink();
    final done = lines.where((l) => l.state == TaskLineState.done).length;
    final c = context.colors;
    return Padding(
      key: const ValueKey('cycle-tasks'),
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Tasks',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
              ),
              const SizedBox(width: 10),
              Muted('$done de ${lines.length} prontas'),
            ],
          ),
          const SizedBox(height: 6),
          for (final line in lines) _line(context, line),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, CycleTaskLine line) {
    final c = context.colors;
    final (icon, color) = switch (line.state) {
      TaskLineState.done => (Icons.check_circle_outline, c.pass),
      TaskLineState.running => (Icons.play_circle_outline, c.running),
      TaskLineState.blocked => (Icons.error_outline, c.fail),
      TaskLineState.queued => (Icons.radio_button_unchecked, c.idle),
    };
    final run = line.run;
    return InkWell(
      key: ValueKey('cycle-task-${line.id}'),
      onTap: run == null ? null : () => context.go(taskLocation(project, run, line.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                line.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: line.state == TaskLineState.running ? FontWeight.w600 : FontWeight.w400,
                  color: c.textPrimary,
                ),
              ),
            ),
            if (line.note.isNotEmpty) ...[const SizedBox(width: 10), Muted(line.note, size: 11)],
          ],
        ),
      ),
    );
  }
}

/// The request that asks the gate the cycle card shows ([cardGate]) becomes a note without button (the one "Decidir" is
/// the cycle card); any other question keeps its card.
RequestOverride gateRequestOverride(StageReport? cardGate) => (detail, request) {
  final gate = cardGate?.gate;
  if (gate == null || cardGate!.sessionId != detail.summary.id) return null;
  if (matchGateRequest(gate, detail)?.requestId != request.requestId) return null;
  return Padding(
    key: ValueKey('flow-gate-request-${gate.name}'),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: const Muted('decida no cartão do ciclo'),
  );
};

/// "Passou sem você": gates that went through without asking, each opening its screen to read.
class PassedGates extends StatelessWidget {
  const PassedGates({super.key, required this.project, required this.stages});

  final String project;
  final List<StageReport> stages;

  @override
  Widget build(BuildContext context) {
    if (stages.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Muted('Passou sem você', size: 11),
          const SizedBox(height: 4),
          for (final s in stages)
            Row(
              key: ValueKey('flow-passed-${s.gate!.name}'),
              children: [
                Icon(Icons.check_circle_outline, size: 15, color: c.pass),
                const SizedBox(width: 8),
                Mono(s.gate!.name, color: c.textPrimary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.gate!.summary,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: () => context.go(gateLocation(project, s.gate!.name)),
                  child: Text('ver', style: TextStyle(color: c.accent, fontSize: 12)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// `/fix` corrects a blocked stage; it is not a stage of the timeline itself.
bool _isSupport(String command) => command.trimLeft().startsWith('/fix');

class VerifyPanel extends StatelessWidget {
  const VerifyPanel({super.key, required this.runs, this.projectPath});

  final List<Run> runs;

  /// Findings carry absolute paths; under this root they are shown relative to it.
  final String? projectPath;

  @override
  Widget build(BuildContext context) {
    final rounds = verifySummary(runs);
    return Panel(
      key: const ValueKey('flow-verify'),
      title: 'Verify',
      child: rounds.isEmpty
          ? const Muted('nenhum verify rodou neste ciclo')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final r in rounds) _VerifyRound(r, projectPath: projectPath)],
            ),
    );
  }
}

class _VerifyRound extends StatelessWidget {
  const _VerifyRound(this.round, {required this.projectPath});

  final VerifyRoundSummary round;
  final String? projectPath;

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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Mono(findingLocation(f.file, f.line, projectPath), size: 11),
                        const SizedBox(height: 2),
                        Text(f.message, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                      ],
                    ),
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
