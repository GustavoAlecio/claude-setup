import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/bloc/stream_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/ladder.dart';
import '../../core/widgets/primitives.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import 'cycle_tasks.dart';
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
            : _RunsBody(projectName: projectName, cycle: snapshot.data?.cycle),
      ),
    );
  }
}

class _RunsBody extends StatelessWidget {
  const _RunsBody({required this.projectName, required this.cycle});

  final String projectName;
  final Cycle? cycle;

  @override
  Widget build(BuildContext context) {
    final cycle = this.cycle;
    if (cycle == null || cycle.runs.isEmpty) {
      return Center(
        child: Muted(
          cycle == null
              ? 'As execuções aparecem a partir do /implement.'
              : 'As execuções aparecem a partir do /implement.\nEtapa atual: ${cycle.stage.label}',
          size: 13,
        ),
      );
    }
    return _RunsView(projectName: projectName, cycle: cycle);
  }
}

enum _Mode { byRun, cycle }

class _RunsView extends StatefulWidget {
  const _RunsView({required this.projectName, required this.cycle});

  final String projectName;
  final Cycle cycle;

  @override
  State<_RunsView> createState() => _RunsViewState();
}

class _RunsViewState extends State<_RunsView> {
  _Mode _mode = _Mode.byRun;
  final _collapsed = <String>{};

  void _toggle(String runId) =>
      setState(() => _collapsed.contains(runId) ? _collapsed.remove(runId) : _collapsed.add(runId));

  @override
  Widget build(BuildContext context) {
    final project = widget.projectName;
    final consolidated = consolidateCycle(widget.cycle);
    final items = switch (_mode) {
      _Mode.byRun => _byRunItems(context, consolidated),
      _Mode.cycle => [
        ..._tableItems(context, [
          for (final t in consolidated) _TaskRow(project: project, runId: t.lastRunId, task: t.task),
        ]),
      ],
    };
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<_Mode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _Mode.byRun, label: Text('Por run')),
                ButtonSegment(value: _Mode.cycle, label: Text('Ciclo')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(child: ListView(children: items)),
          const SizedBox(height: 12),
          const _Legend(),
        ],
      ),
    );
  }

  List<Widget> _byRunItems(BuildContext context, List<CycleTask> consolidated) {
    final project = widget.projectName;
    final finalStatus = {for (final t in consolidated) t.task.id: t.task.status};
    final items = <Widget>[];
    for (final run in widget.cycle.runs.reversed) {
      final expanded = !_collapsed.contains(run.id);
      final blocked = run.blockedTask;
      if (blocked != null && finalStatus[blocked.id] == Verdict.blocked) {
        items
          ..add(DiagnosisPanel(task: blocked, onExpand: () => context.go('/p/$project/runs/${run.id}/${blocked.id}')))
          ..add(const SizedBox(height: 16));
      }
      items.add(
        _Band(
          first: true,
          last: !expanded,
          child: InkWell(
            onTap: () => _toggle(run.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                      color: context.colors.textMuted,
                    ),
                  ),
                  Expanded(child: _RunHeader(run: run)),
                ],
              ),
            ),
          ),
        ),
      );
      if (expanded) {
        items.addAll(
          _tableItems(context, [
            for (final t in run.tasks) _TaskRow(project: project, runId: run.id, task: t),
          ], attached: true),
        );
      }
      items.add(const SizedBox(height: 16));
    }
    return items;
  }

  List<Widget> _tableItems(BuildContext context, List<Widget> rows, {bool attached = false}) {
    final c = context.colors;
    const header = TextStyle(fontSize: 11, fontWeight: FontWeight.w500);
    return [
      _Band(
        first: !attached,
        child: Container(
          height: 48,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
          decoration: BoxDecoration(
            border: Border(
              top: attached ? BorderSide(color: c.border) : BorderSide.none,
              bottom: BorderSide(color: c.border),
            ),
          ),
          child: Text('Escada por task', style: Theme.of(context).textTheme.titleMedium),
        ),
      ),
      _Band(
        child: Container(
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
      ),
      for (var i = 0; i < rows.length; i++) _Band(last: i == rows.length - 1, child: rows[i]),
    ];
  }
}

/// A slice of one card whose rows are separate list items, so a long run stays lazily built.
class _Band extends StatelessWidget {
  const _Band({required this.child, this.first = false, this.last = false});

  final Widget child;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const radius = Radius.circular(10);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.vertical(top: first ? radius : Radius.zero, bottom: last ? radius : Radius.zero),
        border: Border(
          left: BorderSide(color: c.border),
          right: BorderSide(color: c.border),
          top: first ? BorderSide(color: c.border) : BorderSide.none,
          bottom: last ? BorderSide(color: c.border) : BorderSide.none,
        ),
      ),
      child: child,
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

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.project, required this.runId, required this.task});

  final String project;
  final String? runId;
  final TaskRun task;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      hoverColor: c.hover,
      onTap: task.attempts.isEmpty || runId == null ? null : () => context.go('/p/$project/runs/$runId/${task.id}'),
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
