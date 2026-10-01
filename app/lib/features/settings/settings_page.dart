import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';
import 'org_form.dart';

/// Orgs are edited as a form with Salvar; project and hidden actions write as soon as they happen.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.backTo});

  /// Location of "Voltar": the last project route visited, or the landing.
  final String Function() backTo;

  /// An org switched from here (⌘N) changes `lastOrg` without leaving; back in a project of the old org
  /// the shell would write that org back, so the landing opens the new one instead.
  String _back(DashboardConfig? config, List<Project>? projects) {
    final target = backTo();
    final segments = Uri.parse(target).pathSegments;
    if (config == null || projects == null || segments.length < 2 || segments.first != 'p') return target;
    final org = projects.where((p) => p.name == segments[1]).firstOrNull?.org;
    return org == null || org == config.lastOrg ? target : '/';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final config = context.watch<ConfigCubit>().state.data;
    final projects = context.watch<ProjectsCubit>().state.data;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, kTitleBarInset, 20, 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                  onPressed: () => context.go(_back(config, projects)),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('Voltar', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Text('Configurações', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          Expanded(
            child: config == null || projects == null
                ? const SizedBox.shrink()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
                    children: [
                      _OrgsSection(config: config),
                      const SizedBox(height: 28),
                      _ProjectsSection(config: config, projects: projects),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Muted(text, size: 11));
}

class _OrgsSection extends StatefulWidget {
  const _OrgsSection({required this.config});

  final DashboardConfig config;

  @override
  State<_OrgsSection> createState() => _OrgsSectionState();
}

class _OrgsSectionState extends State<_OrgsSection> {
  bool _adding = false;

  List<OrgConfig> get _orgs => widget.config.orgs;

  Future<void> _update(OrgConfig old, OrgConfig draft) =>
      RepositoryScope.of(context).updateConfig(updateOrg(old.name, draft));

  Future<void> _add(OrgConfig draft) async {
    await RepositoryScope.of(context).updateConfig(addOrg(draft));
    if (mounted) setState(() => _adding = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final repository = RepositoryScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('ORGS'),
        for (final org in _orgs)
          Panel(
            key: ValueKey('settings-org-form-${org.name}'),
            child: OrgForm(
              key: ValueKey(org.name),
              initial: org,
              others: [
                for (final o in _orgs)
                  if (o.name != org.name) o,
              ],
              onSave: (draft) => _update(org, draft),
              onRemove: () => repository.updateConfig(removeOrg(org.name)),
            ),
          ),
        if (_adding)
          Panel(
            key: const ValueKey('settings-new-org'),
            child: OrgForm(others: _orgs, saveLabel: 'Criar org', onSave: _add),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => setState(() => _adding = true),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Nova org', style: TextStyle(fontSize: 12)),
            ),
          ),
      ],
    );
  }
}

class _ProjectsSection extends StatefulWidget {
  const _ProjectsSection({required this.config, required this.projects});

  final DashboardConfig config;
  final List<Project> projects;

  @override
  State<_ProjectsSection> createState() => _ProjectsSectionState();
}

class _ProjectsSectionState extends State<_ProjectsSection> {
  String? _error;
  String? _notice;
  bool _picking = false;

  Future<void> _write(ConfigMutation mutation) async {
    setState(() => _error = null);
    try {
      await RepositoryScope.of(context).updateConfig(mutation);
    } on ConfigWriteException catch (e, st) {
      log('project write rejected', name: 'SettingsPage', error: e, stackTrace: st);
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _addProject() async {
    final repository = RepositoryScope.of(context);
    final pick = RepositoryScope.pickerOf(context);
    setState(() => _picking = true);
    try {
      final dir = await pick();
      if (dir == null || !mounted) return;
      final picked = await repository.inspectDirectory(dir);
      if (!mounted) return;
      setState(() => _notice = picked.divergence);
      await _write(addProject(name: picked.name, path: picked.path));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final orgs = [for (final o in widget.config.orgs) o.name, kNoOrg];
    final hidden = widget.config.hidden;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionTitle('PROJETOS')),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: _picking ? null : _addProject,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Adicionar projeto', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_error!, style: TextStyle(fontSize: 12, color: c.fail)),
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_notice!, style: TextStyle(fontSize: 12, color: c.warn)),
          ),
        for (final org in orgs)
          if (org != kNoOrg || projectsInOrg(widget.projects, kNoOrg).isNotEmpty)
            Panel(
              key: ValueKey('settings-projects-$org'),
              title: org,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (projectsInOrg(widget.projects, org).isEmpty) const Muted('nenhum projeto', size: 12),
                  for (final p in projectsInOrg(widget.projects, org))
                    _ProjectRow(
                      project: p,
                      orgs: orgs,
                      onOrg: (target) => _write(setProjectOrg(p.name, target, path: p.path)),
                      onHide: () => _write(hideProject(p.name)),
                    ),
                ],
              ),
            ),
        const SizedBox(height: 28),
        const _SectionTitle('OCULTOS'),
        Panel(
          key: const ValueKey('settings-hidden'),
          child: hidden.isEmpty
              ? const Muted('nenhum projeto oculto', size: 12)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final name in hidden)
                      Row(
                        children: [
                          Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: c.accent),
                            onPressed: () => _write(unhideProject(name)),
                            child: const Text('Reexibir', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.project, required this.orgs, required this.onOrg, required this.onHide});

  final Project project;
  final List<String> orgs;
  final ValueChanged<String> onOrg;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(project.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Mono(project.path ?? 'sem pasta', color: c.textMuted, size: 11),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Trocar org de ${project.name}',
            color: c.elevated,
            onSelected: onOrg,
            itemBuilder: (_) => [
              for (final org in orgs)
                PopupMenuItem(
                  value: org,
                  height: 36,
                  child: Text(org, style: const TextStyle(fontSize: 13)),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(project.org, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                  Icon(Icons.arrow_drop_down, size: 16, color: c.textMuted),
                ],
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.textSecondary),
            onPressed: onHide,
            child: const Text('Ocultar', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
