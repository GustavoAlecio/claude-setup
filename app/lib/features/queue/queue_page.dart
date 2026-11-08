import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/engine_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primitives.dart';
import '../../data/attention.dart';
import '../../data/github_models.dart';
import '../../data/github_parser.dart';
import '../../data/github_repository.dart';
import '../../data/orgs.dart';
import '../../data/models.dart';
import '../../data/session_models.dart';
import '../../engine/engine_config.dart';

/// "Minha fila": every project of the org at once — what waits on the user, what is running, cycles in progress and
/// cycles ready — so nobody has to open project by project to know where to act.
class QueuePage extends StatefulWidget {
  const QueuePage({super.key, required this.org});

  final String org;

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  /// PRs of the org's projects with review comments waiting on the user, fetched once per (org, endpoint).
  List<(String project, PullRequest pr)> _prs = const [];
  Object? _loadedFor;

  Future<void> _loadPrs(Uri endpoint, List<Project> projects, DashboardConfig? config) async {
    final key = (widget.org, endpoint, projects.length);
    if (_loadedFor == key) return;
    _loadedFor = key;
    final github = GitHubScope.of(context);
    final account = githubFor(widget.org, config).account;
    final found = <(String, PullRequest)>[];
    await Future.wait([
      for (final p in projectsInOrg(projects, widget.org))
        if (!p.hidden)
          github
              .prs(p.name, account: account)
              .then(
                (prs) => found.addAll([
                  for (final pr in prs)
                    if (canResolve(pr)) (p.name, pr),
                ]),
              )
              .catchError(
                (Object e, StackTrace st) =>
                    log('cannot load PRs of ${p.name}', name: 'QueuePage', error: e, stackTrace: st),
              ),
    ]);
    if (mounted && _loadedFor == key) setState(() => _prs = found);
  }

  @override
  Widget build(BuildContext context) {
    final org = widget.org;
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final projects = context.watch<ProjectsCubit>().state.data ?? const <Project>[];
    final config = context.watch<ConfigCubit>().state.data;
    final endpoint = context.watch<EngineCubit>().state.data?.endpoint;
    if (endpoint != null && context.read<ProjectsCubit>().state.data != null) {
      unawaited(_loadPrs(endpoint, projects, config));
    }
    final queue = orgQueue(org, sessions, projects, config);
    final columns = [
      _Column(
        key: const ValueKey('queue-waiting'),
        title: 'Aguardando você',
        accent: true,
        empty: 'nada esperando por você',
        cards: [
          for (final item in queue.waiting) _WaitingCard(item),
          for (final (project, pr) in _prs) _PrCard(project, pr),
        ],
      ),
      _Column(
        key: const ValueKey('queue-running'),
        title: 'Rodando agora',
        empty: 'nenhum agente trabalhando',
        cards: [for (final s in queue.running) _RunningCard(s)],
      ),
      _Column(
        key: const ValueKey('queue-cycles'),
        title: 'Ciclos em andamento',
        empty: 'nenhum ciclo aberto',
        cards: [for (final p in queue.cycles) _CycleCard(p)],
      ),
      _Column(
        key: const ValueKey('queue-done'),
        title: 'Prontos',
        empty: 'nenhum ciclo concluído',
        cards: [for (final p in queue.done) _CycleCard(p, done: true)],
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final perRow = constraints.maxWidth >= 1100 ? 4 : 2;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            for (var i = 0; i < columns.length; i += perRow) ...[
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = i; j < i + perRow && j < columns.length; j++) ...[
                      if (j > i) const SizedBox(width: 14),
                      Expanded(child: columns[j]),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
          ],
        );
      },
    );
  }
}

class _Column extends StatelessWidget {
  const _Column({super.key, required this.title, required this.empty, required this.cards, this.accent = false});

  final String title;
  final String empty;
  final List<Widget> cards;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final highlight = accent && cards.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: highlight ? c.warn.withValues(alpha: 0.5) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: highlight ? c.warn : c.textPrimary,
                  ),
                ),
              ),
              Pill(label: '${cards.length}', color: highlight ? c.warn : c.idle, dot: false),
            ],
          ),
          const SizedBox(height: 10),
          if (cards.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Muted(empty, size: 12))
          else
            for (final card in cards) Padding(padding: const EdgeInsets.only(bottom: 8), child: card),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.onTap,
    required this.leading,
    required this.caption,
    required this.title,
    this.trailing,
  });

  final VoidCallback onTap;
  final Widget leading;
  final String caption;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.elevated,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: c.hover,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: leading),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(caption, style: TextStyle(fontSize: 11, color: c.textMuted)),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.textPrimary, height: 1.3),
                    ),
                    if (trailing case final trailing?) ...[const SizedBox(height: 6), trailing],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard(this.item);

  final AttentionItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final blocked = item.key.startsWith('blocked:');
    return _Card(
      onTap: () => context.go(item.route),
      leading: Icon(
        blocked ? Icons.report_outlined : Icons.front_hand_outlined,
        size: 16,
        color: blocked ? c.fail : c.warn,
      ),
      caption: item.title.replaceFirst(RegExp(r'^[^·]+· '), '') + (blocked ? ' · ciclo parado' : ' · decisão sua'),
      title: item.body,
    );
  }
}

class _RunningCard extends StatelessWidget {
  const _RunningCard(this.session);

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = session;
    return _Card(
      onTap: () => context.go(sessionRoute(s)),
      leading: Icon(Icons.play_circle_outline, size: 16, color: c.running),
      caption: s.isOrgSession ? '${s.org} · atividade da org' : s.project,
      title: s.title,
      trailing: s.model == null
          ? null
          : Text(
              s.model!,
              style: TextStyle(fontSize: 11, fontFamily: monoFamily, color: c.textSecondary),
            ),
    );
  }
}

class _CycleCard extends StatelessWidget {
  const _CycleCard(this.project, {this.done = false});

  final Project project;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cycle = project.cycle!;
    return _Card(
      onTap: () => context.go('/p/${project.name}/flow'),
      leading: Icon(
        done
            ? Icons.task_alt
            : cycle.paused
            ? Icons.pause_circle_outline
            : Icons.timelapse,
        size: 16,
        color: done
            ? c.pass
            : cycle.paused
            ? c.idle
            : c.accent,
      ),
      caption: [project.name, ?cycle.tracker].join(' · '),
      title: cycle.feature ?? project.name,
      trailing: Pill(
        label: done
            ? 'pronto para PR'
            : cycle.paused
            ? 'pausado em ${cycle.stage.label}'
            : 'etapa: ${cycle.stage.label}',
        color: done
            ? c.pass
            : cycle.paused
            ? c.idle
            : c.accent,
        dot: false,
      ),
    );
  }
}

class _PrCard extends StatelessWidget {
  const _PrCard(this.project, this.pr);

  final String project;
  final PullRequest pr;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _Card(
      key: ValueKey('queue-pr-$project-${pr.number}'),
      onTap: () => context.go('/p/$project/prs'),
      leading: Icon(Icons.forum_outlined, size: 16, color: c.accent),
      caption: '$project · PR #${pr.number ?? '?'} · ${countLabel(pr.unresolved.length, 'comentário')} esperando',
      title: pr.title.isEmpty ? '—' : pr.title,
    );
  }
}
