import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../core/widgets/unsaved_changes.dart';
import 'attention_watcher.dart';
import 'terminal_handoff.dart';
import '../data/docs_repository.dart';
import '../data/flow_repository.dart';
import '../data/github_repository.dart';
import '../data/mock_github_repository.dart';
import '../data/inventory_repository.dart';
import '../data/metrics_repository.dart';
import '../data/mock_docs_repository.dart';
import '../data/mock_inventory_repository.dart';
import '../data/mock_metrics_repository.dart';
import '../data/attention.dart';
import '../data/orgs.dart';
import '../data/session_models.dart';
import '../data/sessions_repository.dart';
import '../engine/engine_supervisor.dart';
import '../features/launcher/command_palette.dart';
import '../core/claude_home.dart';
import 'config_cubit.dart';
import 'org_switch.dart';
import 'engine_cubit.dart';
import 'inbox_cubit.dart';
import 'projects_cubit.dart';
import 'router.dart';
import 'sessions_cubit.dart';

class ClaudeFlowApp extends StatefulWidget {
  const ClaudeFlowApp({
    super.key,
    required this.repository,
    required this.sessions,
    required this.engine,
    this.pickDirectory = getDirectoryPath,
    this.inventory = const MockInventoryRepository.empty(),
    this.metrics = const MockMetricsRepository.empty(),
    this.docs,
    this.github,
    this.paths,
  });

  final FlowRepository repository;
  final FolderPicker pickDirectory;
  final SessionsRepository sessions;
  final EngineController engine;
  final InventoryRepository inventory;
  final MetricsRepository metrics;

  /// `null` is [MockDocsRepository.empty].
  final DocsRepository? docs;

  /// `null` is [MockGitHubRepository.empty].
  final GitHubRepository? github;

  /// `null` reads the real environment.
  final EffectivePaths? paths;

  @override
  State<ClaudeFlowApp> createState() => _ClaudeFlowAppState();
}

class _ClaudeFlowAppState extends State<ClaudeFlowApp> {
  late final GoRouter _router = buildRouter(widget.paths ?? EffectivePaths.fromEnvironment());
  late final AppLifecycleListener _lifecycle;
  static final _fallbackDocs = MockDocsRepository.empty();
  late final _fallbackGithub = MockGitHubRepository.empty();
  final _unsaved = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: widget.repository.reload, onExitRequested: _onExitRequested);
  }

  /// stdin EOF already ends the engine when the app dies; this waits for its flush on a regular quit. ⌘Q and the
  /// window's close button (`AppDelegate.windowShouldClose`) both land here, so unsaved edits are asked about first.
  Future<AppExitResponse> _onExitRequested() async {
    final dialogContext = _router.routerDelegate.navigatorKey.currentContext;
    if (_unsaved.value && dialogContext != null && dialogContext.mounted) {
      if (!await confirmDiscard(dialogContext, _unsaved)) return AppExitResponse.cancel;
    }
    await widget.engine.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _unsaved.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final docs = widget.docs ?? _fallbackDocs;
    final github = widget.github ?? _fallbackGithub;
    return RepositoryScope(
      repository: widget.repository,
      pickDirectory: widget.pickDirectory,
      child: InventoryScope(
        repository: widget.inventory,
        child: MetricsScope(
          repository: widget.metrics,
          child: DocsScope(
            repository: docs,
            opener: docs.open,
            child: SessionsScope(
              sessions: widget.sessions,
              engine: widget.engine,
              child: GitHubScope(
                repository: github,
                child: UnsavedChangesScope(
                  unsaved: _unsaved,
                  child: MultiBlocProvider(
                    providers: [
                      BlocProvider(create: (_) => ProjectsCubit(widget.repository)),
                      BlocProvider(create: (_) => ConfigCubit(widget.repository)),
                      BlocProvider(create: (_) => SessionsCubit(widget.sessions)),
                      BlocProvider(create: (_) => EngineCubit(widget.engine), lazy: false),
                      BlocProvider(
                        create: (_) => InboxCubit(
                          github,
                          widget.engine.watch().map((s) => s.endpoint),
                          widget.repository.watchConfig().map((c) => githubFor(c.lastOrg, c)),
                        ),
                        lazy: false,
                      ),
                    ],
                    child: MaterialApp.router(
                      title: 'Claude Flow',
                      debugShowCheckedModeBanner: false,
                      theme: buildTheme(Brightness.light),
                      darkTheme: buildTheme(Brightness.dark),
                      themeMode: ThemeMode.dark,
                      routerConfig: _router,
                      builder: (context, child) => AttentionWatcher(
                        router: _router,
                        child: TerminalHandoffListener(
                          router: _router,
                          child: _GlobalShortcuts(router: _router, child: child!),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

/// Above the Navigator so ⌘1..⌘9 (orgs in config order), ⌘, and ⌘I work on every route.
class _GlobalShortcuts extends StatelessWidget {
  const _GlobalShortcuts({required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  /// Leaving a route with unsaved edits asks first, like the page's own Voltar does.
  Future<bool> _mayLeave(BuildContext context) async {
    final dialogContext = router.routerDelegate.navigatorKey.currentContext;
    if (dialogContext == null) return true;
    return confirmDiscard(dialogContext, UnsavedChangesScope.of(context));
  }

  Future<void> _go(BuildContext context, String location) async {
    if (await _mayLeave(context)) router.go(location);
  }

  Future<void> _switch(BuildContext context, int index) async {
    final config = context.read<ConfigCubit>().state.data;
    final orgs = config?.orgs ?? const [];
    if (index >= orgs.length) return;
    if (!await _mayLeave(context) || !context.mounted) return;
    switchOrg(
      repository: RepositoryScope.of(context),
      router: router,
      projects: context.read<ProjectsCubit>().state.data ?? const [],
      config: config,
      org: orgs[index].name,
      messenger: ScaffoldMessenger.maybeOf(context),
    );
  }

  /// Org of the current location, for the palette: the route's inside the shell, `lastOrg` on the landing.
  /// Settings, About and the org chooser resolve to none.
  void _newActivity(BuildContext context) {
    final navigator = router.routerDelegate.navigatorKey;
    final dialogContext = navigator.currentContext;
    if (dialogContext == null || navigator.currentState?.canPop() == true) return;
    final config = context.read<ConfigCubit>().state.data;
    final projects = context.read<ProjectsCubit>().state.data;
    if (config == null || projects == null) return;
    final sessions = context.read<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final location = router.routerDelegate.currentConfiguration.uri.toString();
    final org = paletteOrg(location, config, projects, sessions: sessions);
    final target = org == null ? null : OrgTarget.of(orgConfigOf(config, org));
    if (target != null) showCommandPalette(dialogContext, target);
  }

  Future<void> _nextPending(BuildContext context) async {
    final items = pendingAttention(
      context.read<SessionsCubit>().state.data ?? const [],
      context.read<ProjectsCubit>().state.data ?? const [],
    );
    final route = nextAttentionRoute(items, router.routerDelegate.currentConfiguration.uri.toString());
    if (route == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('nada esperando por você')));
      return;
    }
    await _go(context, route);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyJ, meta: true): () => _nextPending(context),
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true, shift: true): () => _newActivity(context),
      for (final (i, key) in _digits.indexed) SingleActivator(key, meta: true): () => _switch(context, i),
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => _go(context, '/settings'),
      const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () => _go(context, '/about'),
    },
    child: Focus(autofocus: true, child: child),
  );
}
