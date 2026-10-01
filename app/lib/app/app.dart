import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../data/flow_repository.dart';
import '../data/sessions_repository.dart';
import '../engine/engine_supervisor.dart';
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
  });

  final FlowRepository repository;
  final FolderPicker pickDirectory;
  final SessionsRepository sessions;
  final EngineController engine;

  @override
  State<ClaudeFlowApp> createState() => _ClaudeFlowAppState();
}

class _ClaudeFlowAppState extends State<ClaudeFlowApp> {
  late final GoRouter _router = buildRouter();
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

/// Above the Navigator so ⌘1..⌘9 (orgs in config order) and ⌘, work on every route.
class _GlobalShortcuts extends StatelessWidget {
  const _GlobalShortcuts({required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  void _switch(BuildContext context, int index) {
    final orgs = context.read<ConfigCubit>().state.data?.orgs ?? const [];
    if (index >= orgs.length) return;
    switchOrg(
      repository: RepositoryScope.of(context),
      router: router,
      projects: context.read<ProjectsCubit>().state.data ?? const [],
      org: orgs[index].name,
      messenger: ScaffoldMessenger.maybeOf(context),
    );
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (final (i, key) in _digits.indexed) SingleActivator(key, meta: true): () => _switch(context, i),
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => router.go('/settings'),
    },
    child: Focus(autofocus: true, child: child),
  );
}
