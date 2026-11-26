import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/engine_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/refresh_loop.dart';
import '../../core/widgets/session_launcher.dart';
import '../../data/docs_parser.dart';
import '../../data/docs_repository.dart';
import '../../data/docs_models.dart';
import '../../data/github_models.dart';
import '../../data/github_parser.dart';
import '../../data/github_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';
import '../../engine/engine_supervisor.dart';

const _logName = 'PrsPage';
const _refreshInterval = Duration(seconds: 60);

/// Waits for the config and the projects: the account comes from the org of [projectName].
class PrsPage extends StatelessWidget {
  const PrsPage({super.key, required this.projectName});

  final String projectName;

  @override
  Widget build(BuildContext context) {
    final config = context.select<ConfigCubit, DashboardConfig?>((c) => c.state.data);
    final projects = context.select<ProjectsCubit, List<Project>?>((c) => c.state.data);
    if (config == null || projects == null) return const SizedBox.shrink();
    final org = projects.where((p) => p.name == projectName).firstOrNull?.org;
    final account = githubFor(org, config).account;
    return _PrsView(key: ValueKey((projectName, account)), projectName: projectName, account: account);
  }
}

class _PrsView extends StatefulWidget {
  /// Keyed by `(projectName, account)`: a project or account switch disposes this state, so a late answer for
  /// the previous one lands on an unmounted state and is dropped.
  const _PrsView({super.key, required this.projectName, required this.account});

  final String projectName;

  /// `null`: the `gh` active account.
  final String? account;

  @override
  State<_PrsView> createState() => _PrsViewState();
}

class _ReviewRow {
  const _ReviewRow({required this.number, required this.title, required this.status, required this.text});

  final int number;
  final String title;
  final ReviewStatus status;
  final String text;
}

/// A row is only rebuilt when the report or the meta stamp changes.
class _ReviewMemo {
  const _ReviewMemo(this.report, this.meta, this.row);

  final DocEntry report;
  final DocEntry? meta;
  final _ReviewRow row;
}

typedef _ReadRow = ({_ReviewRow row, bool failed});

class _PrsViewState extends State<_PrsView> with SessionLauncher<_PrsView>, RefreshLoop<_PrsView> {
  List<PullRequest>? _prs;
  String? _error;
  bool _inFlight = false;
  Uri? _endpoint;
  bool _started = false;
  late final Timer _timer;
  final _expanded = <String>{};
  List<_ReviewRow>? _reviews;
  final _memo = <int, _ReviewMemo>{};

  /// Push identity of each checkout, by cwd; a cwd is asked once per view.
  final _identities = <String, SshIdentity>{};
  final _asked = <String>{};

  @override
  String get logName => _logName;

  bool get _hasEndpoint => _endpoint != null;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_refreshInterval, (_) => _reload());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    refresh();
    _onEngine(context.read<EngineCubit>().state);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _onEngine(AsyncSnapshot<EngineState> snapshot) {
    final next = snapshot.data?.endpoint;
    if (next == _endpoint) return;
    _endpoint = next;
    if (next != null) unawaited(_load());
  }

  @override
  Future<void> sync() async {
    final repository = DocsScope.of(context);
    final project = widget.projectName;
    final listing = await repository.list(project);
    final next = <int, _ReviewMemo>{};
    final rows = <int, _ReviewRow>{};
    for (final entry in listing.reviews) {
      final memo = _memo[entry.number];
      if (memo != null && memo.report == entry.report && memo.meta == entry.meta) {
        next[entry.number] = memo;
        rows[entry.number] = memo.row;
        continue;
      }
      final read = await _readRow(repository, project, entry);
      rows[entry.number] = read.row;
      // A failed read renders a placeholder row; memoizing it would keep the placeholder until the file changes.
      if (!read.failed) next[entry.number] = _ReviewMemo(entry.report, entry.meta, read.row);
    }
    if (!mounted) return;
    setState(() {
      _memo
        ..clear()
        ..addAll(next);
      _reviews = [for (final e in listing.reviews) rows[e.number]!];
    });
  }

  static String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s;

  static Future<_ReadRow> _readRow(DocsRepository repository, String project, ReviewEntry entry) async {
    final report = await repository.read(project, entry.report.rel);
    var failed = report.error != null;
    final line = reviewLine(report.text ?? '');
    var title = _nonEmpty(line.title);
    final metaEntry = entry.meta;
    if (title == null && metaEntry != null) {
      final meta = await repository.read(project, metaEntry.rel);
      if (meta.error != null) failed = true;
      if (meta case DocText(:final String text)) title = _nonEmpty(parseReviewMeta(text)?.title);
    }
    final row = _ReviewRow(
      number: entry.number,
      title: title ?? 'Review PR-${entry.number}',
      status: line.status,
      text: line.text,
    );
    return (row: row, failed: failed);
  }

  void _reload() {
    unawaited(_load());
    refresh();
  }

  Future<void> _load() async {
    if (_inFlight || !_hasEndpoint) return;
    _inFlight = true;
    final github = GitHubScope.of(context);
    try {
      final prs = await github.prs(widget.projectName, account: widget.account);
      if (!mounted) return;
      setState(() {
        _prs = prs;
        _error = null;
      });
      _checkIdentities(github, prs);
    } on Exception catch (e, st) {
      log('cannot load PRs', name: _logName, error: e, stackTrace: st);
      if (mounted) setState(() => _error = '$e');
    } finally {
      _inFlight = false;
    }
  }

  void _checkIdentities(GitHubRepository github, List<PullRequest> prs) {
    final projects = context.read<ProjectsCubit>().state.data ?? const <Project>[];
    for (final pr in prs) {
      final cwd = prCwd(pr, projects);
      if (cwd == null || !_asked.add(cwd)) continue;
      unawaited(_checkIdentity(github, cwd));
    }
  }

  Future<void> _checkIdentity(GitHubRepository github, String cwd) async {
    try {
      final identity = await github.sshIdentity(cwd: cwd);
      if (mounted) setState(() => _identities[cwd] = identity);
    } on GitHubException catch (e, st) {
      log('push identity unavailable for $cwd', name: _logName, error: e, stackTrace: st);
    }
  }

  /// One line per checkout whose push does not go out as [_PrsView.account]: https remotes and diverging SSH.
  List<(String, String)> _pushAlerts(List<PullRequest> prs, List<Project> projects) {
    final account = widget.account;
    final seen = <String>{};
    return [
      for (final pr in prs)
        if (prCwd(pr, projects) case final cwd? when seen.add(cwd))
          if (_identities[cwd] case final identity?)
            if (isHttpsRemote(identity))
              (
                'prs-https-$cwd',
                '${pr.repo ?? pr.nameWithOwner ?? cwd}: remote HTTPS: push usa o credential helper do git '
                    '(osxkeychain), não a conta ${account == null ? 'ativa do gh' : '@$account'}',
              )
            else if (sshDivergence(identity, account) case final alert?)
              ('prs-ssh-$cwd', alert),
    ];
  }

  static String _keyOf(PullRequest pr) => pr.url ?? '#${pr.number}';

  /// Siblings need distinct keys even when the engine hands over PRs without `url` (same or missing number).
  static ValueKey<String> _rowKey(PullRequest pr, int index) => ValueKey(pr.url ?? '#${pr.number}@$index');

  void _toggle(String key) => setState(() {
    if (!_expanded.remove(key)) _expanded.add(key);
  });

  @override
  Widget build(BuildContext context) {
    final projects = context.select<ProjectsCubit, List<Project>>((c) => c.state.data ?? const []);
    return BlocListener<EngineCubit, AsyncSnapshot<EngineState>>(
      listener: (_, snapshot) => _onEngine(snapshot),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(context, projects),
          Expanded(child: _body(context, projects)),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context, List<Project> projects) {
    final c = context.colors;
    final prs = _prs ?? const <PullRequest>[];
    final offline = prs.any((p) => !p.live);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _columnWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: offline
                          ? Pill(
                              key: const ValueKey('prs-offline'),
                              label: 'não consegui consultar o GitHub',
                              color: c.warn,
                            )
                          : null,
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Recarregar', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              for (final (key, alert) in _pushAlerts(prs, projects))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    alert,
                    key: ValueKey(key),
                    style: TextStyle(fontSize: 12, color: c.warn),
                  ),
                ),
              if (_error case final error?)
                ErrorRetryRow(error, onRetry: _hasEndpoint ? () => unawaited(_load()) : null),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<Project> projects) {
    final sections = [?_needsYouSection(context, projects), ?_mineSection(context), ?_reviewsSection(context)];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _columnWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, section) in sections.indexed) ...[if (i > 0) const SizedBox(height: 28), section],
            ],
          ),
        ),
      ),
    );
  }

  /// Each section is its own [Column]: a PR with comments shows in two of them under the same [_keyOf].
  Widget? _needsYouSection(BuildContext context, List<Project> projects) {
    final prs = (_prs ?? const <PullRequest>[]).where(canResolve).toList();
    if (prs.isEmpty) return null;
    return Column(
      key: const ValueKey('prs-needs-you'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle('Precisa de você', color: context.colors.warn),
        for (final (i, pr) in prs.indexed)
          Padding(
            key: _rowKey(pr, i),
            padding: const EdgeInsets.only(bottom: 8),
            child: _NeedsYou(
              pr: pr,
              cwd: prCwd(pr, projects),
              expanded: _expanded.contains(_keyOf(pr)),
              creating: isCreating(_keyOf(pr)),
              createError: createError(_keyOf(pr)),
              onToggle: () => _toggle(_keyOf(pr)),
              onResolve: (cwd) => unawaited(
                launchSession(
                  _keyOf(pr),
                  widget.projectName,
                  '/pr-status',
                  cwd: cwd,
                  githubAccount: widget.account,
                  permissionMode: launchOrg(cwd, projects, context.read<ConfigCubit>().state.data).mode,
                ),
              ),
              onLink: openLink,
            ),
          ),
      ],
    );
  }

  Widget? _mineSection(BuildContext context) {
    final prs = _prs;
    if (prs == null && _hasEndpoint) return null;
    final placeholder = switch (prs) {
      null => 'engine iniciando',
      [] => 'nenhum PR registrado; abra com /pr-open',
      _ => null,
    };
    final all = [for (final o in prs ?? const <PullRequest>[]) (o.repo, o.nameWithOwner)];
    final manyRepos = {for (final (_, nwo) in all) ?nwo?.toLowerCase()}.length > 1;
    final now = DateTime.now();
    return Column(
      key: const ValueKey('prs-mine'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (placeholder != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Muted(placeholder, size: 13)),
          )
        else ...[
          const _SectionTitle('Seus PRs'),
          for (final (i, pr) in prs!.indexed)
            _PrRow(
              key: _rowKey(pr, i),
              pr: pr,
              repoPrefix: manyRepos ? repoLabel(pr.repo, pr.nameWithOwner, all) : null,
              now: now,
              onLink: openLink,
            ),
        ],
      ],
    );
  }

  Widget? _reviewsSection(BuildContext context) {
    final reviews = _reviews ?? const <_ReviewRow>[];
    if (reviews.isEmpty && !refreshFailed) return null;
    final c = context.colors;
    return Column(
      key: const ValueKey('prs-reviews'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Revisões que você fez', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Muted('PRs de outras pessoas neste projeto', size: 12),
        ),
        if (refreshFailed)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Text(
              'não consegui ler as revisões',
              key: const ValueKey('prs-reviews-error'),
              style: TextStyle(fontSize: 12, color: c.warn),
            ),
          ),
        for (final r in reviews)
          _ReviewTile(row: r, onOpen: () => context.go(reviewLocation(widget.projectName, r.number))),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.color});

  final String title;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.row, required this.onOpen});

  final _ReviewRow row;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = switch (row.status) {
      ReviewStatus.draft => 'Ler e publicar',
      ReviewStatus.approved => 'Publicar',
      _ => null,
    };
    return InkWell(
      key: ValueKey('review-row-${row.number}'),
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: _wNumber,
              child: Text(
                '#${row.number}',
                style: TextStyle(
                  fontFamily: monoFamily,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  Text(row.text, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                ],
              ),
            ),
            if (label != null)
              OutlinedButton(
                key: ValueKey('review-open-${row.number}'),
                onPressed: onOpen,
                child: Text(label, style: const TextStyle(fontSize: 12)),
              )
            else
              Icon(Icons.chevron_right, size: 18, color: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

const _columnWidth = 720.0;
const _wNumber = 64.0;

Uri? _externalUri(PullRequest pr) {
  final uri = pr.url == null ? null : Uri.tryParse(pr.url!);
  return uri != null && opensExternally(uri) ? uri : null;
}

class _NeedsYou extends StatelessWidget {
  const _NeedsYou({
    required this.pr,
    required this.cwd,
    required this.expanded,
    required this.creating,
    required this.createError,
    required this.onToggle,
    required this.onResolve,
    required this.onLink,
  });

  final PullRequest pr;
  final String? cwd;
  final bool expanded;
  final bool creating;
  final String? createError;
  final VoidCallback onToggle;
  final void Function(String cwd) onResolve;
  final void Function(Uri) onLink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final threads = pr.unresolved.length;
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(prNeedsYouTitle(pr), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(prNeedsYouDetail(pr), style: TextStyle(fontSize: 13, color: c.textSecondary)),
            const SizedBox(height: 8),
            Row(
              children: [
                _resolve(),
                const SizedBox(width: 12),
                Expanded(
                  child: DisclosureToggle(
                    key: ValueKey('pr-comments-${pr.number}'),
                    open: expanded,
                    onTap: onToggle,
                    children: [
                      Flexible(
                        child: Text(
                          threads == 1 ? 'ver 1 comentário' : 'ver os $threads comentários',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: c.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (expanded)
              for (final t in pr.unresolved)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Mono(_threadHeader(t), size: 11.5),
                      const SizedBox(height: 4),
                      MarkdownView(t.body, onLink: onLink),
                    ],
                  ),
                ),
            if (createError case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
              ),
          ],
        ),
      ),
    );
  }

  static String _threadHeader(ReviewThread t) {
    final where = switch ((t.path, t.line)) {
      (final path?, final line?) => '$path:$line ',
      (final path?, null) => '$path ',
      _ => '',
    };
    return '$where@${t.author}';
  }

  Widget _resolve() {
    final cwd = this.cwd;
    final button = OutlinedButton(
      key: ValueKey('pr-resolve-${pr.number}'),
      onPressed: cwd == null || creating ? null : () => onResolve(cwd),
      child: const Text('Resolver', style: TextStyle(fontSize: 12)),
    );
    if (cwd != null) return button;
    return Tooltip(message: 'sem checkout local de ${pr.repo ?? pr.nameWithOwner ?? '?'}', child: button);
  }
}

class _PrRow extends StatelessWidget {
  const _PrRow({super.key, required this.pr, required this.repoPrefix, required this.now, required this.onLink});

  final PullRequest pr;

  /// `repoLabel` of the PR when the list spans more than one repo; `—` means no usable name.
  final String? repoPrefix;
  final DateTime now;
  final void Function(Uri) onLink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final uri = _externalUri(pr);
    return InkWell(
      key: ValueKey('pr-row-${pr.number}'),
      onTap: uri == null ? null : () => onLink(uri),
      hoverColor: c.hover,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            SizedBox(width: _wNumber, child: _number(c, uri)),
            if (pr.card case final card?) ...[
              Pill(label: card.label, color: c.accent, mono: true, dot: false),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pr.title.isEmpty ? '—' : pr.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  _state(c),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _number(AppColors c, Uri? uri) {
    final label = pr.number == null ? '—' : '#${pr.number}';
    const style = TextStyle(fontFamily: monoFamily, fontSize: 12.5, fontWeight: FontWeight.w600);
    if (uri == null) return Text(label, style: style.copyWith(color: c.textSecondary));
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        key: ValueKey('pr-link-${pr.number}'),
        onTap: () => onLink(uri),
        child: Text(label, style: style.copyWith(color: c.accent)),
      ),
    );
  }

  Widget _state(AppColors c) {
    final line = prStateLine(pr, now);
    final prefix = repoPrefix;
    final text = Text(
      prefix == null || prefix == '—' ? line.text : '$prefix · ${line.text}',
      key: ValueKey('pr-state-${pr.number}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        color: switch (line.tone) {
          PrTone.attention => c.warn,
          PrTone.normal => c.textSecondary,
          PrTone.done => c.textMuted,
        },
      ),
    );
    return pr.live ? text : Tooltip(message: pr.liveError ?? 'sem dados do GitHub', child: text);
  }
}
