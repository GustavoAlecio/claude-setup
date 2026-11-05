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

class RunsPage extends StatelessWidget {
  const RunsPage({super.key, required this.projectName});

  final String projectName;

  @override
  Widget build(BuildContext context) {
    final repository = RepositoryScope.of(context);
    return BlocProvider(
      // The shell reuses this page across projects (same route pattern); a new project needs a new cubit.
      key: ValueKey(projectName),
      create: (_) => StreamCubit<Project?>(repository.watchProject(projectName)),
      child: BlocBuilder<StreamCubit<Project?>, AsyncSnapshot<Project?>>(
        builder: (context, snapshot) => snapshot.connectionState == ConnectionState.waiting
            ? const SizedBox.shrink()
            : _RunsView(projectName: projectName, runs: snapshot.data?.cycle?.runs ?? const []),
      ),
    );
  }
}

class _RunsView extends StatelessWidget {
  const _RunsView({required this.projectName, required this.runs});

  final String projectName;
  final List<Run> runs;

  @override
  Widget build(BuildContext context) {
    if (runs.isEmpty) return const Center(child: Muted('sem execuções com escada neste ciclo', size: 13));
    final run = runs.first;
    final blocked = run.blockedTask;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _RunHeader(run: run),
        const SizedBox(height: 16),
        if (blocked != null) ...[
          DiagnosisPanel(task: blocked, onExpand: () => context.go('/p/$projectName/runs/${run.id}/${blocked.id}')),
          const SizedBox(height: 16),
        ],
        _LadderTable(project: projectName, run: run),
        const SizedBox(height: 12),
        const _Legend(),
      ],
    );
  }
}

class _RunHeader extends StatelessWidget {
  const _RunHeader({required this.run});

  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final attempts = run.tasks.fold(0, (s, t) => s + t.attempts.length);
    final header = Row(
      children: [
        Text('smart-${run.kind}', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(width: 12),
        VerdictBadge(run.status),
        const SizedBox(width: 12),
        Mono(run.id, color: c.textMuted, size: 11),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Muted('$attempts tentativas · ${formatTokens(run.tokensOut)} tokens out · início ${run.startedAt}'),
          ),
        ),
      ],
    );
    if (run.gates.isEmpty) return header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (final g in run.gates)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Mono(g.gate, color: c.textSecondary, size: 11),
                  const SizedBox(width: 6),
                  VerdictBadge(g.verdict),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _LadderTable extends StatelessWidget {
  const _LadderTable({required this.project, required this.run});

  final String project;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const header = TextStyle(fontSize: 11, fontWeight: FontWeight.w500);
    return Panel(
      title: 'Escada por task',
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: c.elevated,
            child: DefaultTextStyle.merge(
              style: header.copyWith(color: c.textMuted),
              child: const Row(
                children: [
                  SizedBox(width: 40, child: Text('TASK')),
                  SizedBox(width: 44, child: Text('CX')),
                  Expanded(child: Text('TÍTULO')),
                  SizedBox(width: 150, child: Text('ESCADA')),
                  SizedBox(width: 170, child: Text('TIER0 → ATUAL')),
                  SizedBox(width: 70, child: Text('TOKENS')),
                  SizedBox(width: 100, child: Text('STATUS')),
                  SizedBox(width: 20),
                ],
              ),
            ),
          ),
          for (final t in run.tasks) _TaskRow(project: project, runId: run.id, task: t),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.project, required this.runId, required this.task});

  final String project;
  final String runId;
  final TaskRun task;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      hoverColor: c.hover,
      onTap: task.attempts.isEmpty ? null : () => context.go('/p/$project/runs/$runId/${task.id}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            SizedBox(width: 40, child: Mono(task.id, color: c.textPrimary)),
            SizedBox(
              width: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: ComplexityTag(task.complexity, risk: task.risk),
              ),
            ),
            Expanded(
              child: Text(task.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
            SizedBox(
              width: 150,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Ladder(task: task),
              ),
            ),
            SizedBox(
              width: 170,
              child: Row(
                children: [
                  Flexible(child: TierChip(task.tier0)),
                  if (task.tier != task.tier0) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward, size: 12, color: c.textMuted),
                    ),
                    Flexible(child: TierChip(task.tier)),
                  ],
                ],
              ),
            ),
            SizedBox(width: 70, child: Mono(task.attempts.isEmpty ? '—' : formatTokens(task.tokensOut), size: 11)),
            SizedBox(
              width: 100,
              child: Align(alignment: Alignment.centerLeft, child: VerdictBadge(task.status)),
            ),
            SizedBox(
              width: 20,
              child: task.attempts.isEmpty ? null : Icon(Icons.chevron_right, size: 16, color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        for (final t in Tier.values) ...[TierChip(t), const SizedBox(width: 6)],
        const SizedBox(width: 12),
        const Expanded(
          child: Muted(
            'cada coluna é uma tentativa · anel vermelho = reprovou · degrau = escalada com rollback',
            size: 11,
          ),
        ),
        Icon(Icons.bolt, size: 13, color: c.warn),
        const SizedBox(width: 4),
        const Muted('risco alto', size: 11),
      ],
    );
  }
}
