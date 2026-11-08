import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../data/orgs.dart';
import '../data/session_models.dart';
import '../data/sessions_repository.dart';
import 'config_cubit.dart';
import 'projects_cubit.dart';

/// Answers the terminal's `/app`: imports the session the same way the Sessões tab does (org, mode and account of
/// the project it ran in) and opens it. Bringing the window forward is the script's `open`.
class TerminalHandoffListener extends StatefulWidget {
  const TerminalHandoffListener({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  State<TerminalHandoffListener> createState() => _TerminalHandoffListenerState();
}

class _TerminalHandoffListenerState extends State<TerminalHandoffListener> {
  SessionsRepository? _repo;
  StreamSubscription<TerminalHandoff>? _sub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = SessionsScope.of(context);
    if (identical(repo, _repo)) return;
    _repo = repo;
    unawaited(_sub?.cancel());
    _sub = repo.terminalHandoffs().listen((h) => unawaited(_open(repo, h)));
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _tell(String text) {
    final navigator = widget.router.routerDelegate.navigatorKey.currentContext;
    if (navigator != null) ScaffoldMessenger.maybeOf(navigator)?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _open(SessionsRepository repo, TerminalHandoff handoff) async {
    final projects = context.read<ProjectsCubit>().state.data ?? const <Project>[];
    final config = context.read<ConfigCubit>().state.data;
    final project = projectOfCwd(handoff.cwd, projects);
    if (project == null) {
      _tell('${handoff.cwd} não está em nenhum projeto do app; adicione a pasta numa org para trazer a sessão.');
      return;
    }
    final launch = launchOrg(handoff.cwd, projects, config);
    try {
      final session = await repo.importTerminalSession(
        sdkSessionId: handoff.sdkSessionId,
        cwd: handoff.cwd,
        project: project.name,
        githubAccount: githubFor(launch.org, config).account,
        permissionMode: launch.mode,
      );
      widget.router.go(sessionLocation(session));
    } on Exception catch (e, st) {
      log('terminal handoff failed', name: 'TerminalHandoff', error: e, stackTrace: st);
      _tell('Não deu para trazer a sessão do terminal: $e');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
