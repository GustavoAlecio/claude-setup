import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../data/budget.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/github_models.dart';
import '../../data/github_parser.dart';
import '../../data/github_repository.dart';
import '../../data/orgs.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';
import 'budget_field.dart';

const _kSshTimeout = Duration(seconds: 10);

/// How often and for how long the form re-checks an account after opening the login in Terminal.
const _kLoginPoll = Duration(seconds: 3);
const _kLoginWait = Duration(minutes: 5);

/// State of the `ssh -T` check of one owner; `null` identity means it could not be verified.
class _Ssh {
  const _Ssh.pending() : pending = true, identity = null;
  const _Ssh.done(this.identity) : pending = false;
  const _Ssh.failed() : pending = false, identity = null;

  final bool pending;
  final SshIdentity? identity;
}

/// Name + folders of one org, validated against [others] before [onSave]. Shared by the landing's
/// "Criar org" (`maxRoots: 1`, with [suggestions]) and each org in Configurações. The GitHub section edits
/// `OrgConfig.github` (account, owners) and blocks saving while an owner's SSH identity contradicts the account.
class OrgForm extends StatefulWidget {
  const OrgForm({
    super.key,
    this.initial,
    this.others = const [],
    this.maxRoots,
    this.suggestions = const [],
    this.saveLabel = 'Salvar',
    required this.onSave,
    this.onRemove,
    this.onDirtyChanged,
    this.simple = false,
    this.globalMode = kDefaultPermissionMode,
    this.globalBudget,
  });

  final OrgConfig? initial;

  /// The other orgs as they will be saved: name uniqueness and root overlap are checked against them.
  final List<OrgConfig> others;

  /// `null` allows any number of folders; at the limit, picking replaces the last one.
  final int? maxRoots;

  /// Folders offered as one-click starting points; picking one fills both name and folder.
  final List<String> suggestions;
  final String saveLabel;

  /// Throws [ConfigWriteException] when the write is rejected; the message is shown inline.
  final Future<void> Function(OrgConfig org) onSave;
  final Future<void> Function()? onRemove;

  /// First use: only name and folder up front; permissions, agent and GitHub fold into "Opções avançadas" with their
  /// defaults spelled out, so the first decision is not about things the user cannot judge yet.
  final bool simple;

  /// What "herdar global" resolves to, shown in the option.
  /// What an empty budget inherits; `null` when there is no global budget either.
  final double? globalBudget;

  final PermissionMode globalMode;

  /// Whether the form differs from [initial] (or, for a new org, has anything typed), on every change.
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<OrgForm> createState() => _OrgFormState();
}

class _OrgFormState extends State<OrgForm> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late List<String> _roots = [...?widget.initial?.roots];
  final _ownerInput = TextEditingController();
  late String? _account = widget.initial?.github?.account;
  late List<String> _owners = [...?widget.initial?.github?.owners];
  late PermissionMode? _permissionMode = widget.initial?.permissionMode;
  bool _githubTouched = false;
  late AgentProvider _provider = widget.initial?.agent?.provider ?? AgentProvider.anthropic;
  late final _agentAccount = TextEditingController(text: widget.initial?.agent?.account ?? '');
  late final _budget = TextEditingController(text: budgetText(widget.initial?.cycleBudget));
  late String? _agentModel = widget.initial?.agent?.model;
  late TrackerKind? _trackerKind = widget.initial?.tracker?.kind;
  late final _trackerOrg = TextEditingController(text: widget.initial?.tracker?.org ?? '');
  late final _trackerProject = TextEditingController(text: widget.initial?.tracker?.project ?? '');
  late final _trackerSite = TextEditingController(text: widget.initial?.tracker?.site ?? '');
  late final _trackerEmail = TextEditingController(text: widget.initial?.tracker?.email ?? '');
  late final _trackerTeam = TextEditingController(text: widget.initial?.tracker?.team ?? '');
  late final _trackerWorkspace = TextEditingController(text: widget.initial?.tracker?.workspace ?? '');
  late bool _releaseBase = widget.initial?.tracker?.releaseBase ?? false;
  bool _agentTouched = false;
  int _agentGeneration = 0;
  AgentAccountStatus? _agentStatus;
  List<AgentModel>? _agentModels;
  String? _agentError;
  bool _loggingIn = false;

  /// Bumped by "Cancelar": a login wait from before stops polling.
  int _loginRun = 0;
  String? _loginNote;
  String? _error;
  String? _nameError;
  String? _rootsError;
  String? _ownerError;
  bool _busy = false;

  late GitHubRepository _github;
  late SessionsRepository _sessions;
  bool _githubStarted = false;
  int _generation = 0;
  int _suggestionsGeneration = 0;
  List<GithubAccount>? _accounts;
  List<String> _suggested = const [];
  String? _githubError;
  String? _protocol;
  final _ssh = <String, _Ssh>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _github = GitHubScope.of(context);
    _sessions = SessionsScope.of(context);
    if (_githubStarted) return;
    _githubStarted = true;
    if (_provider == AgentProvider.antigravity) unawaited(_loadAgent());
    unawaited(_loadGithub());
    for (final owner in _owners) {
      unawaited(_verify(owner));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _ownerInput.dispose();
    _agentAccount.dispose();
    _budget.dispose();
    for (final c in [_trackerOrg, _trackerProject, _trackerSite, _trackerEmail, _trackerTeam, _trackerWorkspace]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadGithub() async {
    final generation = ++_generation;
    setState(() => _githubError = null);
    await Future.wait([
      _guard(generation, () async {
        final accounts = await _github.accounts();
        if (mounted && generation == _generation) setState(() => _accounts = accounts);
      }, 'accounts'),
      _guard(generation, () async {
        final protocol = await _github.protocol();
        if (mounted && generation == _generation) setState(() => _protocol = protocol);
      }, 'protocol'),
      _loadSuggestions(),
    ]);
  }

  Future<void> _guard(int generation, Future<void> Function() body, String what) async {
    try {
      await body();
    } on GitHubException catch (e, st) {
      log('github $what failed', name: 'OrgForm', error: e, stackTrace: st);
      if (mounted && generation == _generation) setState(() => _githubError = e.message);
    }
  }

  Future<void> _loadSuggestions() async {
    final generation = ++_suggestionsGeneration;
    try {
      final suggested = await _github.orgs(_account);
      if (mounted && generation == _suggestionsGeneration) setState(() => _suggested = suggested);
    } on GitHubException catch (e, st) {
      log('github orgs failed', name: 'OrgForm', error: e, stackTrace: st);
      if (mounted && generation == _suggestionsGeneration) setState(() => _suggested = const []);
    }
  }

  Future<void> _verify(String owner) async {
    final key = owner.toLowerCase();
    setState(() => _ssh[key] = const _Ssh.pending());
    _Ssh result;
    try {
      result = _Ssh.done(await _github.sshIdentity(owner: owner, fresh: true).timeout(_kSshTimeout));
    } on Exception catch (e, st) {
      log('ssh identity unavailable', name: 'OrgForm', error: e, stackTrace: st);
      result = const _Ssh.failed();
    }
    if (mounted && _owners.any((o) => o.toLowerCase() == key)) setState(() => _ssh[key] = result);
  }

  String get _accountName {
    final text = _agentAccount.text.trim();
    return text.isEmpty ? kDefaultAgentAccount : text;
  }

  /// Login state and models of the typed account; a stale answer (account changed meanwhile) is dropped.
  Future<void> _loadAgent() async {
    final account = _accountName;
    final generation = ++_agentGeneration;
    setState(() {
      _agentError = kAgentAccount.hasMatch(account) ? null : 'conta inválida: letras, números, ".", "_" ou "-"';
      _agentStatus = null;
      _agentModels = null;
    });
    if (_agentError != null) return;
    try {
      final status = await _sessions.agentAccount(account);
      if (!mounted || generation != _agentGeneration) return;
      setState(() => _agentStatus = status);
      if (!status.loggedIn) return;
      final models = await _sessions.agentModels(account);
      if (mounted && generation == _agentGeneration) setState(() => _agentModels = models);
    } on SessionsException catch (e, st) {
      log('agent account unavailable', name: 'OrgForm', error: e, stackTrace: st);
      if (mounted && generation == _agentGeneration) setState(() => _agentError = e.message);
    }
  }

  /// Opens Terminal on the account, then polls until it is logged in, the account changes or [_kLoginWait] passes.
  Future<void> _login() async {
    final account = _accountName;
    final generation = _agentGeneration;
    final run = ++_loginRun;
    bool current() => mounted && generation == _agentGeneration && run == _loginRun;
    setState(() {
      _loggingIn = true;
      _agentError = null;
      _loginNote = null;
    });
    try {
      await _sessions.agentLogin(account);
      final deadline = DateTime.now().add(_kLoginWait);
      while (current() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_kLoginPoll);
        if (!current()) return;
        final status = await _sessions.agentAccount(account);
        if (status.loggedIn) {
          await _loadAgent();
          return;
        }
      }
      if (current()) {
        setState(() => _loginNote = 'não detectamos o login em 5 min: tente de novo ou rode o comando abaixo');
      }
    } on SessionsException catch (e, st) {
      log('agent login failed', name: 'OrgForm', error: e, stackTrace: st);
      if (current()) setState(() => _agentError = e.message);
    } finally {
      if (mounted && run == _loginRun) setState(() => _loggingIn = false);
    }
  }

  void _cancelLogin() => setState(() {
    _loginRun++;
    _loggingIn = false;
  });

  void _setProvider(AgentProvider? provider) {
    if (provider == null) return;
    setState(() {
      _agentTouched = true;
      _provider = provider;
      _error = null;
    });
    if (provider == AgentProvider.antigravity) unawaited(_loadAgent());
  }

  OrgAgent? get _agentDraft {
    if (!_agentTouched) return widget.initial?.agent;
    if (_provider == AgentProvider.anthropic) return OrgAgent.anthropic;
    final account = _agentAccount.text.trim();
    return OrgAgent(provider: _provider, account: account.isEmpty ? null : account, model: _agentModel);
  }

  /// Only the fields of the chosen kind: switching kinds leaves the other kind's text out of the save.
  OrgTracker? get _trackerDraft {
    final kind = _trackerKind;
    if (kind == null) return null;
    String? text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    String? key(TextEditingController c) => text(c)?.toUpperCase();
    return switch (kind) {
      TrackerKind.ado => OrgTracker(
        kind: kind,
        org: text(_trackerOrg),
        project: text(_trackerProject),
        releaseBase: _releaseBase,
      ),
      TrackerKind.jira => OrgTracker(
        kind: kind,
        site: text(_trackerSite)?.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/+$'), ''),
        project: key(_trackerProject),
        email: text(_trackerEmail),
        releaseBase: _releaseBase,
      ),
      TrackerKind.linear => OrgTracker(
        kind: kind,
        team: key(_trackerTeam),
        workspace: text(_trackerWorkspace),
        releaseBase: _releaseBase,
      ),
    };
  }

  bool? _notifiedDirty;
  bool _advanced = false;

  /// The draft differs from what is saved: what Salvar would write is not what the file has.
  bool get _dirty {
    final initial = widget.initial;
    if (initial == null) return _name.text.trim().isNotEmpty || _roots.isNotEmpty;
    final github = _githubTouched ? OrgGithub(account: _account, owners: _owners) : initial.github;
    return _name.text.trim() != initial.name ||
        !sameStrings(_roots, initial.roots) ||
        github != initial.github ||
        _permissionMode != initial.permissionMode ||
        _agentDraft != initial.agent ||
        _trackerDraft != initial.tracker ||
        parseBudgetInput(_budget.text) != initial.cycleBudget;
  }

  /// After the frame: the parent rebuilds its own guards from this.
  void _notifyDirty(bool dirty) {
    if (dirty == _notifiedDirty || widget.onDirtyChanged == null) return;
    _notifiedDirty = dirty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDirtyChanged!(dirty);
    });
  }

  bool _diverges(SshIdentity? identity) => identity != null && sshDivergence(identity, _account) != null;

  /// The GitHub part differs from what is saved. A divergence that is already saved is a warning, not a block:
  /// otherwise a permission change would be stuck behind it.
  bool get _githubChanged => _githubTouched && OrgGithub(account: _account, owners: _owners) != widget.initial?.github;

  bool get _blocked => _blockReason != null;

  /// Why Salvar is off, shown beside it: an SSH check still running or an SSH identity that contradicts the account.
  String? get _blockReason {
    if (!_githubChanged) return null;
    for (final owner in _owners) {
      final ssh = _ssh[owner.toLowerCase()];
      if (ssh == null) continue;
      if (ssh.pending) return 'verificando o SSH de $owner…';
      if (ssh.identity case final identity? when _diverges(identity)) {
        return '${sshDivergence(identity, _account)}. Remova $owner ou ajuste o ~/.ssh/config para salvar.';
      }
    }
    return null;
  }

  void _setAccount(String? account) {
    setState(() {
      _githubTouched = true;
      _account = account;
      _error = null;
    });
    unawaited(_loadSuggestions());
  }

  void _addOwner(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    final canonical = _suggested.where((s) => s.toLowerCase() == text.toLowerCase()).firstOrNull ?? text;
    final error = validateOwners([..._owners, canonical]);
    if (error != null) {
      setState(() => _ownerError = error);
      return;
    }
    _ownerInput.clear();
    setState(() {
      _githubTouched = true;
      _ownerError = null;
      _error = null;
      _owners = [..._owners, canonical];
    });
    unawaited(_verify(canonical));
  }

  void _removeOwner(String owner) => setState(() {
    _githubTouched = true;
    _owners = [..._owners]..remove(owner);
    _ssh.remove(owner.toLowerCase());
    _error = null;
  });

  Future<void> _verifyAll() async {
    await Future.wait([for (final owner in _owners) _verify(owner)]);
  }

  bool get _full => widget.maxRoots != null && _roots.length >= widget.maxRoots!;

  void _addRoot(String path) {
    final root = normalizePath(path);
    // The folder name is the usual org name: fill it when the user has not typed one.
    if (_name.text.trim().isEmpty) _name.text = root.split('/').last;
    setState(() {
      _error = null;
      _nameError = null;
      _rootsError = null;
      if (_roots.contains(root)) return;
      _roots = _full ? [..._roots.sublist(0, _roots.length - 1), root] : [..._roots, root];
    });
  }

  Future<void> _pick() async {
    final path = await RepositoryScope.pickerOf(context)();
    if (path != null && mounted) _addRoot(path);
  }

  void _suggest(String path) {
    final root = normalizePath(path);
    _name.text = root.split('/').last;
    setState(() {
      _error = null;
      _roots = [root];
    });
  }

  Future<void> _save() async {
    if (_busy || _blocked) return;
    final github = _githubTouched ? OrgGithub(account: _account, owners: _owners) : widget.initial?.github;
    final draft = OrgConfig(
      name: _name.text.trim(),
      roots: _roots,
      github: github,
      permissionMode: _permissionMode,
      agent: _agentDraft,
      cycleBudget: parseBudgetInput(_budget.text),
      tracker: _trackerDraft,
    );
    final agentAccount = draft.agent?.account;
    // Both missing fields at once, each under its own field, name first.
    final nameError = draft.name.isEmpty ? 'informe um nome para a org' : null;
    final rootsError = _roots.isEmpty ? 'escolha uma pasta para a org' : null;
    final error = nameError != null || rootsError != null
        ? null
        : agentAccount != null && !kAgentAccount.hasMatch(agentAccount)
        ? 'conta do Antigravity inválida'
        : draft.cycleBudget?.isNaN ?? false
        ? 'orçamento inválido: use um valor positivo'
        : draft.tracker?.missing ?? validateOrgs([...widget.others, draft]);
    if (nameError != null || rootsError != null || error != null) {
      setState(() {
        _nameError = nameError;
        _rootsError = rootsError;
        _error = error;
      });
      return;
    }
    await _run(() async {
      await _verifyAll();
      if (!mounted || _blocked) return;
      await widget.onSave(draft);
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ConfigWriteException catch (e, st) {
      log('org write rejected', name: 'OrgForm', error: e, stackTrace: st);
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _githubSection(AppColors c) {
    final accounts = _accounts;
    final known = {for (final a in accounts ?? const <GithubAccount>[]) a.login};
    final account = _account;
    final selected = accounts?.where((a) => a.login == account).firstOrNull;
    final note = account == null
        ? null
        : accounts == null
        ? null
        : selected == null
        ? 'não logada'
        : selected.valid
        ? null
        : 'token inválido ou sem rede';
    final addable = [
      for (final s in _suggested)
        if (!_owners.any((o) => o.toLowerCase() == s.toLowerCase())) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Muted('GitHub', size: 11)),
            IconButton(
              key: const ValueKey('org-github-reload'),
              tooltip: 'Recarregar contas',
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              onPressed: _loadGithub,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_githubError != null) Text(_githubError!, style: TextStyle(fontSize: 12, color: c.warn)),
        const SizedBox(height: 6),
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Conta do gh', isDense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              key: const ValueKey('org-github-account'),
              isDense: true,
              isExpanded: true,
              value: account,
              style: TextStyle(fontSize: 13, color: c.textPrimary),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('conta ativa do gh')),
                for (final a in accounts ?? const <GithubAccount>[])
                  DropdownMenuItem<String?>(value: a.login, child: Text(a.login)),
                if (account != null && !known.contains(account))
                  DropdownMenuItem<String?>(value: account, child: Text(account)),
              ],
              onChanged: _busy ? null : _setAccount,
            ),
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(note, style: TextStyle(fontSize: 12, color: c.warn)),
          ),
        const SizedBox(height: 10),
        const Muted('Orgs do GitHub', size: 11),
        const SizedBox(height: 6),
        if (_owners.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Muted('nenhuma: PRs e "Para revisar" mostram todas as orgs da conta', size: 12),
          ),
        if (_owners.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final owner in _owners)
                InputChip(
                  label: Text(owner, style: const TextStyle(fontSize: 12)),
                  deleteButtonTooltipMessage: 'Remover $owner',
                  onDeleted: _busy ? null : () => _removeOwner(owner),
                ),
            ],
          ),
        for (final owner in _owners) _sshLine(c, owner),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('org-github-owner-input'),
                controller: _ownerInput,
                onChanged: (_) => setState(() => _ownerError = null),
                onSubmitted: _addOwner,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Adicionar org do GitHub',
                  labelStyle: TextStyle(fontSize: 13),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Adicionar org do GitHub',
              iconSize: 16,
              onPressed: () => _addOwner(_ownerInput.text),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        if (_ownerError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_ownerError!, style: TextStyle(fontSize: 12, color: c.fail)),
          ),
        if (addable.isNotEmpty) ...[
          const SizedBox(height: 6),
          Muted('sugestões da conta ${_account ?? 'ativa do gh'}:', size: 11),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in addable)
                ActionChip(
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  tooltip: 'Adicionar $s',
                  onPressed: () => _addOwner(s),
                ),
            ],
          ),
        ],
        // Only worth saying when it gets in the way: over https the per-org SSH identity does not apply.
        if (_protocol == 'https') ...[
          const SizedBox(height: 8),
          Text(
            'o gh clona por https: a conta por org via SSH não vale. Rode gh config set git_protocol ssh.',
            key: const ValueKey('org-github-https'),
            style: TextStyle(fontSize: 12, color: c.warn),
          ),
        ],
      ],
    );
  }

  Widget _permissionsSection(AppColors c) {
    final mode = _permissionMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Permissões da org', isDense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<PermissionMode?>(
              key: const ValueKey('org-permission-mode'),
              isDense: true,
              isExpanded: true,
              value: mode,
              style: TextStyle(fontSize: 13, color: c.textPrimary),
              items: [
                DropdownMenuItem<PermissionMode?>(
                  value: null,
                  child: Text('herdar global (${permissionModeLabel(widget.globalMode)})'),
                ),
                for (final m in kConfigPermissionModes)
                  DropdownMenuItem<PermissionMode?>(
                    value: m,
                    child: Text.rich(
                      TextSpan(
                        text: permissionModeLabel(m),
                        style: TextStyle(color: permissionModeColor(c, m)),
                        children: [
                          TextSpan(
                            text: '  ${permissionModeHint(m)}',
                            style: TextStyle(fontSize: 11, color: c.textMuted),
                          ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (m) async {
                      if (m == PermissionMode.bypassPermissions &&
                          _permissionMode != m &&
                          !await confirmBypass(context)) {
                        return;
                      }
                      if (!mounted) return;
                      setState(() {
                        _permissionMode = m;
                        _error = null;
                      });
                    },
            ),
          ),
        ),
        if (mode == PermissionMode.bypassPermissions)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(permissionModeHint(mode!), style: TextStyle(fontSize: 12, color: c.warn)),
          ),
      ],
    );
  }

  Widget _agentSection(AppColors c) {
    final status = _agentStatus;
    final models = _agentModels;
    final model = _agentModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Provider', isDense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<AgentProvider>(
              key: const ValueKey('org-agent-provider'),
              isDense: true,
              isExpanded: true,
              value: _provider,
              style: TextStyle(fontSize: 13, color: c.textPrimary),
              items: [for (final p in AgentProvider.values) DropdownMenuItem(value: p, child: Text(p.label))],
              onChanged: _busy ? null : _setProvider,
            ),
          ),
        ),
        if (_provider == AgentProvider.anthropic)
          const Padding(padding: EdgeInsets.only(top: 6), child: Muted('Claude Code com a sua conta', size: 12))
        else ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('org-agent-account'),
                  controller: _agentAccount,
                  onChanged: (_) => setState(() {
                    _agentTouched = true;
                    _agentModel = null;
                    _agentStatus = null;
                    _agentModels = null;
                  }),
                  onSubmitted: (_) => _loadAgent(),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Conta',
                    hintText: 'default (login da IDE)',
                    hintStyle: TextStyle(fontSize: 13, color: c.textMuted),
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('org-agent-check'),
                tooltip: 'Verificar conta',
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                onPressed: _busy ? null : _loadAgent,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_agentError != null)
            Text(_agentError!, style: TextStyle(fontSize: 12, color: c.warn))
          else if (status == null)
            const Muted('verifique a conta para ver o login e os modelos', size: 12)
          else if (status.loggedIn)
            Text('logada', style: TextStyle(fontSize: 12, color: c.pass))
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    _loggingIn ? 'aguardando o login no Terminal…' : 'sem login: entre com a conta Google desta org',
                    style: TextStyle(fontSize: 12, color: c.warn),
                  ),
                ),
                if (_loggingIn)
                  TextButton(
                    key: const ValueKey('org-agent-login-cancel'),
                    onPressed: _cancelLogin,
                    child: const Text('Cancelar', style: TextStyle(fontSize: 12)),
                  )
                else
                  FilledButton.icon(
                    key: const ValueKey('org-agent-login'),
                    style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
                    onPressed: _busy ? null : _login,
                    icon: const Icon(Icons.login, size: 14),
                    label: const Text('Fazer login', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            if (_loginNote case final note?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(note, style: TextStyle(fontSize: 12, color: c.warn)),
              ),
            const SizedBox(height: 6),
            const Muted('abre o Terminal no agy desta conta; ou rode o comando:', size: 11),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    status.loginCommand,
                    style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: c.textSecondary),
                  ),
                ),
                IconButton(
                  tooltip: 'Copiar comando',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Clipboard.setData(ClipboardData(text: status.loginCommand)),
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          InputDecorator(
            decoration: const InputDecoration(labelText: 'Modelo', isDense: true),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                key: const ValueKey('org-agent-model'),
                isDense: true,
                isExpanded: true,
                value: model,
                style: TextStyle(fontSize: 13, color: c.textPrimary),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('padrão do agy')),
                  for (final m in models ?? const <AgentModel>[])
                    DropdownMenuItem<String?>(
                      value: m.id,
                      child: Text.rich(
                        TextSpan(
                          text: m.label,
                          children: [
                            if (m.quota case final quota?)
                              TextSpan(
                                text: '  ${quota.label(DateTime.now())}',
                                style: TextStyle(fontSize: 11, color: quota.exhausted ? c.warn : c.textMuted),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (model != null && !(models ?? const <AgentModel>[]).any((m) => m.id == model))
                    DropdownMenuItem<String?>(value: model, child: Text(model)),
                ],
                onChanged: _busy
                    ? null
                    : (m) => setState(() {
                        _agentTouched = true;
                        _agentModel = m;
                      }),
              ),
            ),
          ),
          if (models?.where((m) => m.id == model).firstOrNull?.quota case final quota? when quota.exhausted)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'modelo ${quota.label(DateTime.now())}: as conversas livres desta org vão falhar até renovar',
                key: const ValueKey('org-agent-model-exhausted'),
                style: TextStyle(fontSize: 12, color: c.warn),
              ),
            ),
          const SizedBox(height: 6),
          const Muted('vale só para conversas livres; /skills e o Fluxo seguem no Claude Code', size: 11),
        ],
      ],
    );
  }

  Widget _sshLine(AppColors c, String owner) {
    final ssh = _ssh[owner.toLowerCase()];
    final identity = ssh?.identity;
    final alert = identity == null ? null : sshDivergence(identity, _account);
    final String text;
    final Color color;
    if (ssh == null || ssh.pending) {
      text = 'verificando SSH…';
      color = c.textMuted;
    } else if (alert != null) {
      text = alert;
      color = c.fail;
    } else if (identity?.login case final login?) {
      text = 'SSH: @$login via ${identity!.host ?? 'github.com'}';
      color = c.textSecondary;
    } else {
      text = 'SSH não verificado';
      color = c.warn;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Mono(owner, color: c.textMuted, size: 11),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _trackerField(String key, TextEditingController controller, String label, String hint) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: TextField(
      key: ValueKey('org-tracker-$key'),
      controller: controller,
      onChanged: (_) => setState(() => _error = null),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, color: context.colors.textMuted),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        isDense: true,
      ),
    ),
  );

  Widget _trackerSection(AppColors c) {
    final kind = _trackerKind;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Cards da org', isDense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<TrackerKind?>(
              key: const ValueKey('org-tracker-kind'),
              isDense: true,
              isExpanded: true,
              value: kind,
              style: TextStyle(fontSize: 13, color: c.textPrimary),
              items: [
                const DropdownMenuItem<TrackerKind?>(value: null, child: Text('nenhum (só kickoff manual)')),
                for (final k in TrackerKind.values) DropdownMenuItem<TrackerKind?>(value: k, child: Text(k.label)),
              ],
              onChanged: _busy
                  ? null
                  : (k) => setState(() {
                      _trackerKind = k;
                      _error = null;
                    }),
            ),
          ),
        ),
        ...switch (kind) {
          null => const <Widget>[],
          TrackerKind.ado => [
            _trackerField('org', _trackerOrg, 'Org', 'ex.: GrupoOTG'),
            _trackerField('project', _trackerProject, 'Projeto', 'ex.: R10 Score Development'),
          ],
          TrackerKind.jira => [
            _trackerField('site', _trackerSite, 'Site', 'ex.: likindo.atlassian.net'),
            _trackerField('project', _trackerProject, 'Chave do projeto', 'ex.: LC'),
            _trackerField('email', _trackerEmail, 'Email da conta', 'quem é dono do API token'),
          ],
          TrackerKind.linear => [
            _trackerField('team', _trackerTeam, 'Team key', 'opcional · ex.: LC'),
            _trackerField('workspace', _trackerWorkspace, 'Workspace', 'opcional · slug em linear.app/<slug>'),
          ],
        },
        if (kind != null) ...[
          const SizedBox(height: 6),
          CheckboxListTile(
            key: const ValueKey('org-tracker-release'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _releaseBase,
            onChanged: _busy ? null : (v) => setState(() => _releaseBase = v ?? false),
            title: const Text('Branch a partir da última release/*', style: TextStyle(fontSize: 13)),
            subtitle: const Muted('desmarcado: a branch padrão do remoto', size: 11),
          ),
          Muted(switch (kind) {
            TrackerKind.ado => 'PAT em ~/.claude/.ado_pat ou AZURE_DEVOPS_EXT_PAT',
            TrackerKind.jira => 'API token em ~/.claude/.jira_token ou JIRA_API_TOKEN',
            TrackerKind.linear => 'via MCP linear: autentique com /mcp',
          }, size: 11),
        ],
      ],
    );
  }

  Widget _generalSection(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          onChanged: (_) => setState(() {
            _error = null;
            _nameError = null;
          }),
          onSubmitted: (_) => _save(),
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Nome',
            hintText: 'ex.: likin.do, pessoal, cliente-x',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            isDense: true,
            errorText: _nameError,
          ),
        ),
        const SizedBox(height: 14),
        const Muted('Pastas', size: 11),
        const SizedBox(height: 6),
        if (_roots.isEmpty)
          _rootsError == null
              ? const Muted('nenhuma pasta', size: 12)
              : Text(_rootsError!, style: TextStyle(fontSize: 12, color: c.fail)),
        for (final root in _roots)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 14, color: c.textSecondary),
                const SizedBox(width: 8),
                Expanded(child: Mono(root, color: c.textSecondary)),
                IconButton(
                  tooltip: 'Remover pasta',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _roots = [..._roots]..remove(root)),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.accent),
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: Text(_full ? 'trocar pasta' : 'escolher pasta', style: const TextStyle(fontSize: 12)),
          ),
        ),
        if (widget.suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Muted('SUGESTÕES EM ~/development', size: 10),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in widget.suggestions)
                ActionChip(
                  label: Text(normalizePath(s).split('/').last, style: const TextStyle(fontSize: 12)),
                  tooltip: s,
                  onPressed: _busy ? null : () => _suggest(s),
                ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dirty = _dirty;
    _notifyDirty(dirty);
    final general = _FormSection(title: 'GERAL', child: _generalSection(c));
    final permissions = _FormSection(title: 'PERMISSÕES', child: _permissionsSection(c));
    final agent = _FormSection(title: 'AGENTE', child: _agentSection(c));
    final budget = _FormSection(
      title: 'ORÇAMENTO',
      child: BudgetField(
        key: const ValueKey('org-form-budget'),
        controller: _budget,
        label: 'Por ciclo',
        hint: widget.globalBudget == null ? 'sem orçamento' : 'herdar global (${usd(widget.globalBudget!)})',
        onChanged: (_) => setState(() {}),
      ),
    );
    final github = _FormSection(child: _githubSection(c));
    final tracker = _FormSection(title: 'TRACKER', child: _trackerSection(c));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.simple) ...[
          general,
          const SizedBox(height: 8),
          InkWell(
            key: const ValueKey('org-form-advanced'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _advanced = !_advanced),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(_advanced ? Icons.expand_less : Icons.expand_more, size: 18, color: c.textSecondary),
                  const SizedBox(width: 6),
                  Text('Opções avançadas', style: TextStyle(fontSize: 13, color: c.textPrimary)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Muted(
                      'padrão: aceitar edições · Claude · conta ativa do gh · sem tracker — dá para mudar depois em Configurações',
                      size: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_advanced) ...[
            permissions,
            const SizedBox(height: 12),
            agent,
            const SizedBox(height: 12),
            github,
            const SizedBox(height: 12),
            tracker,
            const SizedBox(height: 12),
            budget,
          ],
        ] else
          LayoutBuilder(
            builder: (_, constraints) => constraints.maxWidth >= 760
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            general,
                            const SizedBox(height: 12),
                            permissions,
                            const SizedBox(height: 12),
                            agent,
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [github, const SizedBox(height: 12), tracker, const SizedBox(height: 12), budget],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      general,
                      const SizedBox(height: 12),
                      permissions,
                      const SizedBox(height: 12),
                      agent,
                      const SizedBox(height: 12),
                      github,
                      const SizedBox(height: 12),
                      tracker,
                      const SizedBox(height: 12),
                      budget,
                    ],
                  ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 12, color: c.fail)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
              onPressed: _busy || _blocked || (widget.initial != null && !dirty) ? null : _save,
              child: Text(widget.saveLabel, style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: switch (_blockReason) {
                final reason? => Text(
                  reason,
                  key: const ValueKey('org-form-blocked'),
                  style: TextStyle(fontSize: 12, color: c.fail),
                ),
                null when dirty && widget.initial != null => Text(
                  'alterações não salvas',
                  key: const ValueKey('org-form-dirty'),
                  style: TextStyle(fontSize: 12, color: c.warn),
                ),
                null => const SizedBox.shrink(),
              },
            ),
            // Away from Salvar: removing is not undoable.
            if (widget.onRemove case final remove?)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: c.fail),
                onPressed: _busy ? null : () => _run(remove),
                child: const Text('Remover org', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ],
    );
  }
}

class _FormSection extends StatelessWidget {
  const _FormSection({this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title case final title?) ...[Muted(title, size: 10), const SizedBox(height: 10)],
          child,
        ],
      ),
    );
  }
}
