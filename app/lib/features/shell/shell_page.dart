import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/org_switch.dart';
import '../../app/engine_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';
import '../../engine/engine_supervisor.dart';
import '../launcher/command_palette.dart';

enum AppTab {
  flow('Fluxo'),
  runs('Execuções'),
  sessions('Sessões'),
  artifacts('Artefatos'),
  reviews('Reviews'),
  prs('PRs'),
  inbox('Para revisar'),
  metrics('Métricas'),
  adrs('ADRs');

  const AppTab(this.label);
  final String label;

  static AppTab parse(String? s) => AppTab.values.where((t) => t.name == s).firstOrNull ?? AppTab.flow;
}

class ShellPage extends StatefulWidget {
  const ShellPage({super.key, required this.projectName, required this.tab, required this.child});

  final String projectName;
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

  /// The route decides the org; `lastOrg` only follows, and only once the route project is known, so a
  /// loading snapshot or an unknown project never writes "Sem org".
  void _syncLastOrg(AsyncSnapshot<List<Project>> projects, DashboardConfig? config, Project? project) {
    if (!projects.hasData || config == null || project == null) return;
    if (project.org == config.lastOrg) {
      _syncing = null;
      _failed = null;
      return;
    }
    final org = project.org;
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

  @override
  Widget build(BuildContext context) {
    final snapshot = context.watch<ProjectsCubit>().state;
    final config = context.watch<ConfigCubit>().state.data;
    final projects = snapshot.data ?? const <Project>[];
    final routeProject = projects.where((p) => p.name == widget.projectName).firstOrNull;
    _syncLastOrg(snapshot, config, routeProject);
    final project = routeProject ?? Project(name: widget.projectName);
    final org = currentOrg(widget.projectName, projects, config);
    final pending = pendingByProject(context.watch<SessionsCubit>().state.data ?? const []);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showCommandPalette(context, routeProject),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(
                org: org,
                orgs: switchableOrgs(config, projects, pending),
                projects: projects,
                pending: pending,
                active: project.name,
                tab: widget.tab,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TopBar(
                      project: project,
                      paletteProject: routeProject,
                      pending: project.hidden ? 0 : pending[project.name] ?? 0,
                    ),
                    _Tabs(project: project.name, active: widget.tab),
                    if (project.hidden) _HiddenBanner(project: project.name),
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
    required this.orgs,
    required this.projects,
    required this.pending,
    required this.active,
    required this.tab,
  });

  final String org;
  final List<String> orgs;
  final List<Project> projects;
  final Map<String, int> pending;
  final String active;
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
          _OrgHeader(org: org, orgs: orgs, projects: projects, pending: pending),
          const SizedBox(height: 12),
          const Padding(padding: EdgeInsets.fromLTRB(8, 0, 8, 8), child: Muted('PROJETOS', size: 10)),
          Expanded(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Muted('nenhum projeto em $org — adicione em Configurações', size: 11),
                  )
                : ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final p in visible)
                        _ProjectTile(project: p, pending: pending[p.name] ?? 0, selected: p.name == active, tab: tab),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          const _AutoModeIndicator(on: true),
          const SizedBox(height: 8),
          const _EngineFooter(key: ValueKey('engine-footer')),
        ],
      ),
    );
  }
}

class _OrgHeader extends StatelessWidget {
  const _OrgHeader({required this.org, required this.orgs, required this.projects, required this.pending});

  final String org;
  final List<String> orgs;
  final List<Project> projects;
  final Map<String, int> pending;

  static const _settings = '\u0000settings';

  void _onSelected(BuildContext context, String value) {
    if (value == _settings) {
      context.go('/settings');
      return;
    }
    switchOrg(
      repository: RepositoryScope.of(context),
      router: GoRouter.of(context),
      projects: projects,
      org: value,
      messenger: ScaffoldMessenger.maybeOf(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = pendingInOrg(pending, projects, org);
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
                if (pendingInOrg(pending, projects, name) case final n when n > 0) ...[
                  _CountBadge(n),
                  const SizedBox(width: 8),
                ],
                if (i < 9) Mono('⌘${i + 1}', color: c.textMuted, size: 11),
              ],
            ),
          ),
        const PopupMenuDivider(),
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
  const _ProjectTile({required this.project, required this.pending, required this.selected, required this.tab});

  final Project project;
  final int pending;
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
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
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
                if (pending > 0) Tooltip(message: '$pending aguardando você', child: _CountBadge(pending)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AutoModeIndicator extends StatelessWidget {
  const _AutoModeIndicator({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
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
    );
  }
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
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => context.go('/p/${project.name}/sessions'),
              child: Pill(label: '$pending aguardando você', color: c.warn),
            ),
            const SizedBox(width: 12),
          ],
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: c.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            onPressed: () => showCommandPalette(context, paletteProject),
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: const Text('Executar skill  ⌘K'),
          ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.project, required this.active});

  final String project;
  final AppTab active;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          for (final t in AppTab.values)
            InkWell(
              onTap: () => context.go('/p/$project/${t.name}'),
              hoverColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t == active ? c.accent : Colors.transparent, width: 2)),
                ),
                child: Text(
                  t.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: t == active ? FontWeight.w600 : FontWeight.w400,
                    color: t == active ? c.textPrimary : c.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
