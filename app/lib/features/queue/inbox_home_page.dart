import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/engine_cubit.dart';
import '../../app/inbox_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/attention.dart';
import '../../data/github_models.dart';
import '../../data/github_parser.dart';
import '../../data/github_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_models.dart';
import '../../engine/engine_config.dart';

const _logName = 'InboxHomePage';

/// Most review rows shown before "ver os N".
const _maxReviewRows = 5;

typedef _PrKey = (String org, Uri endpoint, int projects);

/// "Caixa de entrada": first and almost only what waits on the user in the org, one action per line; PRs of other
/// people to review below, and what is just happening reduced to a line of counts.
class InboxHomePage extends StatefulWidget {
  const InboxHomePage({super.key, required this.org});

  final String org;

  @override
  State<InboxHomePage> createState() => _InboxHomePageState();
}

class _InboxHomePageState extends State<InboxHomePage> {
  _PrKey? _requested;

  /// PRs with review comments waiting, with the key they were loaded for: the page state survives an org switch
  /// (the route's page key is the `/o/:org/fila` template), so another org's PRs must never be shown.
  ({_PrKey key, List<(String, PullRequest)> prs})? _loaded;

  Future<void> _loadPrs(Uri endpoint, List<Project> projects, DashboardConfig? config) async {
    final key = (widget.org, endpoint, projects.length);
    if (_requested == key) return;
    _requested = key;
    if (_loaded?.key != key) _loaded = null;
    final github = GitHubScope.of(context);
    final account = githubFor(widget.org, config).account;
    final perProject = await Future.wait([
      for (final p in projectsInOrg(projects, widget.org))
        if (!p.hidden)
          github
              .prs(p.name, account: account)
              .then<List<(String, PullRequest)>>(
                (prs) => [
                  for (final pr in prs)
                    if (canResolve(pr)) (p.name, pr),
                ],
              )
              .catchError((Object e, StackTrace st) {
                log('cannot load PRs of ${p.name}', name: _logName, error: e, stackTrace: st);
                return const <(String, PullRequest)>[];
              }),
    ]);
    if (mounted && _requested == key) setState(() => _loaded = (key: key, prs: [for (final l in perProject) ...l]));
  }

  @override
  Widget build(BuildContext context) {
    final org = widget.org;
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final projects = context.watch<ProjectsCubit>().state.data ?? const <Project>[];
    final config = context.watch<ConfigCubit>().state.data;
    final endpoint = context.watch<EngineCubit>().state.data?.endpoint;
    final reviews = context.watch<InboxCubit>().state.itemsFor(githubFor(org, config));
    if (endpoint != null && context.read<ProjectsCubit>().state.data != null) {
      unawaited(_loadPrs(endpoint, projects, config));
    }
    final prs = switch (_loaded) {
      (key: final key, :final prs) when key.$1 == org => prs,
      _ => const <(String, PullRequest)>[],
    };
    final queue = orgQueue(org, sessions, projects, config);
    final rows = inboxRows(org, queue.waiting, prs, projects);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Waiting(rows),
                if (reviews.isNotEmpty) ...[const SizedBox(height: 28), _Review(org, reviews)],
                if (queue.running.isNotEmpty || queue.cycles.isNotEmpty || queue.done.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  _Footer(org, queue),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.color, this.trailing});

  final String title;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: color ?? context.colors.textPrimary),
        ),
        if (trailing case final trailing?) ...[const SizedBox(width: 10), trailing],
      ],
    ),
  );
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.rows);

  final List<InboxRow> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      key: const ValueKey('inbox-waiting'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          'Precisa de você',
          color: c.warn,
          trailing: Pill(label: '${rows.length}', color: c.warn, dot: false),
        ),
        if (rows.isEmpty)
          Padding(
            key: const ValueKey('inbox-empty'),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('Nada precisa de você agora.', style: TextStyle(fontSize: 13, color: c.textSecondary)),
          )
        else
          for (final (i, row) in rows.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _WaitingRow(index: i, row: row),
            ),
      ],
    );
  }
}

class _WaitingRow extends StatelessWidget {
  const _WaitingRow({required this.index, required this.row});

  final int index;
  final InboxRow row;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    void open() => context.go(row.route);
    final label = Text(row.action, style: const TextStyle(fontSize: 13));
    final actionKey = ValueKey('inbox-row-$index-action');
    return Material(
      key: ValueKey('inbox-row-$index'),
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        hoverColor: c.hover,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.context,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textPrimary),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      row.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.textSecondary, height: 1.3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (index == 0)
                FilledButton(key: actionKey, onPressed: open, child: label)
              else
                OutlinedButton(key: actionKey, onPressed: open, child: label),
            ],
          ),
        ),
      ),
    );
  }
}

class _Review extends StatelessWidget {
  const _Review(this.org, this.items);

  final String org;
  final List<InboxItem> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final now = DateTime.now();
    final all = [for (final o in items) (o.repo, o.nameWithOwner)];
    void open() => context.go(orgInboxLocation(org));
    return Column(
      key: const ValueKey('inbox-home-review'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          'Para revisar',
          trailing: Text('PRs de outras pessoas', style: TextStyle(fontSize: 12, color: c.textMuted)),
        ),
        for (final (i, item) in items.take(_maxReviewRows).indexed)
          InkWell(
            key: ValueKey('inbox-home-review-$i'),
            onTap: open,
            hoverColor: c.hover,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  SizedBox(width: 56, child: Mono('#${item.number}', color: c.textSecondary)),
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      '${repoLabel(item.repo, item.nameWithOwner, all)} · ${relativeAge(item.updatedAt, now)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (items.length > _maxReviewRows)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('inbox-home-review-more'),
              onPressed: open,
              child: Text('ver os ${items.length}', style: const TextStyle(fontSize: 12)),
            ),
          ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer(this.org, this.queue);

  final String org;
  final OrgQueue queue;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = TextStyle(fontSize: 12, color: c.textSecondary);
    return Wrap(
      key: const ValueKey('inbox-home-footer'),
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (queue.running.isNotEmpty)
          TextButton(
            key: const ValueKey('inbox-home-footer-running'),
            style: TextButton.styleFrom(foregroundColor: c.textSecondary),
            onPressed: () => context.go(orgSessionsLocation(org)),
            child: Text('${countLabel(queue.running.length, 'agente')} rodando', style: style),
          ),
        if (queue.cycles.isNotEmpty)
          _ProjectsMenu(
            id: 'inbox-home-footer-cycles',
            label: '${countLabel(queue.cycles.length, 'ciclo')} em andamento',
            projects: queue.cycles,
          ),
        if (queue.done.isNotEmpty)
          _ProjectsMenu(
            id: 'inbox-home-footer-done',
            label: '${countLabel(queue.done.length, 'pronto')} para PR',
            projects: queue.done,
          ),
      ],
    );
  }
}

String _projectLabel(Project p) {
  final feature = p.cycle?.feature;
  return feature == null || feature.isEmpty ? p.name : '${p.name} · $feature';
}

/// A footer count that always opens a menu, even with one project, so the count reads the same at any size.
class _ProjectsMenu extends StatelessWidget {
  const _ProjectsMenu({required this.id, required this.label, required this.projects});

  final String id;
  final String label;
  final List<Project> projects;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopupMenuButton<String>(
      key: ValueKey(id),
      tooltip: '',
      color: c.elevated,
      position: PopupMenuPosition.under,
      onSelected: (project) => context.go('/p/$project/flow'),
      itemBuilder: (_) => [
        for (final p in projects)
          PopupMenuItem(
            key: ValueKey('$id-${p.name}'),
            value: p.name,
            height: 36,
            child: Text(_projectLabel(p), style: const TextStyle(fontSize: 13)),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: c.textSecondary)),
            Icon(Icons.arrow_drop_down, size: 16, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}
