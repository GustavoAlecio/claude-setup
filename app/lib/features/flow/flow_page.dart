import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/sessions_cubit.dart';
import '../../core/bloc/stream_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/ladder.dart';
import '../../core/widgets/primitives.dart';
import '../../data/flow_aggregates.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_reducer.dart';
import '../../data/session_models.dart';
import '../launcher/kickoff_form.dart';
import 'flow_panels.dart';
import 'last_cycle_line.dart';
import 'report_extras.dart';
import 'flow_side_panel.dart';
import 'stage_timeline.dart';

class FlowPage extends StatelessWidget {
  const FlowPage({super.key, required this.projectName, this.stage});

  final String projectName;

  /// `?stage=`: the stage selected in the timeline; its session is the one the side panel shows.
  final Stage? stage;

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
            : _FlowView(projectName: projectName, project: snapshot.data, stage: stage),
      ),
    );
  }
}

class _FlowView extends StatelessWidget {
  const _FlowView({required this.projectName, required this.project, required this.stage});

  final String projectName;
  final Project? project;
  final Stage? stage;

  @override
  Widget build(BuildContext context) {
    final project = this.project;
    final report = project?.cycle?.report;
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final stageSession = project == null ? null : runningStageSession(sessions, project);
    final shownId = flowPanelSessionId(stage: stage, runningStage: stageSession, report: report);
    final shown = sessions.where((s) => s.id == shownId).firstOrNull;
    final pending = pendingByProject(sessions)[projectName] ?? 0;
    final side =
        showsFlowSidePanel(
          hasCycle: project?.cycle != null,
          hasShownSession: shown != null,
          stage: stage,
          pending: pending,
        )
        ? FlowSidePanel(projectName: projectName, project: project, report: report, session: shown)
        : null;
    final c = context.colors;
    // `main` keeps the same ancestors with or without `side`, so its state (e.g. LastCycleLine) survives the toggle.
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth >= kFlowSplitWidth;
        final main = _FlowMain(
          projectName: projectName,
          project: project,
          stageSession: stageSession,
          showOpenLink:
              stageSession == null ||
              stageBannerShowsOpenLink(
                split: split,
                hasSidePanel: side != null,
                shownSessionId: shown?.id,
                stageSessionId: stageSession.id,
              ),
          selected: stage,
        );
        return split
            ? _split(c, main, side)
            : _withDrawer(c, main, side, pending + endedStageSessions(report, sessions).length);
      },
    );
  }

  Widget _split(AppColors c, Widget main, Widget? side) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(key: const ValueKey('flow-main'), child: main),
      if (side != null)
        Container(
          width: kFlowSidePanelWidth,
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.border)),
          ),
          child: side,
        ),
    ],
  );

  Widget _withDrawer(AppColors c, Widget main, Widget? side, int pending) => Scaffold(
    backgroundColor: Colors.transparent,
    endDrawer: side == null
        ? null
        : Drawer(
            width: kFlowSidePanelWidth,
            backgroundColor: c.canvas,
            shape: const RoundedRectangleBorder(),
            child: side,
          ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (side != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: Builder(
                builder: (context) => OutlinedButton.icon(
                  key: const ValueKey('flow-drawer-toggle'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textPrimary,
                    side: BorderSide(color: c.borderStrong),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                  icon: const Icon(Icons.forum_outlined, size: 15),
                  label: Text(
                    pending > 0 ? 'Sessão da etapa · $pending aguardando' : 'Sessão da etapa',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        Expanded(key: const ValueKey('flow-main'), child: main),
      ],
    ),
  );
}

/// Left side of the Fluxo: the stage timeline and the cycle panels, or the empty state without a cycle.
class _FlowMain extends StatelessWidget {
  const _FlowMain({
    required this.projectName,
    required this.project,
    required this.stageSession,
    required this.showOpenLink,
    required this.selected,
  });

  final String projectName;
  final Project? project;

  /// The project's live pipeline session ([runningStageSession]).
  final SessionSummary? stageSession;
  final bool showOpenLink;
  final Stage? selected;

  @override
  Widget build(BuildContext context) {
    final project = this.project;
    final cycle = project?.cycle;
    final stageSession = this.stageSession;
    final banner = stageSession == null ? null : StageBanner(session: stageSession, showOpenLink: showOpenLink);
    if (project == null || cycle == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (banner != null) Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 0), child: banner),
          Expanded(
            child: Center(
              child: stageSession != null && isKickoffSession(stageSession)
                  ? _KickoffRunning(session: stageSession)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Muted('Nenhum ciclo ativo. Comece com /kickoff ou /specify.', size: 13),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: context.colors.accent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: project == null ? null : () => showKickoffForm(context, project),
                          icon: const Icon(Icons.rocket_launch_outlined, size: 15),
                          label: const Text('Novo kickoff'),
                        ),
                        if (project != null) ...[
                          const SizedBox(height: 20),
                          LastCycleLine(key: ValueKey('last-cycle-${project.name}'), project: project),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      );
    }
    final run = cycle.latestRun;
    final report = cycle.report;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (banner != null) ...[banner, const SizedBox(height: 16)],
        StageTimeline(
          report: report,
          derived: derivedStageStates(cycle),
          stageMinutes: cycle.stageMinutes,
          project: project.name,
          selected: selected,
          onSelect: (stage) => context.go(
            Uri(pathSegments: ['', 'p', projectName, 'flow'], queryParameters: {'stage': stage.name}).toString(),
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final cycleCard = _CycleCard(project: project, cycle: cycle);
            final runCard = run == null ? const _NoRun() : _RunSummary(project: project.name, run: run);
            // Next to the side panel the left column is too narrow for both cards side by side.
            if (constraints.maxWidth < 960) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [cycleCard, const SizedBox(height: 16), runCard],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: cycleCard),
                const SizedBox(width: 16),
                Expanded(flex: 3, child: runCard),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        TasksPanel(cycle: cycle),
        const SizedBox(height: 16),
        VerifyPanel(runs: cycle.runs),
        const SizedBox(height: 16),
        DecisionsPanel(report: report),
        ReportExtras(report: report),
      ],
    );
  }
}

/// Without a cycle a live pipeline session is a kickoff whose `current.json` has no identity yet.
class _KickoffRunning extends StatelessWidget {
  const _KickoffRunning({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('flow-kickoff-running'),
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Kickoff em andamento', style: TextStyle(fontSize: 14, color: context.colors.textPrimary)),
      const SizedBox(height: 6),
      Muted(session.title, size: 12.5),
    ],
  );
}

class _CycleCard extends StatelessWidget {
  const _CycleCard({required this.project, required this.cycle});

  final Project project;
  final Cycle cycle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final run = cycle.latestRun;
    Widget row(String k, Widget v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 110, child: Muted(k)),
          Expanded(child: v),
        ],
      ),
    );
    return Panel(
      title: 'Ciclo',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(cycle.feature ?? project.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (cycle.tracker case final tracker?) row('Card', Mono(tracker, color: c.textPrimary)),
          if (cycle.branch case final branch?) row('Branch', Mono(branch)),
          if (project.stack case final stack?) row('Stack', Mono(stack)),
          if (project.path case final path?) row('Repo', Mono(path)),
          row(
            'Piloto',
            Align(
              alignment: Alignment.centerLeft,
              child: Pill(label: cycle.autoMode ? 'on' : 'off', color: cycle.autoMode ? c.accent : c.idle, dot: false),
            ),
          ),
          if (run != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1, color: c.border),
            ),
            Row(
              children: [
                _Stat(
                  label: 'tasks',
                  value: '${run.tasks.where((t) => t.status == Verdict.pass).length}/${run.tasks.length}',
                ),
                _Stat(label: 'escaladas', value: '${run.tasks.where((t) => t.escalations > 0).length}'),
                _Stat(label: 'tokens out', value: formatTokens(run.tokensOut)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _NoRun extends StatelessWidget {
  const _NoRun();

  @override
  Widget build(BuildContext context) =>
      const Panel(title: 'Execução', child: Muted('Nenhum workflow rodou ainda neste ciclo.'));
}

class _RunSummary extends StatelessWidget {
  const _RunSummary({required this.project, required this.run});

  final String project;
  final Run run;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final blocked = run.blockedTask;
    return Panel(
      title: 'Última execução',
      trailing: TextButton(
        onPressed: () => context.go('/p/$project/runs'),
        child: Text('abrir', style: TextStyle(color: c.accent, fontSize: 12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Mono(run.id, color: c.textPrimary),
              const SizedBox(width: 10),
              VerdictBadge(run.status),
              const Spacer(),
              Muted('início ${run.startedAt}'),
            ],
          ),
          if (blocked != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.fail.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.fail.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.report_outlined, color: c.fail, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${blocked.id} bloqueou: mesma falha em ${blocked.attempts.map((a) => a.tier).toSet().length} tiers. '
                      'Diagnóstico pronto — decisão sua.',
                      style: TextStyle(fontSize: 12.5, color: c.textPrimary),
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go('/p/$project/runs/${run.id}/${blocked.id}'),
                    child: Text('ver diagnóstico', style: TextStyle(color: c.fail, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          for (final t in run.tasks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(width: 28, child: Mono(t.id, color: c.textMuted, size: 11)),
                  Expanded(
                    child: Text(t.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                  ),
                  ComplexityTag(t.complexity, risk: t.risk),
                  const SizedBox(width: 16),
                  Ladder(task: t),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        Muted(label, size: 11),
      ],
    ),
  );
}
