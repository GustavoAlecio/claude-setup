import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/github_models.dart';
import '../../data/github_parser.dart';
import '../../data/github_repository.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';

const _kSshTimeout = Duration(seconds: 10);

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
  String? _error;
  String? _ownerError;
  bool _busy = false;

  late GitHubRepository _github;
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
    if (_githubStarted) return;
    _githubStarted = true;
    unawaited(_loadGithub());
    for (final owner in _owners) {
      unawaited(_verify(owner));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _ownerInput.dispose();
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

  bool _diverges(SshIdentity? identity) => identity != null && sshDivergence(identity, _account) != null;

  bool get _blocked => _owners.any((o) {
    final ssh = _ssh[o.toLowerCase()];
    return ssh != null && (ssh.pending || _diverges(ssh.identity));
  });

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
    setState(() {
      _error = null;
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
    final draft = OrgConfig(name: _name.text.trim(), roots: _roots, github: github, permissionMode: _permissionMode);
    final error = _roots.isEmpty ? 'escolha uma pasta para a org' : validateOrgs([...widget.others, draft]);
    if (error != null) {
      setState(() => _error = error);
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
            const Expanded(child: Muted('GITHUB', size: 10)),
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
        const Muted('ORGS DO GITHUB', size: 10),
        const SizedBox(height: 6),
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
                decoration: const InputDecoration(labelText: 'Adicionar org do GitHub', isDense: true),
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
        if (_protocol != null || accounts != null) ...[
          const SizedBox(height: 8),
          Text(
            'git_protocol do gh: ${_protocol ?? 'não definido'}${_protocol == 'https' ? ' (recomendado: ssh)' : ''}',
            style: TextStyle(fontSize: 12, color: _protocol == 'https' ? c.warn : c.textSecondary),
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
                const DropdownMenuItem<PermissionMode?>(value: null, child: Text('herdar global')),
                for (final m in PermissionMode.values)
                  DropdownMenuItem<PermissionMode?>(
                    value: m,
                    child: Text(permissionModeLabel(m), style: TextStyle(color: permissionModeColor(c, m))),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (m) => setState(() {
                      _permissionMode = m;
                      _error = null;
                    }),
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _save(),
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(labelText: 'Nome', isDense: true),
        ),
        const SizedBox(height: 10),
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
        const SizedBox(height: 14),
        _permissionsSection(c),
        const SizedBox(height: 14),
        _githubSection(c),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 12, color: c.fail)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
              onPressed: _busy || _blocked ? null : _save,
              child: Text(widget.saveLabel, style: const TextStyle(fontSize: 12)),
            ),
            if (widget.onRemove case final remove?) ...[
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: c.fail),
                onPressed: _busy ? null : () => _run(remove),
                child: const Text('Remover org', style: TextStyle(fontSize: 12)),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
