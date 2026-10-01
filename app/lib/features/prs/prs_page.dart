import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/config_cubit.dart';
import '../../app/engine_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/session_launcher.dart';
import '../../data/docs_repository.dart';
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

class _PrsViewState extends State<_PrsView> with SessionLauncher {
  List<PullRequest>? _prs;
  String? _error;
  bool _inFlight = false;
  Uri? _endpoint;
  bool _started = false;
  late final Timer _timer;
  final _expanded = <String>{};

  /// Push identity of each checkout, by cwd; a cwd is asked once per view.
  final _identities = <String, SshIdentity>{};
  final _asked = <String>{};

  @override
  String get logName => _logName;

  bool get _hasEndpoint => _endpoint != null;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_refreshInterval, (_) => unawaited(_load()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
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
    final waiting = prs.where(canResolve).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (offline)
                      Pill(key: const ValueKey('prs-offline'), label: 'não consegui consultar o GitHub', color: c.warn),
                    if (waiting > 0)
                      Pill(
                        key: const ValueKey('prs-waiting'),
                        label: '$waiting PR(s) com comentários esperando você',
                        color: c.accent,
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                onPressed: _hasEndpoint ? () => unawaited(_load()) : null,
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
          if (_error case final error?) ErrorRetryRow(error, onRetry: _hasEndpoint ? () => unawaited(_load()) : null),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, List<Project> projects) {
    final prs = _prs;
    if (prs == null) {
      if (!_hasEndpoint) return const Center(child: Muted('engine iniciando', size: 13));
      return const SizedBox.shrink();
    }
    if (prs.isEmpty) return const Center(child: Muted('nenhum PR registrado; abra com /pr-open', size: 13));
    final now = DateTime.now();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        const TableHeaderRow([
          ('#PR', _wNumber),
          ('Título', null),
          ('Repo', _wRepo),
          ('Target', _wTarget),
          ('Stage', _wStage),
          ('CI', _wCi),
          ('Atualizado', _wUpdated),
          ('', _wAction),
        ]),
        for (final pr in prs)
          _PrRow(
            pr: pr,
            repoLabel: repoLabel(pr.repo, pr.nameWithOwner, [for (final o in prs) (o.repo, o.nameWithOwner)]),
            cwd: prCwd(pr, projects),
            now: now,
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
      ],
    );
  }
}

const _wNumber = 64.0;
const _wRepo = 170.0;
const _wTarget = 110.0;
const _wStage = 200.0;
const _wCi = 90.0;
const _wUpdated = 100.0;
const _wAction = 110.0;

class _PrRow extends StatelessWidget {
  const _PrRow({
    required this.pr,
    required this.repoLabel,
    required this.cwd,
    required this.now,
    required this.expanded,
    required this.creating,
    required this.createError,
    required this.onToggle,
    required this.onResolve,
    required this.onLink,
  });

  final PullRequest pr;
  final String repoLabel;
  final String? cwd;
  final DateTime now;
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
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: _wNumber, child: _number(c)),
              Expanded(
                child: Row(
                  children: [
                    if (pr.adoId case final ado?) ...[
                      Pill(label: 'AB#$ado', color: c.accent, mono: true, dot: false),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        pr.title.isEmpty ? '—' : pr.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: _wRepo, child: Mono(repoLabel)),
              SizedBox(width: _wTarget, child: Mono(pr.target ?? '—')),
              SizedBox(width: _wStage, child: _stage(c)),
              SizedBox(width: _wCi, child: _checks(c)),
              SizedBox(width: _wUpdated, child: Muted(relativeAge(pr.mergedAt ?? pr.updatedAt ?? pr.openedAt, now))),
              SizedBox(width: _wAction, child: _action(c)),
            ],
          ),
          if (threads > 0)
            Padding(
              padding: const EdgeInsets.only(left: _wNumber, top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: onToggle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${expanded ? '▾' : '▸'} $threads comentário(s)',
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                  ),
                ),
              ),
            ),
          if (expanded)
            for (final t in pr.unresolved)
              Padding(
                padding: const EdgeInsets.only(left: _wNumber + 12, top: 8),
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
              padding: const EdgeInsets.only(left: _wNumber, top: 6),
              child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
            ),
        ],
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

  Widget _number(AppColors c) {
    final label = pr.number == null ? '—' : '#${pr.number}';
    final uri = pr.url == null ? null : Uri.tryParse(pr.url!);
    const style = TextStyle(fontFamily: monoFamily, fontSize: 12.5, fontWeight: FontWeight.w600);
    if (uri == null || !opensExternally(uri)) return Text(label, style: style.copyWith(color: c.textSecondary));
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        key: ValueKey('pr-link-${pr.number}'),
        onTap: () => onLink(uri),
        child: Text(label, style: style.copyWith(color: c.accent)),
      ),
    );
  }

  Widget _stage(AppColors c) {
    final color = switch (stageColorRole(pr.stage)) {
      StageColorRole.accent => c.accent,
      StageColorRole.warn => c.warn,
      StageColorRole.pass => c.pass,
      StageColorRole.idle => c.idle,
    };
    return Row(
      children: [
        Flexible(
          child: Pill(label: stageLabel(pr.stage), color: color),
        ),
        if (!pr.live) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: pr.liveError ?? 'sem dados do GitHub',
            child: Pill(label: 'cache', color: c.idle, dot: false),
          ),
        ],
      ],
    );
  }

  Widget _checks(AppColors c) => switch (pr.checks) {
    PrChecks.failing => Pill(label: 'falhando', color: c.fail),
    PrChecks.pending => Pill(label: 'pendente', color: c.running),
    PrChecks.passing => Pill(label: 'ok', color: c.pass),
    null => const Muted('—'),
  };

  Widget _action(AppColors c) {
    if (!canResolve(pr)) return const SizedBox.shrink();
    final cwd = this.cwd;
    final button = OutlinedButton(
      key: ValueKey('pr-resolve-${pr.number}'),
      onPressed: cwd == null || creating ? null : () => onResolve(cwd),
      child: const Text('Resolver', style: TextStyle(fontSize: 12)),
    );
    if (cwd != null) return Align(alignment: Alignment.centerLeft, child: button);
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(message: 'sem checkout local de ${pr.repo ?? pr.nameWithOwner ?? '?'}', child: button),
    );
  }
}
