import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../data/flow_repository.dart';
import '../data/inventory_repository.dart';
import '../data/mock_inventory_repository.dart';
import '../data/orgs.dart';
import '../data/session_models.dart';
import '../data/sessions_repository.dart';
import '../engine/engine_supervisor.dart';
import '../features/launcher/command_palette.dart';
import '../core/claude_home.dart';
import 'config_cubit.dart';
import 'org_switch.dart';
import 'engine_cubit.dart';
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
    this.paths,
  });

  final FlowRepository repository;
  final FolderPicker pickDirectory;
  final SessionsRepository sessions;
  final EngineController engine;
  final InventoryRepository inventory;

  /// `null` reads the real environment.
  final EffectivePaths? paths;

  @override
  State<ClaudeFlowApp> createState() => _ClaudeFlowAppState();
}

class _ClaudeFlowAppState extends State<ClaudeFlowApp> {
  late final GoRouter _router = buildRouter(widget.paths ?? EffectivePaths.fromEnvironment());
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: widget.repository.reload, onExitRequested: _onExitRequested);
  }

  /// stdin EOF already ends the engine when the app dies; this waits for its flush on a regular quit.
  Future<AppExitResponse> _onExitRequested() async {
    await widget.engine.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepositoryScope(
      repository: widget.repository,
      pickDirectory: widget.pickDirectory,
      child: InventoryScope(
        repository: widget.inventory,
        child: SessionsScope(
          sessions: widget.sessions,
          engine: widget.engine,
          child: MultiBlocProvider(
            providers: [
              BlocProvider(create: (_) => ProjectsCubit(widget.repository)),
              BlocProvider(create: (_) => ConfigCubit(widget.repository)),
              BlocProvider(create: (_) => SessionsCubit(widget.sessions)),
              BlocProvider(create: (_) => EngineCubit(widget.engine), lazy: false),
            ],
            child: MaterialApp.router(
              title: 'Claude Flow',
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.light),
              darkTheme: buildTheme(Brightness.dark),
              themeMode: ThemeMode.dark,
              routerConfig: _router,
              builder: (context, child) => _GlobalShortcuts(router: _router, child: child!),
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

  void _switch(BuildContext context, int index) {
    final config = context.read<ConfigCubit>().state.data;
    final orgs = config?.orgs ?? const [];
    if (index >= orgs.length) return;
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

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true, shift: true): () => _newActivity(context),
      for (final (i, key) in _digits.indexed) SingleActivator(key, meta: true): () => _switch(context, i),
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => router.go('/settings'),
      const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () => router.go('/about'),
    },
    child: Focus(autofocus: true, child: child),
  );
}
