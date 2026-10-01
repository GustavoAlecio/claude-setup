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
import '../../data/session_models.dart';
import '../../engine/engine_config.dart';
import '../settings/org_form.dart';

/// `/` decides where the app opens from `landingFor`: "Criar org" without orgs, the org chooser when
/// `lastOrg` is unset or stale, otherwise `lastOrg` per [orgHome] (or its empty state).
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
    final sessions = context.read<SessionsCubit>().state.data ?? const <SessionSummary>[];
    if (landingFor(config, projects, sessions) case OpenOrgLanding(:final org)) {
      if (orgHome(org, projects, config) case final home?) context.go(home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = context.watch<ProjectsCubit>().state.data;
    final config = context.watch<ConfigCubit>().state.data;
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    return MultiBlocListener(
      listeners: [
        BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(listener: (_, _) => _maybeOpen()),
        BlocListener<ConfigCubit, AsyncSnapshot<DashboardConfig>>(listener: (_, _) => _maybeOpen()),
      ],
      child: Scaffold(
        body: projects == null || config == null || _awaitingSwitch(config)
            ? const SizedBox.shrink()
            : switch (landingFor(config, projects, sessions)) {
                CreateOrgLanding() => const _CreateOrg(),
                ChooseOrgLanding(:final options) => _ChooseOrg(options: options, projects: projects, config: config),
                OpenOrgLanding(:final org) =>
                  orgHome(org, projects, config) == null
                      ? _EmptyOrg(org: org, pending: firstPendingInOrg(sessions, projects, config, org))
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
          onSave: (org) => repository.updateConfig(createOrg(org.name, org.roots, github: org.github)),
        ),
      ),
    );
  }
}

class _ChooseOrg extends StatelessWidget {
  const _ChooseOrg({required this.options, required this.projects, required this.config});

  final List<String> options;
  final List<Project> projects;
  final DashboardConfig config;

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
                  config: config,
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
  const _EmptyOrg({required this.org, this.pending});

  final String org;

  /// An org can be offered with no visible project only for [kNoOrg]'s pending sessions; this opens them.
  final ({String name, String location})? pending;

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
          if (pending case final target?)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => context.go(target.location),
              child: Text('Ver sessões aguardando em ${target.name}', style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
