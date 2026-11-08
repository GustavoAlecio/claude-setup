import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/unsaved_changes.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';
import 'advanced_section.dart';
import 'budget_field.dart';
import 'org_form.dart';

/// Orgs are edited as a form with Salvar; project and hidden actions write as soon as they happen.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.backTo, this.newOrg = false});

  /// Location of "Voltar": the last shell route visited (`/p/` or `/o/`), or the landing.
  final String Function() backTo;

  /// Opens with the "Nova org" form (`/settings?nova=1`).
  final bool newOrg;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final ValueNotifier<bool> _unsaved = UnsavedChangesScope.of(context);

  @override
  void dispose() {
    // Whatever was being edited is gone with the page.
    _unsaved.value = false;
    super.dispose();
  }

  Future<void> _back(DashboardConfig? config, List<Project>? projects) async {
    if (!await confirmDiscard(context, _unsaved)) return;
    if (mounted) context.go(backTarget(widget.backTo(), config, projects));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final config = context.watch<ConfigCubit>().state.data;
    final projects = context.watch<ProjectsCubit>().state.data;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, kTitleBarInset, 20, 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                  onPressed: () => _back(config, projects),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('Voltar', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Text('Configurações', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          Expanded(
            child: config == null || projects == null
                ? const SizedBox.shrink()
                : ListView(
                    padding: EdgeInsets.fromLTRB(_gutter(context), 20, _gutter(context), 40),
                    children: [
                      _PermissionsSection(config: config),
                      const SizedBox(height: 28),
                      _OrgsSection(config: config, projects: projects, unsaved: _unsaved, adding: widget.newOrg),
                      const SizedBox(height: 28),
                      _ProjectsSection(config: config, projects: projects),
                      const SizedBox(height: 28),
                      const _SectionTitle('Avançado'),
                      AdvancedSection(config: config),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Centers the content at [_kMaxContentWidth] on wide windows; long form fields at 2000px are unreadable.
const _kMaxContentWidth = 1200.0;

double _gutter(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width > _kMaxContentWidth + 48 ? (width - _kMaxContentWidth) / 2 : 24;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Muted(text, size: 11));
}

/// Global mode of new sessions; orgs and the session itself override it, and open sessions keep their own.
class _PermissionsSection extends StatefulWidget {
  const _PermissionsSection({required this.config});

  final DashboardConfig config;

  @override
  State<_PermissionsSection> createState() => _PermissionsSectionState();
}

class _PermissionsSectionState extends State<_PermissionsSection> {
  String? _error;

  Future<void> _write(PermissionMode mode) async {
    setState(() => _error = null);
    try {
      await RepositoryScope.of(context).updateConfig(setGlobalPermissionMode(mode));
    } on ConfigWriteException catch (e, st) {
      log('permission mode write rejected', name: 'SettingsPage', error: e, stackTrace: st);
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mode = widget.config.permissionMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Padrões globais'),
        Panel(
          key: const ValueKey('settings-permissions'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Modo das sessões novas', style: TextStyle(fontSize: 13))),
                  PermissionModeMenu(
                    key: const ValueKey('settings-permission-mode'),
                    mode: mode,
                    tooltip: 'Modo global de permissões',
                    bypassScope: switch ([
                      for (final o in widget.config.orgs)
                        if (o.permissionMode == null) o.name,
                    ]) {
                      [] => 'nenhuma org (todas têm modo próprio)',
                      final names => 'as orgs que herdam o global: ${names.join(', ')}',
                    },
                    onSelected: _write,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (mode == PermissionMode.bypassPermissions)
                Text(permissionModeHint(mode), style: TextStyle(fontSize: 12, color: c.warn))
              else
                Muted(permissionModeHint(mode), size: 12),
              const SizedBox(height: 4),
              const Muted('cada org pode ter o próprio modo; a sessão também; sessões abertas mantêm o modo', size: 11),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_error!, style: TextStyle(fontSize: 12, color: c.fail)),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Divider(height: 1, color: c.border),
              ),
              _GlobalBudget(key: ValueKey(widget.config.cycleBudget), budget: widget.config.cycleBudget),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlobalBudget extends StatefulWidget {
  const _GlobalBudget({super.key, required this.budget});

  final double? budget;

  @override
  State<_GlobalBudget> createState() => _GlobalBudgetState();
}

class _GlobalBudgetState extends State<_GlobalBudget> {
  late final _controller = TextEditingController(text: budgetText(widget.budget));
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save(double? budget) async {
    try {
      await RepositoryScope.of(context).updateConfig(setCycleBudget(budget));
    } on ConfigWriteException catch (e, st) {
      log('budget write rejected', name: 'SettingsPage', error: e, stackTrace: st);
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final value = parseBudgetInput(_controller.text);
    final valid = !(value?.isNaN ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Orçamento por ciclo', style: TextStyle(fontSize: 13)),
              ),
            ),
            SizedBox(
              width: 200,
              child: BudgetField(
                key: const ValueKey('settings-cycle-budget'),
                controller: _controller,
                hint: 'sem orçamento',
                onChanged: (_) => setState(() => _error = null),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('settings-cycle-budget-save'),
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: valid && value != widget.budget ? () => _save(value) : null,
              child: const Text('Salvar', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Muted(
          'o Fluxo avisa a partir de 80% e quando o custo das sessões do ciclo passa do valor; cada org pode ter o seu',
          size: 11,
        ),
        if (_error case final error?) Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
      ],
    );
  }
}

/// Orgs as a horizontal strip of summary cards; the selected one (or the new-org draft) opens below in [OrgForm].
class _OrgsSection extends StatefulWidget {
  const _OrgsSection({required this.config, required this.projects, required this.unsaved, this.adding = false});

  final DashboardConfig config;
  final List<Project> projects;
  final ValueNotifier<bool> unsaved;
  final bool adding;

  @override
  State<_OrgsSection> createState() => _OrgsSectionState();
}

class _OrgsSectionState extends State<_OrgsSection> {
  static const _cardWidth = 240.0;
  static const _cardGap = 12.0;

  final _scroll = ScrollController();
  late bool _adding = widget.adding;

  /// Settings a new org starts from when it duplicates another (everything but name and folders).
  OrgConfig? _template;
  String? _selected;

  List<OrgConfig> get _orgs => widget.config.orgs;

  /// Falls back to the first org when the selection was renamed elsewhere or removed.
  OrgConfig? get _current => _orgs.where((o) => o.name == _selected).firstOrNull ?? _orgs.firstOrNull;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _update(OrgConfig old, OrgConfig draft) async {
    await RepositoryScope.of(context).updateConfig(updateOrg(old.name, draft));
    if (mounted) setState(() => _selected = draft.name);
  }

  Future<void> _add(OrgConfig draft) async {
    await RepositoryScope.of(context).updateConfig(addOrg(draft));
    widget.unsaved.value = false;
    if (mounted) {
      setState(() {
        _adding = false;
        _selected = draft.name;
      });
    }
  }

  Future<void> _remove(OrgConfig org) async {
    final repository = RepositoryScope.of(context);
    final projects = projectsInOrg(widget.projects, org.name).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remover ${org.name}?'),
        content: Text(
          '${switch (projects) {
            0 => 'Nenhum projeto é afetado',
            1 => '1 projeto fica sem org ou passa para a org da pasta dele',
            _ => '$projects projetos ficam sem org ou passam para a org da pasta deles',
          }}. '
          'As pastas, a conta do GitHub, o agente e as permissões desta org saem das configurações. '
          'Sessões abertas continuam. Não dá para desfazer.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.colors.fail, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remover org'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repository.updateConfig(removeOrg(org.name));
    widget.unsaved.value = false;
    if (mounted) setState(() => _selected = null);
  }

  Future<void> _select(String? name) async {
    final same = name == null ? _adding : !_adding && name == _current?.name;
    if (!same && !await confirmDiscard(context, widget.unsaved)) return;
    if (!mounted) return;
    setState(() {
      _adding = name == null;
      _template = null;
      if (name != null) _selected = name;
    });
  }

  /// New-org form prefilled with [org]'s permissions, agent and GitHub; name and folders stay to be chosen, since
  /// two orgs can neither share a name nor overlap roots.
  Future<void> _duplicate(OrgConfig org) async {
    if (!await confirmDiscard(context, widget.unsaved) || !mounted) return;
    setState(() {
      _adding = true;
      _template = OrgConfig(name: '', github: org.github, permissionMode: org.permissionMode, agent: org.agent);
    });
  }

  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final target = (_scroll.offset + direction * (_cardWidth + _cardGap) * 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    unawaited(_scroll.animateTo(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final current = _adding ? null : _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionTitle('Orgs')),
            TextButton.icon(
              key: const ValueKey('settings-new-org-button'),
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => _select(null),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Nova org', style: TextStyle(fontSize: 12)),
            ),
            ListenableBuilder(
              listenable: _scroll,
              builder: (_, _) {
                final position = _scroll.hasClients && _scroll.position.hasContentDimensions ? _scroll.position : null;
                return Row(
                  children: [
                    IconButton(
                      tooltip: 'Orgs anteriores',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      onPressed: position == null || position.pixels <= 0 ? null : () => _page(-1),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    IconButton(
                      tooltip: 'Próximas orgs',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      onPressed: position == null || position.pixels >= position.maxScrollExtent
                          ? null
                          : () => _page(1),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
        SizedBox(
          height: 132,
          child: ListView.separated(
            key: const ValueKey('settings-org-carousel'),
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            itemCount: _orgs.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: _cardGap),
            itemBuilder: (_, i) => SizedBox(
              width: _cardWidth,
              child: i < _orgs.length
                  ? _OrgCard(
                      org: _orgs[i],
                      projects: projectsInOrg(widget.projects, _orgs[i].name).length,
                      globalMode: widget.config.permissionMode,
                      selected: _orgs[i].name == current?.name,
                      onTap: () => _select(_orgs[i].name),
                    )
                  : _NewOrgCard(selected: _adding, onTap: () => _select(null)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_adding)
          Panel(
            key: const ValueKey('settings-new-org'),
            title: _template == null ? 'Nova org' : 'Nova org (cópia das configurações)',
            child: OrgForm(
              key: ValueKey(_template),
              initial: _template,
              globalMode: widget.config.permissionMode,
              globalBudget: widget.config.cycleBudget,
              others: _orgs,
              saveLabel: 'Criar org',
              onSave: _add,
              onDirtyChanged: (dirty) => widget.unsaved.value = dirty,
            ),
          )
        else if (current != null)
          Panel(
            key: ValueKey('settings-org-form-${current.name}'),
            title: current.name,
            trailing: TextButton.icon(
              key: const ValueKey('settings-org-duplicate'),
              style: TextButton.styleFrom(foregroundColor: c.textSecondary),
              onPressed: () => _duplicate(current),
              icon: const Icon(Icons.copy_all_outlined, size: 15),
              label: const Text('Duplicar', style: TextStyle(fontSize: 12)),
            ),
            child: OrgForm(
              globalMode: widget.config.permissionMode,
              globalBudget: widget.config.cycleBudget,
              key: ValueKey(current.name),
              initial: current,
              others: [
                for (final o in _orgs)
                  if (o.name != current.name) o,
              ],
              onSave: (draft) => _update(current, draft),
              onRemove: () => _remove(current),
              onDirtyChanged: (dirty) => widget.unsaved.value = dirty,
            ),
          ),
      ],
    );
  }
}

class _OrgCard extends StatelessWidget {
  const _OrgCard({
    required this.org,
    required this.projects,
    required this.globalMode,
    required this.selected,
    required this.onTap,
  });

  final OrgConfig org;
  final int projects;
  final PermissionMode globalMode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mode = org.permissionMode;
    final account = org.github?.account;
    final owners = org.github?.owners ?? const <String>[];
    return Tooltip(
      message: [org.name, ...org.roots].join('\n'),
      waitDuration: const Duration(milliseconds: 600),
      child: _CardFrame(
        key: ValueKey('settings-org-card-${org.name}'),
        selected: selected,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    org.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                Muted(countLabel(projects, 'projeto'), size: 11),
              ],
            ),
            const SizedBox(height: 4),
            Mono(
              [
                if (org.roots.isNotEmpty) org.roots.first.split('/').last,
                if (org.roots.length > 1) '+${org.roots.length - 1}',
              ].join(' '),
              color: c.textMuted,
              size: 11,
            ),
            Expanded(
              child: Align(
                alignment: Alignment.bottomLeft,
                // Long account or org names wrap past the card: clip instead of overflowing it.
                child: ClipRect(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      // Inherited reads as muted and dot-less; a mode the org chose keeps its color and dot.
                      Pill(
                        label: mode == null ? 'herda: ${permissionModeLabel(globalMode)}' : permissionModeLabel(mode),
                        color: mode == null ? c.textMuted : permissionModeColor(c, mode),
                        dot: mode != null,
                      ),
                      // Only free conversations follow the org's agent; skills and the Fluxo run on Claude Code.
                      Pill(
                        tooltip: 'Agente das conversas livres; /skills e o Fluxo rodam no Claude',
                        label: switch (org.agent) {
                          OrgAgent(provider: AgentProvider.antigravity, :final account) =>
                            'Antigravity · ${account ?? kDefaultAgentAccount}',
                          _ => 'Claude',
                        },
                        color: org.agent?.provider == AgentProvider.antigravity ? c.accent : c.textSecondary,
                        dot: false,
                      ),
                      Pill(
                        label: [
                          'GitHub: ${account ?? 'conta ativa'}',
                          if (owners.length == 1) owners.first,
                          if (owners.length > 1) '${owners.length} orgs',
                        ].join(' · '),
                        color: c.textSecondary,
                        dot: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewOrgCard extends StatelessWidget {
  const _NewOrgCard({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _CardFrame(
      key: const ValueKey('settings-org-card-new'),
      selected: selected,
      ghost: true,
      onTap: onTap,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16, color: c.accent),
            const SizedBox(width: 6),
            Text('Nova org', style: TextStyle(fontSize: 13, color: c.accent)),
          ],
        ),
      ),
    );
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({super.key, required this.selected, required this.onTap, required this.child, this.ghost = false});

  final bool selected;
  final bool ghost;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.elevated : (ghost ? Colors.transparent : c.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? c.accent : c.border, width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: c.hover,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      ),
    );
  }
}

class _ProjectsSection extends StatefulWidget {
  const _ProjectsSection({required this.config, required this.projects});

  final DashboardConfig config;
  final List<Project> projects;

  @override
  State<_ProjectsSection> createState() => _ProjectsSectionState();
}

/// What a project runs with in [org]: the agent, the gh account and the permission mode the next session gets.
({String agent, String github, String mode}) _effectiveIn(String org, DashboardConfig config) {
  final orgName = org == kNoOrg ? null : org;
  final agent = agentFor(orgName, config, 'prompt');
  return (
    agent: agent.provider == AgentProvider.antigravity
        ? 'Antigravity · ${agent.account ?? kDefaultAgentAccount}'
        : 'Claude',
    github: githubFor(orgName, config).account ?? 'conta ativa do gh',
    mode: permissionModeLabel(effectivePermissionMode(null, orgName, config)),
  );
}

class _ProjectsSectionState extends State<_ProjectsSection> {
  String? _error;
  String? _notice;
  bool _picking = false;

  Future<void> _write(ConfigMutation mutation) async {
    setState(() => _error = null);
    try {
      await RepositoryScope.of(context).updateConfig(mutation);
    } on ConfigWriteException catch (e, st) {
      log('project write rejected', name: 'SettingsPage', error: e, stackTrace: st);
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _undoable(String message, ConfigMutation undo) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: 'Desfazer', onPressed: () => _write(undo)),
      ),
    );
  }

  String? _pinnedOrg(String name) => widget.config.projects.where((e) => e.name == name).firstOrNull?.org;

  /// Moving changes the agent, gh account and mode of the project's next sessions: say so before, offer undo after.
  Future<void> _move(Project project, String target) async {
    if (target == project.org) return;
    final before = _effectiveIn(project.org, widget.config);
    final after = _effectiveIn(target, widget.config);
    final changes = [
      if (before.agent != after.agent) 'Agente: ${before.agent} → ${after.agent}',
      if (before.github != after.github) 'GitHub: ${before.github} → ${after.github}',
      if (before.mode != after.mode) 'Permissões: ${before.mode} → ${after.mode}',
    ];
    if (changes.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Mover ${project.name} para $target?'),
          content: Text('As próximas sessões do projeto mudam:\n\n${changes.map((l) => '• $l').join('\n')}'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Mover')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final previous = _pinnedOrg(project.name);
    await _write(setProjectOrg(project.name, target, path: project.path));
    if (!mounted) return;
    _undoable('${project.name} movido para $target', setProjectOrg(project.name, previous, path: project.path));
  }

  Future<void> _hide(Project project) async {
    await _write(hideProject(project.name));
    if (mounted) _undoable('${project.name} oculto', unhideProject(project.name));
  }

  /// [org] `null` (the global button) asks where to put a folder outside every org's roots.
  Future<void> _addProject({String? org}) async {
    final repository = RepositoryScope.of(context);
    final pick = RepositoryScope.pickerOf(context);
    setState(() => _picking = true);
    try {
      final dir = await pick();
      if (dir == null || !mounted) return;
      final picked = await repository.inspectDirectory(dir);
      if (!mounted) return;
      final byRoot = orgOf(picked.path, orgs: widget.config.orgs, canonical: normalizePath);
      var target = org ?? byRoot;
      if (org == null && byRoot == kNoOrg && widget.config.orgs.isNotEmpty) {
        final chosen = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text('Em qual org fica ${picked.name}?'),
            children: [
              for (final name in [for (final o in widget.config.orgs) o.name, kNoOrg])
                SimpleDialogOption(onPressed: () => Navigator.of(context).pop(name), child: Text(name)),
            ],
          ),
        );
        if (chosen == null || !mounted) return;
        target = chosen;
      }
      setState(() => _notice = picked.divergence);
      // Pinned only when the roots would put it elsewhere: inside its org's folder the root already decides.
      await _write(addProject(name: picked.name, path: picked.path, org: target == byRoot ? null : target));
      if (mounted && _error == null) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('${picked.name} adicionado em $target')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// "conversas: Claude · modo: aceitar edições · GitHub: conta ativa" for a project of [org].
  String _setupOf(String org) {
    final config = widget.config;
    final name = org == kNoOrg ? null : org;
    final agent = agentFor(name, config, 'prompt');
    final github = githubFor(name, config).account;
    return [
      'conversas: ${agent.provider == AgentProvider.antigravity ? 'Antigravity · ${agent.account ?? kDefaultAgentAccount}' : 'Claude'}'
          '${agent.model == null ? '' : ' · ${agent.model}'}',
      'modo: ${permissionModeLabel(effectivePermissionMode(null, name, config))}',
      'GitHub: ${github ?? 'conta ativa'}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final orgs = [for (final o in widget.config.orgs) o.name, kNoOrg];
    final hidden = widget.config.hidden;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionTitle('Projetos')),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: _picking ? null : _addProject,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Adicionar projeto', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_error!, style: TextStyle(fontSize: 12, color: c.fail)),
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_notice!, style: TextStyle(fontSize: 12, color: c.warn)),
          ),
        for (final org in orgs)
          if (org != kNoOrg || projectsInOrg(widget.projects, kNoOrg).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                key: ValueKey('settings-projects-$org'),
                title: org,
                trailing: org == kNoOrg
                    ? null
                    : TextButton.icon(
                        key: ValueKey('settings-add-project-$org'),
                        style: TextButton.styleFrom(foregroundColor: c.accent),
                        onPressed: _picking ? null : () => _addProject(org: org),
                        icon: const Icon(Icons.add, size: 14),
                        label: const Text('Adicionar', style: TextStyle(fontSize: 12)),
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (projectsInOrg(widget.projects, org).isEmpty) const Muted('nenhum projeto', size: 12),
                    for (final p in projectsInOrg(widget.projects, org))
                      _ProjectRow(
                        project: p,
                        setup: _setupOf(p.org),
                        orgs: orgs,
                        outsideRoots:
                            p.org != kNoOrg &&
                            p.path != null &&
                            orgOf(p.path!, orgs: widget.config.orgs, canonical: normalizePath) != p.org,
                        onOrg: (target) => _move(p, target),
                        onHide: () => _hide(p),
                      ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 16),
        const _SectionTitle('Ocultos'),
        Panel(
          key: const ValueKey('settings-hidden'),
          child: hidden.isEmpty
              ? const Muted('nenhum projeto oculto', size: 12)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final name in hidden)
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name, style: const TextStyle(fontSize: 13)),
                                if (widget.config.projects.where((e) => e.name == name).firstOrNull?.path
                                    case final path?)
                                  Mono(path, color: c.textMuted, size: 11),
                              ],
                            ),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: c.accent),
                            onPressed: () => _write(unhideProject(name)),
                            child: const Text('Reexibir', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.setup,
    required this.orgs,
    required this.outsideRoots,
    required this.onOrg,
    required this.onHide,
  });

  final Project project;

  /// How its sessions run (agent, mode, GitHub account), resolved from its org and the global defaults.
  final String setup;
  final List<String> orgs;

  /// Pinned to an org whose folders do not hold it: legal, but worth seeing.
  final bool outsideRoots;
  final ValueChanged<String> onOrg;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(project.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Mono(project.path ?? 'sem pasta', color: c.textMuted, size: 11),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    setup,
                    key: ValueKey('settings-project-setup-${project.name}'),
                    style: TextStyle(fontSize: 11, color: c.textSecondary),
                  ),
                ),
                if (outsideRoots)
                  Text('pasta fora das pastas de ${project.org}', style: TextStyle(fontSize: 11, color: c.warn)),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Trocar org de ${project.name}',
            color: c.elevated,
            onSelected: onOrg,
            itemBuilder: (_) => [
              for (final org in orgs)
                PopupMenuItem(
                  value: org,
                  height: 36,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        child: org == project.org ? Icon(Icons.check, size: 14, color: c.accent) : null,
                      ),
                      Text(org, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(project.org, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                  Icon(Icons.arrow_drop_down, size: 16, color: c.textMuted),
                ],
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: c.textSecondary),
            onPressed: onHide,
            child: const Text('Ocultar', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
