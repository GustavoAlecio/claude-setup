import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/engine_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
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

class ShellPage extends StatelessWidget {
  const ShellPage({super.key, required this.projectName, required this.tab, required this.child});

  final String projectName;
  final AppTab tab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final projects = context.watch<ProjectsCubit>().state.data ?? const <Project>[];
    final project = projects.where((p) => p.name == projectName).firstOrNull ?? Project(name: projectName);
    final pending = pendingByProject(context.watch<SessionsCubit>().state.data ?? const []);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showCommandPalette(context, project.name),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Sidebar(projects: projects, pending: pending, active: project.name, tab: tab),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TopBar(project: project, pending: pending[project.name] ?? 0),
                    _Tabs(project: project.name, active: tab),
                    Expanded(child: child),
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
  const _Sidebar({required this.projects, required this.pending, required this.active, required this.tab});

  final List<Project> projects;
  final Map<String, int> pending;
  final String active;
  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(right: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 44, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(8, 0, 8, 8), child: Muted('PROJETOS', size: 10)),
          for (final p in projects)
            _ProjectTile(project: p, pending: pending[p.name] ?? 0, selected: p.name == active, tab: tab),
          const Spacer(),
          const _AutoModeIndicator(on: true),
          const SizedBox(height: 8),
          const _EngineFooter(),
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
                if (pending > 0)
                  Tooltip(
                    message: '$pending aguardando você',
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 18),
                      height: 18,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: c.warn, borderRadius: BorderRadius.circular(9)),
                      child: Text(
                        '$pending',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.canvas),
                      ),
                    ),
                  ),
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
  const _EngineFooter();

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
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (errorText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(errorText, maxLines: 2, style: TextStyle(fontSize: 11, color: c.textMuted)),
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
  const _TopBar({required this.project, required this.pending});

  final Project project;
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
            onPressed: () => showCommandPalette(context, project.name),
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
