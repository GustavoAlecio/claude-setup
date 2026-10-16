import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/org_switch.dart';
import '../../app/engine_cubit.dart';
import '../../app/inbox_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/auto_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_aggregates.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_models.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';
import '../../engine/engine_supervisor.dart';
import '../settings/add_project.dart';
import '../launcher/command_palette.dart';
import '../launcher/kickoff_form.dart';
import 'shell_scope.dart';

enum AppTab {
  flow('Fluxo'),
  runs('Execuções'),
  sessions('Sessões'),
  artifacts('Artefatos'),
  reviews('Reviews'),
  prs('PRs'),
  inbox('Para revisar'),
  metrics('Métricas'),
  adrs('ADRs'),

  /// Org scope only: every project of the org at once.
  queue('Minha fila');

  const AppTab(this.label);
  final String label;

  static AppTab parse(String? s) => AppTab.values.where((t) => t.name == s).firstOrNull ?? AppTab.flow;
}

class ShellPage extends StatefulWidget {
  const ShellPage({super.key, required this.scope, required this.tab, required this.child});

  final ShellScope scope;
  final AppTab tab;
  final Widget child;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  /// Org whose `lastOrg` write is in flight; keeps rebuilds before the config re-emits from writing again.
  String? _syncing;

  /// Org whose write failed and the config it was attempted against; retried only after the config
  /// re-emits, so a persistently failing write does not repeat on every rebuild.
  (String, DashboardConfig)? _failed;

  /// The route decides the org; `lastOrg` only follows. [org] is `null` until the route org is known (a
  /// loaded route project, or an `/o/` org present in the config), so loading or unknown routes never write.
  void _syncLastOrg(String? org, DashboardConfig? config) {
    if (config == null || org == null) return;
    if (org == config.lastOrg) {
      _syncing = null;
      _failed = null;
      return;
    }
    if (_syncing == org) return;
    if (_failed case (final failedOrg, final failedConfig) when failedOrg == org && identical(failedConfig, config)) {
      return;
    }
    _syncing = org;
    final repository = RepositoryScope.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await saveLastOrg(repository, org, messenger: messenger)) return;
      _failed = (org, config);
      if (_syncing == org) _syncing = null;
    });
  }

  List<Widget> _projectHeader(Project project, Project? routeProject, Map<String, int> pending) => [
    _TopBar(project: project, paletteProject: routeProject, pending: project.hidden ? 0 : pending[project.name] ?? 0),
    _Tabs(scope: widget.scope, active: widget.tab),
    if (project.hidden) _HiddenBanner(project: project.name),
    if (routeProject == null) _UnknownProjectBanner(name: project.name),
  ];

  @override
  Widget build(BuildContext context) {
    final snapshot = context.watch<ProjectsCubit>().state;
    final config = context.watch<ConfigCubit>().state.data;
    final projects = snapshot.data ?? const <Project>[];
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final scope = widget.scope;
    final routeProject = switch (scope) {
      ShellProjectScope(:final name) => projects.where((p) => p.name == name).firstOrNull,
      ShellOrgScope() => null,
    };
    final org = switch (scope) {
      ShellProjectScope(:final name) => currentOrg(name, projects, config),
      ShellOrgScope(:final org) => org,
    };
    final orgConfig = orgConfigOf(config, org);
    _syncLastOrg(switch (scope) {
      ShellProjectScope() => snapshot.hasData ? routeProject?.org : null,
      ShellOrgScope() => orgConfig?.name,
    }, config);
    final activities = orgActivities(sessions, projects, config, org);
    final activitiesPending = activities.fold(0, (sum, s) => sum + pendingOf(s));
    final pending = withDecisions(pendingByProject(sessions), projects);
    final location = switch (scope) {
      ShellProjectScope(:final name) => Uri(pathSegments: ['', 'p', name]).toString(),
      ShellOrgScope(:final org) => Uri(pathSegments: ['', 'o', org]).toString(),
    };
    final targetOrg = config == null ? null : paletteOrg(location, config, projects, sessions: sessions);
    final orgTarget = targetOrg == null ? null : OrgTarget.of(orgConfigOf(config, targetOrg));
    final VoidCallback? newActivity = orgTarget == null ? null : () => showCommandPalette(context, orgTarget);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): switch (scope) {
          ShellProjectScope() => () => showCommandPalette(context, ProjectTarget(routeProject)),
          ShellOrgScope() => () => newActivity?.call(),
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(
                org: org,
                orgConfig: orgConfig,
                orgs: switchableOrgs(config, projects, sessions),
                projects: projects,
                sessions: sessions,
                activityCount: activities.length,
                activityPending: activitiesPending,
                onNewActivity: newActivity,
                config: config,
                pending: pending,
                scope: scope,
                tab: widget.tab,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...switch (scope) {
                      ShellProjectScope(:final name) => _projectHeader(
                        routeProject ?? Project(name: name),
                        routeProject,
                        pending,
                      ),
                      ShellOrgScope(:final org) => [
                        _OrgTopBar(
                          org: org,
                          pending: activitiesPending,
                          known: orgConfig != null,
                          onNewActivity: newActivity,
                        ),
                        _Tabs(scope: scope, active: widget.tab),
                      ],
                    },
                    Expanded(child: widget.child),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.org,
    required this.orgConfig,
    required this.orgs,
    required this.projects,
    required this.sessions,
    required this.activityCount,
    required this.activityPending,
    required this.onNewActivity,
    required this.config,
    required this.pending,
    required this.scope,
    required this.tab,
  });

  final String org;

  /// `null` for [kNoOrg] and for an `/o/` org missing from the config.
  final OrgConfig? orgConfig;
  final List<String> orgs;
  final List<Project> projects;
  final List<SessionSummary> sessions;

  /// The org's own sessions, per [orgActivities], and how many of them wait for the user.
  final int activityCount;
  final int activityPending;

  /// `null` when the org has no roots (or is Sem org).
  final VoidCallback? onNewActivity;
  final DashboardConfig? config;

  /// Per project, for the tiles.
  final Map<String, int> pending;
  final ShellScope scope;
  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final visible = projectsInOrg(projects, org);
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(right: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.fromLTRB(10, kTitleBarInset, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _OrgHeader(
            org: org,
            orgs: orgs,
            projects: projects,
            sessions: sessions,
            config: config,
            onNewActivity: onNewActivity,
          ),
          const SizedBox(height: 12),
          if (org != kNoOrg) ...[
            _NavTile(
              key: const ValueKey('sidebar-queue'),
              icon: Icons.inbox_outlined,
              label: 'Minha fila',
              location: orgQueueLocation(org),
              selected: scope is ShellOrgScope && tab == AppTab.queue,
              pending: pendingInOrg(sessions, projects, config, org) + decisionsInOrg(projects, org),
            ),
            const SizedBox(height: 4),
            _NavTile(
              key: const ValueKey('sidebar-inbox'),
              icon: Icons.rate_review_outlined,
              label: 'Para revisar',
              location: orgInboxLocation(org),
              selected: scope is ShellOrgScope && tab == AppTab.inbox,
              pending: context.select<InboxCubit, int>((c) => c.state.badge),
              pendingLabel: 'PRs esperando a sua revisão',
              badgeKey: const ValueKey('inbox-badge'),
            ),
            const SizedBox(height: 4),
          ],
          if (org != kNoOrg || activityCount > 0) ...[
            _OrgActivityTile(
              org: org,
              count: activityCount,
              pending: activityPending,
              enabled: orgConfig?.roots.isNotEmpty ?? activityCount > 0,
              selected: scope is ShellOrgScope && tab == AppTab.sessions,
            ),
            const SizedBox(height: 12),
          ],
          const Padding(padding: EdgeInsets.fromLTRB(8, 0, 8, 8), child: Muted('PROJETOS', size: 10)),
          Expanded(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Muted('nenhum projeto em $org ainda', size: 11),
                        const SizedBox(height: 4),
                        if (config case final config? when org != kNoOrg)
                          TextButton.icon(
                            key: const ValueKey('sidebar-add-project'),
                            style: TextButton.styleFrom(
                              foregroundColor: c.accent,
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => addProjectToOrg(context, org, config),
                            icon: const Icon(Icons.add, size: 14),
                            label: const Text('Adicionar projeto', style: TextStyle(fontSize: 12)),
                          ),
                      ],
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final p in visible)
                        _ProjectTile(
                          project: p,
                          pending: pending[p.name] ?? 0,
                          running: sessions
                              .where((s) => !s.isOrgSession && s.project == p.name && s.status == SessionStatus.running)
                              .length,
                          selected: scope == ShellProjectScope(p.name),
                          tab: tab,
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          const _AutoModeIndicator(key: ValueKey('auto-mode')),
          const SizedBox(height: 8),
          const _EngineFooter(key: ValueKey('engine-footer')),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  key: const ValueKey('sidebar-settings'),
                  style: TextButton.styleFrom(
                    foregroundColor: c.textSecondary,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 30),
                  ),
                  onPressed: () => context.go('/settings'),
                  icon: const Icon(Icons.settings_outlined, size: 15),
                  label: const Text('Configurações', style: TextStyle(fontSize: 12)),
                ),
              ),
              _FooterIcon(
                key: const ValueKey('sidebar-about'),
                icon: Icons.help_outline,
                tooltip: 'Como funciona (⌘I)',
                onPressed: () => context.go('/about'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OrgHeader extends StatelessWidget {
  const _OrgHeader({
    required this.org,
    required this.orgs,
    required this.projects,
    required this.sessions,
    required this.config,
    required this.onNewActivity,
  });

  final String org;
  final List<String> orgs;
  final List<Project> projects;
  final List<SessionSummary> sessions;
  final DashboardConfig? config;
  final VoidCallback? onNewActivity;

  static const _newActivity = '\u0000new-activity';
  static const _settings = '\u0000settings';
  static const _about = '\u0000about';

  void _onSelected(BuildContext context, String value) {
    if (value == _newActivity) {
      onNewActivity?.call();
      return;
    }
    if (value == _settings) {
      context.go('/settings');
      return;
    }
    if (value == _about) {
      context.go('/about');
      return;
    }
    switchOrg(
      repository: RepositoryScope.of(context),
      router: GoRouter.of(context),
      projects: projects,
      config: config,
      org: value,
      messenger: ScaffoldMessenger.maybeOf(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = pendingInOrg(sessions, projects, config, org) + decisionsInOrg(projects, org);
    return PopupMenuButton<String>(
      tooltip: 'Trocar org',
      position: PopupMenuPosition.under,
      color: c.elevated,
      onSelected: (value) => _onSelected(context, value),
      itemBuilder: (_) => [
        for (final (i, name) in orgs.indexed)
          PopupMenuItem(
            value: name,
            height: 36,
            child: Row(
              children: [
                SizedBox(width: 16, child: name == org ? Icon(Icons.check, size: 14, color: c.accent) : null),
                const SizedBox(width: 8),
                Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
                if (pendingInOrg(sessions, projects, config, name) + decisionsInOrg(projects, name) case final n
                    when n > 0) ...[
                  _CountBadge(n),
                  const SizedBox(width: 8),
                ],
                if (i < 9) Mono('⌘${i + 1}', color: c.textMuted, size: 11),
              ],
            ),
          ),
        const PopupMenuDivider(),
        if (org != kNoOrg)
          PopupMenuItem(
            value: _newActivity,
            enabled: onNewActivity != null,
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 24),
                const Expanded(child: Text('Nova atividade na org', style: TextStyle(fontSize: 13))),
                Mono('⌘⇧K', color: c.textMuted, size: 11),
              ],
            ),
          ),
        PopupMenuItem(
          value: _settings,
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 24),
              const Expanded(child: Text('Configurações', style: TextStyle(fontSize: 13))),
              Mono('⌘,', color: c.textMuted, size: 11),
            ],
          ),
        ),
        PopupMenuItem(
          value: _about,
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 24),
              const Expanded(child: Text('Como funciona', style: TextStyle(fontSize: 13))),
              Mono('⌘I', color: c.textMuted, size: 11),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                org,
                key: const ValueKey('current-org'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            if (total > 0) ...[_CountBadge(total, key: const ValueKey('org-pending')), const SizedBox(width: 6)],
            Icon(Icons.unfold_more, size: 16, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.warn, borderRadius: BorderRadius.circular(9)),
      child: Text(
        '$count',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.canvas),
      ),
    );
  }
}

class _HiddenBanner extends StatelessWidget {
  const _HiddenBanner({required this.project});

  final String project;

  Future<void> _unhide(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await RepositoryScope.of(context).updateConfig(unhideProject(project));
    } on ConfigWriteException catch (e, st) {
      log('cannot unhide $project', name: 'ShellPage', error: e, stackTrace: st);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: c.elevated,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.visibility_off_outlined, size: 14, color: c.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Projeto oculto: não aparece na barra lateral nem conta nos avisos.',
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.accent),
            onPressed: () => _unhide(context),
            child: const Text('Reexibir', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.project,
    required this.pending,
    required this.running,
    required this.selected,
    required this.tab,
  });

  final Project project;
  final int pending;

  /// Sessions of the project whose agent is working right now.
  final int running;
  final bool selected;
  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cycle = project.cycle;
    final blocked = cycle?.latestRun?.status == Verdict.blocked;
    final dot = cycle == null ? c.idle : (blocked ? c.fail : c.running);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? c.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: c.hover,
          onTap: () => context.go('/p/${project.name}/${tab.name}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                Tooltip(
                  message: cycle == null ? 'sem ciclo' : (blocked ? 'ciclo parado' : 'ciclo em andamento'),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(project.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      Muted(
                        cycle == null ? 'sem ciclo ativo' : '${cycle.stage.label} · ${cycle.feature ?? project.name}',
                        size: 11,
                      ),
                    ],
                  ),
                ),
                if (running > 0) ...[
                  Tooltip(
                    message: running == 1 ? '1 agente rodando' : '$running agentes rodando',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_circle_outline, size: 12, color: c.running),
                        if (running > 1) ...[const SizedBox(width: 3), Mono('$running', color: c.running, size: 10)],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                if (pending > 0) Tooltip(message: '$pending aguardando você', child: _CountBadge(pending)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OrgActivityTile extends StatelessWidget {
  const _OrgActivityTile({
    required this.org,
    required this.count,
    required this.pending,
    required this.enabled,
    required this.selected,
  });

  final String org;
  final int count;
  final int pending;

  /// An org without roots has nowhere to run an activity; Sem org only lists the orphans it still holds.
  final bool enabled;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tile = Material(
      key: const ValueKey('org-activity'),
      color: selected ? c.hover : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        hoverColor: c.hover,
        onTap: enabled ? () => context.go(orgSessionsLocation(org)) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              Icon(Icons.hub_outlined, size: 14, color: enabled ? c.textSecondary : c.textMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Atividades da org',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: enabled ? null : c.textMuted),
                ),
              ),
              Mono('$count', color: c.textMuted, size: 11),
              if (pending > 0) ...[
                const SizedBox(width: 6),
                Tooltip(message: '$pending aguardando você', child: _CountBadge(pending)),
              ],
            ],
          ),
        ),
      ),
    );
    return enabled ? tile : Tooltip(message: 'org sem pastas', child: tile);
  }
}

/// The global Smart Flow autopilot (`auto_mode.flag`, the same one `/auto` toggles). Turning it on asks first:
/// stages then advance without approval, except at the required gates.
class _AutoModeIndicator extends StatelessWidget {
  const _AutoModeIndicator({super.key});

  Future<void> _toggle(BuildContext context, bool on) async {
    final repository = RepositoryScope.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!on) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Ligar o piloto automático?'),
          content: const Text(
            'O Fluxo Smart passa a avançar as etapas sem pedir aprovação. Ele ainda para nos gates obrigatórios '
            '(spec e PR, ou os de gates.json), em bloqueios, push e operações destrutivas. Vale para todos os projetos.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Ligar')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      await repository.setAutoMode(!on);
    } on Exception catch (e, st) {
      log('autopilot toggle failed', name: 'ShellPage', error: e, stackTrace: st);
      messenger?.showSnackBar(SnackBar(content: Text('não foi possível alterar o piloto: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AutoModeBuilder(
      builder: (context, value) {
        final on = value == true;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: value == null ? null : () => _toggle(context, on),
            child: Tooltip(
              message: on ? 'Desligar: o fluxo volta a parar em todos os gates' : 'Ligar o piloto automático',
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.flight_takeoff, size: 14, color: on ? c.accent : c.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Piloto automático', style: TextStyle(fontSize: 12, color: c.textSecondary)),
                    ),
                    Pill(label: on ? 'on' : 'off', color: on ? c.accent : c.idle, dot: false),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FooterIcon extends StatelessWidget {
  const _FooterIcon({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 30, height: 30),
    icon: Icon(icon, size: 16, color: context.colors.textSecondary),
  );
}

class _EngineFooter extends StatelessWidget {
  const _EngineFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<EngineCubit>().state.data ?? const EngineState.starting();
    final (label, color) = switch (state.status) {
      EngineStatus.starting => ('engine iniciando', c.running),
      EngineStatus.ok => ('engine ok', c.pass),
      EngineStatus.stopped => ('engine parado', c.fail),
    };

    String? errorText;
    if (state.concurrentInstanceTook) {
      errorText = 'outra instância do app assumiu o engine';
    } else if (state.error != null) {
      errorText = state.error;
    } else if (state.versionWarning != null) {
      errorText = state.versionWarning;
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 120),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 12, color: c.textSecondary)),
              ),
              if (state.status == EngineStatus.stopped)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: c.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 24),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => SessionsScope.engineOf(context).restart(),
                  child: const Text('Reiniciar', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          if (errorText != null || state.stderrTail.isNotEmpty)
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (errorText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: SelectableText(
                          errorText,
                          maxLines: 2,
                          style: TextStyle(fontSize: 11, color: c.textMuted),
                        ),
                      ),
                    if (state.stderrTail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Expanded(child: Muted('stderr: ${state.stderrTail.last}', size: 11)),
                            TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: c.accent,
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                minimumSize: const Size(0, 24),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => _showStderrDialog(context, state.stderrTail),
                              child: const Text('ver detalhes', style: TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showStderrDialog(BuildContext context, List<String> stderr) {
    final c = context.colors;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Saída de erro do engine'),
        content: SizedBox(
          width: 600,
          height: 300,
          child: SingleChildScrollView(
            child: SelectableText(
              stderr.join('\n'),
              style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: c.textSecondary),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.project, required this.paletteProject, required this.pending});

  final Project project;

  /// `null` while the route project is unknown: the palette then cannot start a session.
  final Project? paletteProject;
  final int pending;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cycle = project.cycle;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Text(project.name, style: Theme.of(context).textTheme.titleMedium),
          if (cycle != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('/', style: TextStyle(color: c.textMuted)),
            ),
            Text(cycle.feature ?? project.name, style: TextStyle(color: c.textSecondary)),
            if (cycle.tracker case final tracker?) ...[
              const SizedBox(width: 10),
              Mono(tracker, color: c.textMuted, size: 11),
            ],
          ],
          const Spacer(),
          if (pending > 0) ...[
            _PendingPill(
              pending: pending,
              // Only the blocked cycle waits: the pill goes to its diagnosis, not to an empty session list.
              location: switch (blockedDecision(project)) {
                final decision? when pending == 1 => decisionLocation(project.name, decision),
                _ => '/p/${project.name}/sessions',
              },
            ),
            const SizedBox(width: 12),
          ],
          Tooltip(
            message: paletteProject == null ? 'repositório fora das suas orgs: adicione-o em Configurações' : '',
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: c.textPrimary,
                side: BorderSide(color: c.borderStrong),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
              onPressed: paletteProject == null ? null : () => showKickoffForm(context, paletteProject),
              icon: const Icon(Icons.rocket_launch_outlined, size: 15),
              label: const Text('Kickoff'),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            onPressed: () => showCommandPalette(context, ProjectTarget(paletteProject)),
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: const Text('Executar skill  ⌘K'),
          ),
        ],
      ),
    );
  }
}

class _PendingPill extends StatelessWidget {
  const _PendingPill({required this.pending, required this.location});

  final int pending;
  final String location;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(999),
    onTap: () => context.go(location),
    child: Pill(label: '$pending aguardando você', color: context.colors.warn),
  );
}

class _OrgTopBar extends StatelessWidget {
  const _OrgTopBar({required this.org, required this.pending, required this.known, required this.onNewActivity});

  final String org;
  final int pending;

  /// An org missing from the config only lists what resolves to its name: no "Nova atividade".
  final bool known;

  /// `null` when the org has no roots.
  final VoidCallback? onNewActivity;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Atividades em $org',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (pending > 0) ...[
            _PendingPill(pending: pending, location: orgSessionsLocation(org)),
            const SizedBox(width: 12),
          ],
          if (known)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
              onPressed: onNewActivity,
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text('Nova atividade  ⌘K'),
            ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.scope, required this.active});

  final ShellScope scope;
  final AppTab active;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tabs = switch (scope) {
      // "Para revisar" lists PRs of the whole account scope, not of a project: it lives with the org.
      ShellProjectScope() => [
        for (final t in AppTab.values)
          if (t != AppTab.queue && t != AppTab.inbox) t,
      ],
      ShellOrgScope() => const [AppTab.queue, AppTab.inbox, AppTab.sessions],
    };
    String location(AppTab t) => switch (scope) {
      ShellProjectScope(:final name) => '/p/$name/${t.name}',
      ShellOrgScope(:final org) => switch (t) {
        AppTab.queue => orgQueueLocation(org),
        AppTab.inbox => orgInboxLocation(org),
        _ => orgSessionsLocation(org),
      },
    };
    final inboxBadge = context.select<InboxCubit, int>((c) => c.state.badge);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          for (final t in tabs)
            InkWell(
              onTap: () => context.go(location(t)),
              hoverColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t == active ? c.accent : Colors.transparent, width: 2)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      t.label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: t == active ? FontWeight.w600 : FontWeight.w400,
                        color: t == active ? c.textPrimary : c.textSecondary,
                      ),
                    ),
                    if (t == AppTab.inbox && inboxBadge > 0) ...[
                      const SizedBox(width: 6),
                      Pill(key: const ValueKey('inbox-badge'), label: '$inboxBadge', color: c.accent, dot: false),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    super.key,
    required this.icon,
    required this.label,
    required this.location,
    required this.selected,
    this.pending = 0,
    this.pendingLabel,
    this.badgeKey,
  });

  final IconData icon;
  final String label;
  final String location;
  final bool selected;
  final int pending;

  /// Tooltip of the badge; "aguardando você" when `null`.
  final String? pendingLabel;
  final Key? badgeKey;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.hover : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.go(location),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 14, color: c.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ),
              if (pending > 0)
                Tooltip(
                  message: '$pending ${pendingLabel ?? 'aguardando você'}',
                  child: _CountBadge(pending, key: badgeKey),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A route project the config does not know, e.g. a repo opened from "Para revisar": its reviews live here, but the
/// Fluxo needs the folder registered in an org first.
class _UnknownProjectBanner extends StatelessWidget {
  const _UnknownProjectBanner({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: const ValueKey('unknown-project-banner'),
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: c.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$name não é um projeto das suas orgs. As revisões dele aparecem em Reviews; para rodar o Fluxo, '
              'Kickoff ou conversas aqui, adicione a pasta em Configurações.',
              style: TextStyle(fontSize: 12, color: c.textPrimary),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.accent),
            onPressed: () => context.go('/settings'),
            child: const Text('Configurações', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
