import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/bloc/stream_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/ladder.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/session_launcher.dart';
import '../../data/budget.dart';
import '../../data/flow_aggregates.dart';
import '../../data/flow_repository.dart';
import '../../data/kickoff.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_reducer.dart';
import '../../data/session_models.dart';
import '../launcher/command_palette.dart';
import '../launcher/kickoff_form.dart';
import 'cycle_actions.dart';
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

/// Holds what the cycle column has open: above the split and the drawer, so switching between them keeps it. A new
/// project gets a new state through the provider's key.
class _FlowView extends StatefulWidget {
  const _FlowView({required this.projectName, required this.project, required this.stage});

  final String projectName;
  final Project? project;
  final Stage? stage;

  @override
  State<_FlowView> createState() => _FlowViewState();
}

class _FlowViewState extends State<_FlowView> with SessionLauncher<_FlowView> {
  static const _startKey = 'cycle-start';

  late bool _timelineOpen = widget.stage != null;
  bool _detailsOpen = false;
  // The draft, the create in flight and its error live here so they survive `_FlowMain` being remounted when the
  // width crosses [kFlowSplitWidth].
  final _startText = TextEditingController();
  String? _startPathError;

  @override
  String get logName => 'CycleStart';

  void _start(Project project, String command) {
    final config = context.read<ConfigCubit>().state.data;
    final cwd = project.path;
    if (cwd == null) {
      setState(() => _startPathError = missingProjectPathError(project));
      return;
    }
    unawaited(
      launchSession(
        _startKey,
        project.name,
        command,
        cwd: cwd,
        githubAccount: githubFor(project.org, config).account,
        permissionMode: effectivePermissionMode(null, project.org, config),
      ),
    );
  }

  @override
  void dispose() {
    _startText.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_FlowView old) {
    super.didUpdateWidget(old);
    // Only the arrival of `?stage=` opens the timeline: moving between stages must not reopen one the user closed.
    if (old.stage == null && widget.stage != null) _timelineOpen = true;
  }

  @override
  Widget build(BuildContext context) {
    final projectName = widget.projectName;
    final stage = widget.stage;
    final project = widget.project;
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
        ? FlowSidePanel(
            projectName: projectName,
            project: project,
            report: report,
            session: shown,
            orphanStage: orphanCurrentStage(project?.cycle, stage, hasSession: shown != null),
          )
        : null;
    final c = context.colors;
    // `main` keeps the same ancestors with or without `side`, so its state (e.g. LastCycleLine) survives the toggle.
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth >= kFlowSplitWidth;
        final main = _FlowMain(
          projectName: projectName,
          project: project,
          sessions: sessions,
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
          timelineOpen: _timelineOpen,
          detailsOpen: _detailsOpen,
          onToggleTimeline: () => setState(() => _timelineOpen = !_timelineOpen),
          onToggleDetails: () => setState(() => _detailsOpen = !_detailsOpen),
          startText: _startText,
          startCreating: isCreating(_startKey),
          startError: _startPathError ?? createError(_startKey),
          onStartEdited: () {
            if (_startPathError != null) setState(() => _startPathError = null);
          },
          onStart: _start,
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

/// Left side of the Fluxo: the cycle column, or the box that starts one.
class _FlowMain extends StatelessWidget {
  const _FlowMain({
    required this.projectName,
    required this.project,
    required this.sessions,
    required this.stageSession,
    required this.showOpenLink,
    required this.selected,
    required this.timelineOpen,
    required this.detailsOpen,
    required this.onToggleTimeline,
    required this.onToggleDetails,
    required this.startText,
    required this.startCreating,
    required this.startError,
    required this.onStartEdited,
    required this.onStart,
  });

  final String projectName;
  final Project? project;
  final List<SessionSummary> sessions;

  /// The project's live pipeline session ([runningStageSession]).
  final SessionSummary? stageSession;
  final bool showOpenLink;
  final Stage? selected;
  final bool timelineOpen;
  final bool detailsOpen;
  final VoidCallback onToggleTimeline;
  final VoidCallback onToggleDetails;
  final TextEditingController startText;
  final bool startCreating;
  final String? startError;
  final VoidCallback onStartEdited;
  final void Function(Project project, String command) onStart;

  void _act(BuildContext context, Project project, CycleNow now) {
    if (now.route case final route?) {
      context.go(route);
    } else if (now.kind == CycleNowKind.paused) {
      unawaited(resumeCycle(context, project));
    } else if (now.kind == CycleNowKind.stalled && project.cycle?.stage == Stage.kickoff) {
      unawaited(showKickoffForm(context, project));
    } else {
      unawaited(showCommandPalette(context, ProjectTarget(project), skill: now.skill));
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = this.project;
    final cycle = project?.cycle;
    final stageSession = this.stageSession;
    if (project == null || cycle == null) {
      final banner = stageSession == null ? null : StageBanner(session: stageSession, showOpenLink: showOpenLink);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (banner != null) Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 0), child: banner),
          Expanded(
            child: Center(
              child: stageSession != null && isKickoffSession(stageSession)
                  ? _KickoffRunning(session: stageSession)
                  : _CycleStart(
                      projectName: projectName,
                      project: project,
                      text: startText,
                      creating: startCreating,
                      error: startError,
                      onEdited: onStartEdited,
                      onSubmit: onStart,
                    ),
            ),
          ),
        ],
      );
    }
    final run = cycle.latestRun;
    final report = cycle.report;
    final now = cycleNow(project, sessions);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!cycle.paused) _BudgetBanner(project: project, cycle: cycle),
              CycleSteps(steps: cycleSteps(cycle), open: timelineOpen, onToggle: onToggleTimeline),
              if (timelineOpen) ...[
                const SizedBox(height: 12),
                StageTimeline(
                  report: report,
                  derived: derivedStageStates(cycle),
                  stageMinutes: cycle.stageMinutes,
                  project: project.name,
                  selected: selected,
                  onSelect: (stage) => context.go(
                    Uri(
                      pathSegments: ['', 'p', projectName, 'flow'],
                      queryParameters: {'stage': stage.name},
                    ).toString(),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              CycleNowCard(now: now, onAction: () => _act(context, project, now)),
              CycleTaskList(project: project.name, cycle: cycle),
              PassedGates(project: project.name, stages: passedGates(gateReport(cycle))),
              const SizedBox(height: 20),
              _CycleFooter(project: project, cycle: cycle, detailsOpen: detailsOpen, onToggleDetails: onToggleDetails),
              if (detailsOpen) ...[
                const SizedBox(height: 16),
                _CycleCard(project: project, cycle: cycle),
                const SizedBox(height: 16),
                if (run == null) const _NoRun() else _RunSummary(project: project.name, run: run),
                const SizedBox(height: 16),
                VerifyPanel(runs: cycle.runs, projectPath: project.path),
                const SizedBox(height: 16),
                DecisionsPanel(report: report),
                ReportExtras(report: report),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Card, branch, cost, the cycle's menu and the link that opens the details below.
class _CycleFooter extends StatelessWidget {
  const _CycleFooter({
    required this.project,
    required this.cycle,
    required this.detailsOpen,
    required this.onToggleDetails,
  });

  final Project project;
  final Cycle cycle;
  final bool detailsOpen;
  final VoidCallback onToggleDetails;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      key: const ValueKey('cycle-footer'),
      spacing: 14,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (cycle.tracker case final tracker?) Mono(tracker, color: c.textPrimary),
        if (cycle.branch case final branch?)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              branch,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.textSecondary),
            ),
          ),
        _CycleCostText(key: const ValueKey('flow-cycle-cost'), project: project, cycle: cycle),
        CycleMenu(project: project),
        TextButton(
          key: const ValueKey('cycle-details-toggle'),
          style: TextButton.styleFrom(foregroundColor: c.accent),
          onPressed: onToggleDetails,
          child: Text(detailsOpen ? 'ocultar detalhes' : 'detalhes do ciclo', style: const TextStyle(fontSize: 12)),
        ),
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

/// Without a cycle and without a kickoff running: what the user types here starts the cycle ([startCommand]). The
/// session is created by whoever owns [onSubmit]; this box only shows [creating] and [error].
class _CycleStart extends StatefulWidget {
  const _CycleStart({
    required this.projectName,
    required this.project,
    required this.text,
    required this.creating,
    required this.error,
    required this.onEdited,
    required this.onSubmit,
  });

  /// Of the route; the title falls back to it while the project is unknown.
  final String projectName;
  final Project? project;
  final TextEditingController text;
  final bool creating;
  final String? error;
  final VoidCallback onEdited;
  final void Function(Project project, String command) onSubmit;

  @override
  State<_CycleStart> createState() => _CycleStartState();
}

class _CycleStartState extends State<_CycleStart> {
  static const _counterFrom = 18000;

  TextEditingController get _text => widget.text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final project = widget.project;
    final config = context.watch<ConfigCubit>().state.data;
    final tracker = project == null ? null : orgConfigOf(config, project.org)?.tracker;
    final creating = widget.creating;
    final length = _text.text.length;
    final tooLong = length > kKickoffMaxChars;
    final command = startCommand(_text.text, tracker);
    final submit = project == null || command == null || tooLong || creating
        ? null
        : () => widget.onSubmit(project, command);
    final error = widget.error;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        key: const ValueKey('cycle-start'),
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'O que você quer fazer em ${project?.name ?? widget.projectName}?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: c.textPrimary),
            ),
            const SizedBox(height: 6),
            Muted(
              tracker == null
                  ? 'Descreva com suas palavras. Não precisa estar completo: o que faltar vira pergunta.'
                  : 'Descreva com suas palavras ou cole o número de um card. Não precisa estar completo: o que '
                        'faltar vira pergunta.',
              size: 13,
            ),
            const SizedBox(height: 14),
            CallbackShortcuts(
              bindings: {
                if (submit != null) ...{
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true): submit,
                  const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): submit,
                },
              },
              child: TextField(
                key: const ValueKey('cycle-start-input'),
                controller: _text,
                autofocus: true,
                readOnly: creating,
                minLines: 4,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                onChanged: (_) {
                  widget.onEdited();
                  setState(() {});
                },
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  counterText: length > _counterFrom ? '$length/$kKickoffMaxChars' : null,
                  errorText: tooLong ? 'descrição acima de $kKickoffMaxChars caracteres' : null,
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error,
                  key: const ValueKey('cycle-start-error'),
                  style: TextStyle(fontSize: 12, color: c.fail),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('cycle-start-submit'),
                  style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
                  onPressed: submit,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Começar'),
                      SizedBox(width: 8),
                      Opacity(opacity: 0.7, child: Text('⌘↵', style: TextStyle(fontSize: 12))),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey('cycle-start-more'),
                  style: TextButton.styleFrom(foregroundColor: c.accent),
                  onPressed: project == null || creating ? null : () => showKickoffForm(context, project),
                  child: const Text('mais opções', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Muted(
              'Você é chamado para confirmar o que vai ser entregue, ver como vai ser construído e revisar antes do '
              'PR. Fora isso, só se algo travar ou surgir uma decisão sua.',
            ),
            if (project != null) ...[
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: LastCycleLine(key: ValueKey('last-cycle-${project.name}'), project: project),
              ),
            ],
          ],
        ),
      ),
    );
  }
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
          if (cycle.tracker case final tracker?) row('Card', Mono(tracker, color: c.textPrimary)),
          if (cycle.branch case final branch?) row('Branch', Mono(branch)),
          if (project.stack case final stack?) row('Stack', Mono(stack)),
          if (project.path case final path?) row('Repo', Mono(path)),
          row('Custo', _CycleCostText(project: project, cycle: cycle)),
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

({double cost, double? budget, BudgetState state}) _budgetOf(BuildContext context, Project project, Cycle cycle) {
  final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
  final config = context.watch<ConfigCubit>().state.data;
  final cost = cycleCost(cycle, project.name, sessions);
  final budget = cycleBudgetFor(project.org, config);
  return (cost: cost, budget: budget, state: budgetState(cost, budget));
}

/// The cycle's cost against its budget; only the footer gives it the `flow-cycle-cost` key.
class _CycleCostText extends StatelessWidget {
  const _CycleCostText({super.key, required this.project, required this.cycle});

  final Project project;
  final Cycle cycle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (:cost, :budget, :state) = _budgetOf(context, project, cycle);
    final color = switch (state) {
      BudgetState.over => c.fail,
      BudgetState.near => c.warn,
      BudgetState.ok || BudgetState.none => c.textPrimary,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Mono(budget == null ? usd(cost) : '${usd(cost)} de ${usd(budget)}', color: color),
        if (budget == null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'sem orçamento (Configurações)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: c.textMuted),
            ),
          ),
        ],
      ],
    );
  }
}

/// Shown from 80% of the cycle's budget; past it, in red. Only sessions started since the cycle began count.
class _BudgetBanner extends StatelessWidget {
  const _BudgetBanner({required this.project, required this.cycle});

  final Project project;
  final Cycle cycle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (:cost, :budget, :state) = _budgetOf(context, project, cycle);
    if (budget == null || state == BudgetState.ok || state == BudgetState.none) return const SizedBox.shrink();
    final over = state == BudgetState.over;
    final color = over ? c.fail : c.warn;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        key: const ValueKey('flow-budget-banner'),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.savings_outlined, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                over
                    ? 'O ciclo passou do orçamento: ${usd(cost)} de ${usd(budget)}.'
                    : 'O ciclo já usou ${(cost / budget * 100).round()}% do orçamento: ${usd(cost)} de ${usd(budget)}.',
                style: TextStyle(fontSize: 12.5, color: c.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
