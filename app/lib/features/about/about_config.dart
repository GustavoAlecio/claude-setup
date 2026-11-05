import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/claude_home.dart';
import '../../app/config_cubit.dart';
import '../../app/engine_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';
import '../../engine/engine_supervisor.dart';
import 'about_widgets.dart';

/// Read-only: edits go through Configurações, the only screen that writes `.dashboard.json`.
class AboutConfig extends StatelessWidget {
  const AboutConfig({super.key, required this.claudeHome, required this.paths});

  final String claudeHome;
  final EffectivePaths paths;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final config = context.watch<ConfigCubit>().state.data;
    final projects = context.watch<ProjectsCubit>().state.data ?? const [];
    final engine = context.watch<EngineCubit>().state.data;
    if (config == null) return const SizedBox.shrink();
    final engineDir = effectiveEngineDir(engineDirDefine: paths.engineDirDefine, config: config, home: paths.home);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.edit, size: 14),
            label: const Text('Editar em Configurações', style: TextStyle(fontSize: 12)),
          ),
        ),
        const SectionTitle('ORGS'),
        if (config.orgs.isEmpty) const Muted('nenhuma'),
        for (final org in config.orgs)
          _Row(
            key: ValueKey('about-config-org-${org.name}'),
            label: org.name,
            value:
                '${org.roots.isEmpty ? 'sem raízes' : org.roots.join(', ')} · '
                '${projectsInOrg(projects, org.name).length} projetos visíveis',
          ),
        _Row(label: 'lastOrg', value: config.lastOrg ?? '—'),
        const SectionTitle('PROJETOS REGISTRADOS'),
        if (config.projects.isEmpty) const Muted('nenhum'),
        for (final p in config.projects)
          _Row(
            key: ValueKey('about-config-project-${p.name}'),
            label: p.name,
            value: [p.path ?? 'sem path', if (p.org != null) 'org ${p.org}'].join(' · '),
          ),
        const SectionTitle('OCULTOS'),
        if (config.hidden.isEmpty) const Muted('nenhum'),
        for (final name in config.hidden) Mono(name, key: ValueKey('about-config-hidden-$name')),
        const SectionTitle('ENGINE'),
        _Row(
          key: const ValueKey('about-config-engine-dir'),
          label: 'engineDir (config)',
          value: config.engineDir ?? '—',
        ),
        _Row(
          key: const ValueKey('about-config-engine-dir-effective'),
          label: 'engineDir (efetivo)',
          value: [engineDir ?? '—', if (paths.engineDirDefine.isNotEmpty) 'define ENGINE_DIR'].join(' · '),
        ),
        _Row(label: 'nodePath', value: config.nodePath ?? 'PATH'),
        _Row(
          label: 'paletteSkills',
          value: config.paletteSkills == null ? 'padrão (todas)' : config.paletteSkills!.join(', '),
        ),
        _Row(
          key: const ValueKey('about-config-engine-state'),
          label: 'estado',
          value: switch (engine?.status) {
            null || EngineStatus.starting => 'iniciando',
            EngineStatus.ok => 'ok ${engine!.endpoint}',
            EngineStatus.stopped => 'parado${engine!.error == null ? '' : ': ${engine.error}'}',
          },
        ),
        const SectionTitle('CAMINHOS EFETIVOS'),
        _Row(label: 'raiz do workflow', key: const ValueKey('about-config-workflow-root'), value: paths.workflowRoot),
        _Row(label: 'claudeHome', value: claudeHome),
        if (engine?.versionWarning case final warning?) ...[
          const SizedBox(height: 8),
          Text(warning, style: TextStyle(fontSize: 12, color: c.warn)),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(label, style: TextStyle(fontSize: 12, color: c.textMuted)),
          ),
          Expanded(
            child: SelectableText(value, style: TextStyle(fontSize: 12, color: c.textPrimary)),
          ),
        ],
      ),
    );
  }
}
