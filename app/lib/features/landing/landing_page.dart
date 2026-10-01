import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/org_switch.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_reducer.dart';
import '../../engine/engine_config.dart';
import '../settings/org_form.dart';

/// `/` decides where the app opens from `landingFor`: "Criar org" without orgs, the org chooser when
/// `lastOrg` is unset or stale, otherwise the first visible project of `lastOrg` (or its empty state).
class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  @override
  void initState() {
    super.initState();
    // BlocListener only sees changes; when '/' is revisited both streams may already be loaded.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOpen());
  }

  bool _awaitingSwitch(DashboardConfig config) {
    final pending = GoRouterState.of(context).uri.queryParameters['org'];
    return pending != null && config.lastOrg != pending;
  }

  void _maybeOpen() {
    if (!mounted) return;
    final projects = context.read<ProjectsCubit>().state.data;
    final config = context.read<ConfigCubit>().state.data;
    if (projects == null || config == null || _awaitingSwitch(config)) return;
    final pending = pendingByProject(context.read<SessionsCubit>().state.data ?? const []);
    if (landingFor(config, projects, pending) case OpenOrgLanding(:final org)) {
      final first = projectsInOrg(projects, org).firstOrNull;
      if (first != null) context.go('/p/${first.name}/flow');
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = context.watch<ProjectsCubit>().state.data;
    final config = context.watch<ConfigCubit>().state.data;
    final pending = pendingByProject(context.watch<SessionsCubit>().state.data ?? const []);
    return MultiBlocListener(
      listeners: [
        BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(listener: (_, _) => _maybeOpen()),
        BlocListener<ConfigCubit, AsyncSnapshot<DashboardConfig>>(listener: (_, _) => _maybeOpen()),
      ],
      child: Scaffold(
        body: projects == null || config == null || _awaitingSwitch(config)
            ? const SizedBox.shrink()
            : switch (landingFor(config, projects, pending)) {
                CreateOrgLanding() => const _CreateOrg(),
                ChooseOrgLanding(:final options) => _ChooseOrg(options: options, projects: projects),
                OpenOrgLanding(:final org) =>
                  projectsInOrg(projects, org).isEmpty
                      ? _EmptyOrg(
                          org: org,
                          pendingProject: pending.keys.where((p) => belongsToOrg(p, projects, org)).firstOrNull,
                        )
                      : const SizedBox.shrink(),
              },
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[const SizedBox(height: 6), Muted(subtitle!, size: 12)],
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateOrg extends StatefulWidget {
  const _CreateOrg();

  @override
  State<_CreateOrg> createState() => _CreateOrgState();
}

class _CreateOrgState extends State<_CreateOrg> {
  late final Future<List<String>> _suggestions = RepositoryScope.of(context).suggestedRoots();

  @override
  Widget build(BuildContext context) {
    final repository = RepositoryScope.of(context);
    return _Card(
      title: 'Criar org',
      subtitle: 'Uma org agrupa os projetos de uma pasta. O app sempre abre em uma org.',
      child: FutureBuilder<List<String>>(
        future: _suggestions,
        builder: (_, snapshot) => OrgForm(
          maxRoots: 1,
          suggestions: snapshot.data ?? const [],
          saveLabel: 'Criar org',
          onSave: (org) => repository.updateConfig(createOrg(org.name, org.roots)),
        ),
      ),
    );
  }
}

class _ChooseOrg extends StatelessWidget {
  const _ChooseOrg({required this.options, required this.projects});

  final List<String> options;
  final List<Project> projects;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _Card(
      title: 'Escolha uma org',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final org in options)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  side: BorderSide(color: c.border),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                ),
                onPressed: () => switchOrg(
                  repository: RepositoryScope.of(context),
                  router: GoRouter.of(context),
                  projects: projects,
                  org: org,
                  messenger: ScaffoldMessenger.maybeOf(context),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(org, style: const TextStyle(fontSize: 13))),
                    Muted('${projectsInOrg(projects, org).length} projetos', size: 11),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyOrg extends StatelessWidget {
  const _EmptyOrg({required this.org, this.pendingProject});

  final String org;

  /// An org can be offered with no visible project only for [kNoOrg]'s pending sessions; this opens them.
  final String? pendingProject;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Muted('nenhum projeto em $org — adicione em Configurações', size: 13),
          const SizedBox(height: 8),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.accent),
            onPressed: () => context.go('/settings'),
            child: const Text('Abrir Configurações  ⌘,', style: TextStyle(fontSize: 12)),
          ),
          if (pendingProject case final project?)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => context.go('/p/$project/sessions'),
              child: Text('Ver sessões aguardando em $project', style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
