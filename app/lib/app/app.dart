import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../data/flow_repository.dart';
import '../data/sessions_repository.dart';
import '../engine/engine_supervisor.dart';
import 'engine_cubit.dart';
import 'projects_cubit.dart';
import 'router.dart';
import 'sessions_cubit.dart';

class ClaudeFlowApp extends StatefulWidget {
  const ClaudeFlowApp({super.key, required this.repository, required this.sessions, required this.engine});

  final FlowRepository repository;
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
      child: SessionsScope(
        sessions: widget.sessions,
        engine: widget.engine,
        child: MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => ProjectsCubit(widget.repository)),
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
          ),
        ),
      ),
    );
  }
}
