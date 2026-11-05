import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_models.dart';
import '../../data/workflow_parser.dart';
import '../../engine/engine_config.dart';
import '../launcher/command_palette.dart';
import '../shell/shell_scope.dart';
import 'session_view.dart';
import 'session_labels.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.scope, this.sessionId});

  final ShellScope scope;
  final String? sessionId;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  /// Without an id in the route the first pending session is picked once; re-picking on every update
  /// would jump to another session as soon as the user answers the one on screen.
  String? _autoSelected;

  @override
  void didUpdateWidget(SessionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) _autoSelected = null;
  }

  @override
  Widget build(BuildContext context) {
    final all = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final projects = context.watch<ProjectsCubit>().state.data ?? const <Project>[];
    final config = context.watch<ConfigCubit>().state.data;
    final SessionSummary? selected;
    final Widget list;
    switch (widget.scope) {
      case ShellProjectScope(name: final projectName):
        final org = currentOrg(projectName, projects, config);
        final projectSessions = all.where((s) => !s.isOrgSession);
        final mine = projectSessions.where((s) => s.project == projectName).toList();
        final others = projectSessions
            .where((s) => s.project != projectName && sessionOrg(s, projects, config) == org)
            .toList();
        selected = _select(all, mine, widget.sessionId);
        list = _SessionList.project(
          project: projects.where((p) => p.name == projectName).firstOrNull,
          mine: mine,
          others: others,
          selected: selected?.id,
        );
      case ShellOrgScope(:final org):
        final mine = orgActivities(all, projects, config, org);
        // An id of another org's (or a project's) session is ignored, as if the route had none.
        final routeId = mine.any((s) => s.id == widget.sessionId) ? widget.sessionId : null;
        selected = _select(mine, mine, routeId);
        list = _SessionList.org(
          org: org,
          target: OrgTarget.of(orgConfigOf(config, org)),
          mine: mine,
          selected: selected?.id,
        );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        list,
        Expanded(
          child: switch (selected) {
            null => const Center(child: Muted('Nenhuma sessão. Rode uma skill com ⌘K.', size: 13)),
            final selected => SessionPanel(session: selected),
          },
        ),
      ],
    );
  }

  /// [routeId] (or, without one, the auto-selected id) among [candidates]; else the first pending of [mine].
  SessionSummary? _select(List<SessionSummary> candidates, List<SessionSummary> mine, String? routeId) {
    final selected =
        candidates.where((s) => s.id == (routeId ?? _autoSelected)).firstOrNull ??
        mine.where((s) => s.pendingPermissions > 0).firstOrNull ??
        mine.firstOrNull;
    if (routeId == null) _autoSelected = selected?.id;
    return selected;
  }
}

class _SessionList extends StatelessWidget {
  _SessionList.project({required Project? project, required this.mine, required this.others, required this.selected})
    : org = null,
      target = project == null ? null : ProjectTarget(project);

  const _SessionList.org({required String this.org, required this.target, required this.mine, required this.selected})
    : others = const [];

  /// `null` when nothing can be started: a project needs to be known, an org needs roots.
  final PaletteTarget? target;

  /// Set in an org's activities: [mine] are its org sessions.
  final String? org;

  final List<SessionSummary> mine;
  final List<SessionSummary> others;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget header(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 6), child: Muted(t, size: 10));
    return Container(
      width: 300,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          if (target != null || org != kNoOrg)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textPrimary,
                  side: BorderSide(color: c.borderStrong),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                onPressed: target == null ? null : () => showCommandPalette(context, target!, newConversation: true),
                icon: const Icon(Icons.add, size: 16),
                label: Text(org == null ? 'Nova conversa' : 'Nova atividade', style: const TextStyle(fontSize: 12)),
              ),
            ),
          header(org == null ? 'ESTE PROJETO' : 'ATIVIDADES DA ORG'),
          for (final s in mine)
            LiveSessionSummary(
              session: s,
              builder: (_, live) => _SessionTile(session: live, org: org, selected: live.id == selected),
            ),
          if (others.isNotEmpty) ...[
            header('OUTROS PROJETOS'),
            for (final s in others)
              LiveSessionSummary(
                session: s,
                builder: (_, live) => _SessionTile(session: live, selected: live.id == selected),
              ),
          ],
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, this.org, required this.selected});

  final SessionSummary session;

  /// Org the session resolved to, for org sessions; may differ from `session.org` after a rename.
  final String? org;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pending = session.pendingPermissions;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: selected ? c.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: c.hover,
          onTap: () => context.go(switch (org) {
            final org? => orgSessionsLocation(org, session: session.id),
            null => '/p/${session.project}/sessions/${session.id}',
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: statusColor(c, session.status), shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Tooltip(
                              message: session.command,
                              child: Text(
                                session.command,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: c.textMuted),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '· ${org ?? session.project} · ${_createdAt(session.createdAt)}',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: c.textMuted),
                            ),
                          ),
                        ],
                      ),
                      if (session.showsInterrupted)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            kInterruptedLabel,
                            key: ValueKey('session-interrupted-${session.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: c.warn),
                          ),
                        ),
                    ],
                  ),
                ),
                if (session.permissionMode == PermissionMode.bypassPermissions)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: Tooltip(
                      message: 'bypass: roda sem pedir confirmação',
                      child: Icon(
                        Icons.gpp_maybe_outlined,
                        key: ValueKey('session-bypass-${session.id}'),
                        size: 13,
                        color: c.fail.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                if (pending > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 6, top: 1),
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: c.warn, borderRadius: BorderRadius.circular(9)),
                    child: Text(
                      '$pending',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.canvas),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _createdAt(String iso) {
  final at = DateTime.tryParse(iso);
  return at == null ? '' : formatStartedAt(at, DateTime.now());
}
