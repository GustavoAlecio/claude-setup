import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../data/flow_repository.dart';
import '../features/shell/projects_cubit.dart';
import 'router.dart';

class ClaudeFlowApp extends StatefulWidget {
  const ClaudeFlowApp({super.key, required this.repository});

  final FlowRepository repository;

  @override
  State<ClaudeFlowApp> createState() => _ClaudeFlowAppState();
}

class _ClaudeFlowAppState extends State<ClaudeFlowApp> {
  late final GoRouter _router = buildRouter();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: widget.repository.reload);
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
      child: BlocProvider(
        create: (_) => ProjectsCubit(widget.repository),
        child: MaterialApp.router(
          title: 'Claude Flow',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: ThemeMode.dark,
          routerConfig: _router,
        ),
      ),
    );
  }
}
