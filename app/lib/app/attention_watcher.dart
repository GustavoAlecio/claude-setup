import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/platform/attention.dart';
import '../data/attention.dart';
import '../data/models.dart';
import '../data/session_models.dart';
import 'projects_cubit.dart';
import 'sessions_cubit.dart';

/// Keeps the Dock badge on the total waiting for the user and, with the app in the background, posts one macOS
/// notification per new item (pending request, stopped cycle, finished turn). What already waited at launch is not
/// announced again.
class AttentionWatcher extends StatefulWidget {
  const AttentionWatcher({
    super.key,
    required this.router,
    required this.child,
    this.channel = const AttentionChannel(),
  });

  final GoRouter router;
  final AttentionChannel channel;
  final Widget child;

  @override
  State<AttentionWatcher> createState() => _AttentionWatcherState();
}

class _AttentionWatcherState extends State<AttentionWatcher> {
  Set<String>? _seen;
  Map<String, SessionStatus> _statuses = const {};

  @override
  void initState() {
    super.initState();
    widget.channel.onOpen(widget.router.go);
  }

  Future<void> _update() async {
    final sessions = context.read<SessionsCubit>().state.data;
    final projects = context.read<ProjectsCubit>().state.data;
    if (sessions == null || projects == null) return;
    unawaited(widget.channel.badge(attentionCount(sessions, projects)));
    final pending = pendingAttention(sessions, projects);
    final finished = finishedTurns(_statuses, sessions);
    _statuses = {for (final s in sessions) s.id: s.status};
    final seen = _seen;
    _seen = {for (final i in pending) i.key};
    if (seen == null) return;
    final fresh = [...pending.where((i) => !seen.contains(i.key)), ...finished];
    if (fresh.isEmpty || await widget.channel.isActive()) return;
    for (final item in fresh) {
      unawaited(widget.channel.notify(id: item.key, title: item.title, body: item.body, route: item.route));
    }
  }

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<SessionsCubit, AsyncSnapshot<List<SessionSummary>>>(listener: (_, _) => unawaited(_update())),
      BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(listener: (_, _) => unawaited(_update())),
    ],
    child: widget.child,
  );
}
