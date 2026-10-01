import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/inline_markdown.dart';
import '../../core/widgets/primitives.dart';
import '../../data/inventory_models.dart';
import '../../data/inventory_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import 'about_widgets.dart';

class AboutProject extends StatefulWidget {
  const AboutProject({super.key, required this.routeProject, required this.generation});

  /// Project of the last route: picks the org and the default selection.
  final String? routeProject;

  /// Bumped by "Recarregar" so the selected project is read again.
  final int generation;

  @override
  State<AboutProject> createState() => _AboutProjectState();
}

class _AboutProjectState extends State<AboutProject> {
  String? _picked;
  Future<ProjectInventory>? _future;
  (String, String?, int)? _loadedFor;

  Future<ProjectInventory> _load(Project project) {
    final key = (project.name, project.path, widget.generation);
    if (_loadedFor != key || _future == null) {
      _loadedFor = key;
      _future = InventoryScope.of(context).loadProject(project);
    }
    return _future!;
  }

  @override
  Widget build(BuildContext context) {
    final projects = context.watch<ProjectsCubit>().state.data;
    final config = context.watch<ConfigCubit>().state.data;
    if (projects == null) return const SizedBox.shrink();
    final org = currentOrg(widget.routeProject, projects, config);
    final visible = projectsInOrg(projects, org);
    final selected =
        visible.where((p) => p.name == _picked).firstOrNull ??
        visible.where((p) => p.name == widget.routeProject).firstOrNull ??
        visible.firstOrNull;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      children: [
        Row(
          children: [
            Muted('org $org', size: 12),
            const SizedBox(width: 16),
            if (selected == null)
              const Muted('nenhum projeto')
            else
              DropdownButton<String>(
                key: const ValueKey('about-project-picker'),
                value: selected.name,
                isDense: true,
                style: TextStyle(fontSize: 13, color: context.colors.textPrimary),
                items: [for (final p in visible) DropdownMenuItem(value: p.name, child: Text(p.name))],
                onChanged: (name) => setState(() => _picked = name),
              ),
          ],
        ),
        if (selected != null) ...[
          const SizedBox(height: 6),
          Mono(selected.path ?? 'sem path', color: context.colors.textMuted, size: 11),
          FutureBuilder<ProjectInventory>(
            future: _load(selected),
            builder: (context, snapshot) {
              if (snapshot.hasError) return ErrorText('não foi possível ler o projeto: ${snapshot.error}');
              final data = snapshot.data;
              if (data == null || snapshot.connectionState != ConnectionState.done) return const SizedBox.shrink();
              return _ProjectSections(data: data, hasPath: selected.path != null);
            },
          ),
        ],
      ],
    );
  }
}

class _ProjectSections extends StatelessWidget {
  const _ProjectSections({required this.data, required this.hasPath});

  final ProjectInventory data;
  final bool hasPath;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final adrs = [...data.adrs]..sort((a, b) => a.id.compareTo(b.id));
    final routing = data.routing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasPath) ...[
          const SectionTitle('RULES'),
          if (data.rules.isEmpty) const Muted('nenhuma'),
          for (final r in data.rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Mono(r.name, color: c.textPrimary),
                  if (r.error != null)
                    ErrorText(r.error!)
                  else if (r.summary.isNotEmpty)
                    Text(r.summary, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                ],
              ),
            ),
          const SectionTitle('ADRs'),
          if (adrs.isEmpty) const Muted('nenhum'),
          for (final a in adrs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: a.error != null
                  ? ErrorText(a.error!)
                  : Row(
                      children: [
                        SizedBox(width: 48, child: Mono(a.id)),
                        Expanded(child: Text(a.title, style: const TextStyle(fontSize: 13))),
                        Pill(label: a.status, color: a.status == 'accepted' ? c.pass : c.textMuted, dot: false),
                      ],
                    ),
            ),
        ],
        const SectionTitle('LESSONS'),
        if (data.lessons.isEmpty) const Muted('nenhuma'),
        for (final l in data.lessons)
          InlineMarkdown('- $l', style: TextStyle(fontSize: 12, height: 1.5, color: c.textSecondary)),
        const SectionTitle('ROUTING'),
        if (routing.error != null) ErrorText(routing.error!),
        _RoutingTable(routing: routing),
      ],
    );
  }
}

class _RoutingTable extends StatelessWidget {
  const _RoutingTable({required this.routing});

  final Routing routing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = TextStyle(fontSize: 12, color: c.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Muted('faixas', size: 11),
        if (routing.bands.isEmpty) const Muted('nenhuma'),
        for (final b in routing.bands)
          Text(
            '${b.complexity}/${b.risk} · n ${b.n} · pass tier0 ${b.passTier0} · escaladas ${b.escalated}'
            ' · bloqueadas ${b.blocked} · tentativas/task ${b.attemptsPerTask.toStringAsFixed(1)}'
            ' · finais ${b.finalTiers.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
            style: style,
          ),
        const SizedBox(height: 8),
        const Muted('overrides', size: 11),
        if (routing.overrides.isEmpty) const Muted('nenhum'),
        for (final MapEntry(:key, :value) in routing.overrides.entries) Mono('$key → $value'),
      ],
    );
  }
}
