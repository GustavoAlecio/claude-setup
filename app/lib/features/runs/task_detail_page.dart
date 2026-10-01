import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/bloc/stream_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/ladder.dart';
import '../../core/widgets/primitives.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import 'diagnosis_panel.dart';

class TaskDetailPage extends StatelessWidget {
  const TaskDetailPage({super.key, required this.projectName, required this.runId, required this.taskId});

  final String projectName;
  final String runId;
  final String taskId;

  @override
  Widget build(BuildContext context) {
    final repository = RepositoryScope.of(context);
    return BlocProvider(
      // The shell reuses this page across runs (same route pattern); a new run needs a new cubit.
      key: ValueKey('$projectName/$runId'),
      create: (_) => StreamCubit<Run?>(repository.watchRun(projectName, runId)),
      child: BlocBuilder<StreamCubit<Run?>, AsyncSnapshot<Run?>>(
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const SizedBox.shrink();
          final task = snapshot.data?.tasks.where((t) => t.id == taskId).firstOrNull;
          if (task == null) return const Center(child: Muted('Task não encontrada.'));
          return _TaskView(projectName: projectName, task: task);
        },
      ),
    );
  }
}

class _TaskView extends StatelessWidget {
  const _TaskView({required this.projectName, required this.task});

  final String projectName;
  final TaskRun task;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final repeated = <String, int>{};
    final firstSeen = <String, Attempt>{};
    for (final a in task.attempts) {
      for (final f in a.blocking.map((f) => f.fingerprint).toSet()) {
        repeated[f] = (repeated[f] ?? 0) + 1;
        firstSeen.putIfAbsent(f, () => a);
      }
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => context.go('/p/$projectName/runs'),
              icon: Icon(Icons.arrow_back, size: 18, color: c.textSecondary),
            ),
            Mono(task.id, color: c.textMuted, size: 14),
            const SizedBox(width: 10),
            Expanded(child: Text(task.title, style: Theme.of(context).textTheme.titleLarge)),
            ComplexityTag(task.complexity, risk: task.risk),
            const SizedBox(width: 12),
            VerdictBadge(task.status),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 48),
          child: Row(
            children: [
              for (final f in task.files) Mono(f, size: 11),
              const Spacer(),
              Ladder(task: task, laneHeight: 9),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (task.status == Verdict.blocked) ...[DiagnosisPanel(task: task), const SizedBox(height: 20)],
        Text('Tentativas', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final a in task.attempts) ...[
                _AttemptCard(attempt: a, repeated: repeated, firstSeen: firstSeen),
                if (a.escalatedTo != null) _EscalationArrow(to: a.escalatedTo!),
                if (a.escalatedTo == null && a != task.attempts.last) const _RetryArrow(),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AttemptCard extends StatelessWidget {
  const _AttemptCard({required this.attempt, required this.repeated, required this.firstSeen});

  final Attempt attempt;
  final Map<String, int> repeated;
  final Map<String, Attempt> firstSeen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 316,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Mono(attempt.label, color: c.textPrimary, size: 13),
                const SizedBox(width: 10),
                TierChip(attempt.tier),
                const Spacer(),
                Mono(formatTokens(attempt.tokensOut), size: 11),
                const SizedBox(width: 10),
                VerdictBadge(attempt.verdict),
              ],
            ),
          ),
          if (attempt.summary != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Text(
                attempt.summary!,
                style: TextStyle(fontSize: 12, color: c.textSecondary, fontStyle: FontStyle.italic),
              ),
            ),
          for (final g in attempt.gates)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Mono(g.gate.toUpperCase(), color: c.textPrimary),
                      const SizedBox(width: 8),
                      VerdictBadge(g.verdict),
                    ],
                  ),
                  for (final f in g.findings)
                    if ((firstSeen[f.fingerprint]?.ordinal ?? attempt.ordinal) < attempt.ordinal)
                      _RepeatedFindingLine(
                        finding: f,
                        firstLabel: firstSeen[f.fingerprint]!.label,
                        count: repeated[f.fingerprint]!,
                      )
                    else
                      _FindingTile(finding: f, repeatCount: repeated[f.fingerprint] ?? 0),
                ],
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.finding, required this.repeatCount});

  final Finding finding;
  final int repeatCount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hot = repeatCount > 1;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: hot ? c.fail.withValues(alpha: 0.07) : c.elevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: hot ? c.fail.withValues(alpha: 0.45) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(label: finding.severity, color: finding.severity == 'critical' ? c.fail : c.warn, dot: false),
              const SizedBox(width: 6),
              if (hot) Pill(label: 'repetido ×$repeatCount', color: c.fail, dot: false),
            ],
          ),
          const SizedBox(height: 6),
          Text(finding.message, style: TextStyle(fontSize: 12, height: 1.4, color: c.textPrimary)),
          const SizedBox(height: 6),
          Mono('${finding.file}${finding.line == null ? '' : ':${finding.line}'}', size: 10.5),
          Mono(finding.ruleRef, size: 10.5, color: c.accent),
        ],
      ),
    );
  }
}

class _EscalationArrow extends StatelessWidget {
  const _EscalationArrow({required this.to});

  final Tier to;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: 96,
      child: Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Column(
          children: [
            Icon(Icons.trending_up, color: c.tier(to), size: 20),
            const SizedBox(height: 4),
            Mono('rollback', size: 10, color: c.textMuted),
            Mono('→ ${to.name}', size: 11, color: c.tier(to)),
          ],
        ),
      ),
    );
  }
}

class _RetryArrow extends StatelessWidget {
  const _RetryArrow();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: 72,
      child: Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Column(
          children: [
            Icon(Icons.redo, color: c.textMuted, size: 18),
            const SizedBox(height: 4),
            Mono('fix in place', size: 10, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

class _RepeatedFindingLine extends StatelessWidget {
  const _RepeatedFindingLine({required this.finding, required this.firstLabel, required this.count});

  final Finding finding;
  final String firstLabel;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: finding.message,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.fail.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.repeat, size: 14, color: c.fail),
                const SizedBox(width: 8),
                Flexible(
                  child: Text('igual à $firstLabel', style: TextStyle(fontSize: 12, color: c.textPrimary)),
                ),
                const SizedBox(width: 8),
                Pill(label: 'repetido ×$count', color: c.fail, dot: false),
              ],
            ),
            const SizedBox(height: 4),
            Mono(finding.ruleRef, size: 10.5, color: c.accent),
          ],
        ),
      ),
    );
  }
}
