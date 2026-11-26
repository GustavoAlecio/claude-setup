import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/platform/attention.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/unsaved_changes.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_aggregates.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';
import 'advanced_section.dart';
import 'budget_field.dart';
import 'org_form.dart';

/// Orgs are edited as a form with Salvar; project and hidden actions write as soon as they happen.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.backTo, this.newOrg = false, this.home});

  /// Location of "Voltar": the last shell route visited (`/p/` or `/o/`), or the landing.
  final String Function() backTo;

  /// Opens with the "Nova org" form (`/settings?nova=1`).
  final bool newOrg;

  /// The user's home, shown as `~` in the org folders.
  final String? home;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

enum _Section {
  orgs('Orgs'),
  projects('Projetos'),
  stop('Quando parar em você'),
  budget('Orçamento'),
  advanced('Avançado');

  const _Section(this.label);

  final String label;
}

class _SettingsPageState extends State<SettingsPage> {
  late final ValueNotifier<bool> _unsaved = UnsavedChangesScope.of(context);
  final _anchors = {for (final s in _Section.values) s: GlobalKey()};

  /// The last item tapped in the nav; scrolling by hand does not move it.
  var _active = _Section.orgs;
  Future<Set<String>>? _gates;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gates ??= RepositoryScope.of(context).loadRequiredGates();
  }

  void _goTo(_Section section) {
    setState(() => _active = section);
    unawaited(
      Scrollable.ensureVisible(
        _anchors[section]!.currentContext!,
        alignment: 0,
        duration: const Duration(milliseconds: 200),
      ),
    );
  }

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
                : Padding(
                    padding: EdgeInsets.symmetric(horizontal: _gutter(context)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // A plain Column: a scrollable here would come before the content's in the tree.
                        SizedBox(
                          width: 180,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: Column(
                              key: const ValueKey('settings-nav'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final section in _Section.values)
                                  _NavItem(
                                    key: ValueKey('settings-nav-${section.name}'),
                                    label: section.label,
                                    selected: section == _active,
                                    onTap: () => _goTo(section),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) => SingleChildScrollView(
                              key: const ValueKey('settings-content'),
                              padding: const EdgeInsets.only(top: 20, bottom: 40),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  KeyedSubtree(
                                    key: const ValueKey('settings-orgs'),
                                    child: _OrgsSection(
                                      anchor: _anchors[_Section.orgs]!,
                                      config: config,
                                      projects: projects,
                                      unsaved: _unsaved,
                                      home: widget.home,
                                      adding: widget.newOrg,
                                    ),
                                  ),
                                  const SizedBox(height: 28),
                                  KeyedSubtree(
                                    key: const ValueKey('settings-projects'),
                                    child: _ProjectsSection(
                                      anchor: _anchors[_Section.projects]!,
                                      config: config,
                                      projects: projects,
                                    ),
                                  ),
                                  const SizedBox(height: 28),
                                  KeyedSubtree(
                                    key: const ValueKey('settings-stop'),
                                    child: FutureBuilder<Set<String>>(
                                      future: _gates,
                                      initialData: kAlwaysRequiredGates,
                                      builder: (_, gates) => _StopSection(
                                        anchor: _anchors[_Section.stop]!,
                                        rules: stopRules(gates.requireData),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 28),
                                  Column(
                                    key: const ValueKey('settings-budget'),
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      _SectionTitle(_Section.budget.label, key: _anchors[_Section.budget]),
                                      Panel(
                                        child: _GlobalBudget(
                                          key: ValueKey(config.cycleBudget),
                                          budget: config.cycleBudget,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 28),
                                  // As tall as the viewport, so the last section can also scroll up to the top.
                                  ConstrainedBox(
                                    key: const ValueKey('settings-advanced'),
                                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        _SectionTitle(_Section.advanced.label, key: _anchors[_Section.advanced]),
                                        _GlobalDefaults(config: config),
                                        const SizedBox(height: 12),
                                        AdvancedSection(config: config),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.hover : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        hoverColor: c.hover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? c.textPrimary : c.textSecondary,
            ),
          ),
        ),
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
  const _SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Muted(text, size: 11));
}

/// When the pipeline stops for the user: read-only, one row per rule of `stopRules`.
class _StopSection extends StatelessWidget {
  const _StopSection({required this.anchor, required this.rules});

  final GlobalKey anchor;
  final List<({String what, String when})> rules;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(_Section.stop.label, key: anchor),
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Muted(
            'Vale para todos os projetos. O piloto automático (/auto no terminal) não muda estas paradas.',
            size: 12,
          ),
        ),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, rule) in rules.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    key: ValueKey('settings-stop-$i'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 180,
                        child: Text(rule.what, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(rule.when, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Global mode of new sessions (orgs and the session itself override it, and open sessions keep their own) and the
/// sound alert.
class _GlobalDefaults extends StatefulWidget {
  const _GlobalDefaults({required this.config});

  final DashboardConfig config;

  @override
  State<_GlobalDefaults> createState() => _GlobalDefaultsState();
}

class _GlobalDefaultsState extends State<_GlobalDefaults> {
  String? _error;
  String? _soundError;

  Future<void> _setSound(bool on) async {
    setState(() => _soundError = null);
    try {
      await RepositoryScope.of(context).updateConfig(setAlertSound(on));
    } on ConfigWriteException catch (e, st) {
      log('alert sound write rejected', name: 'SettingsPage', error: e, stackTrace: st);
      if (mounted) setState(() => _soundError = e.message);
      return;
    }
    if (on) await const AttentionChannel().sound();
  }

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
    return Panel(
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
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Alerta sonoro', style: TextStyle(fontSize: 13)),
                    SizedBox(height: 2),
                    Muted('toca quando algo novo espera você', size: 12),
                  ],
                ),
              ),
              Material(
                type: MaterialType.transparency,
                child: Switch(
                  key: const ValueKey('settings-alert-sound'),
                  value: widget.config.alertSound,
                  onChanged: _setSound,
                ),
              ),
            ],
          ),
          if (_soundError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _soundError!,
                key: const ValueKey('settings-alert-sound-error'),
                style: TextStyle(fontSize: 12, color: c.fail),
              ),
            ),
        ],
      ),
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

/// One row per org; the selected one opens its [OrgForm] right below, and the new-org draft sits above the rows.
class _OrgsSection extends StatefulWidget {
  const _OrgsSection({
    required this.anchor,
    required this.config,
    required this.projects,
    required this.unsaved,
    required this.home,
    this.adding = false,
  });

  final GlobalKey anchor;
  final DashboardConfig config;
  final List<Project> projects;
  final ValueNotifier<bool> unsaved;
  final String? home;
  final bool adding;

  @override
  State<_OrgsSection> createState() => _OrgsSectionState();
}

class _OrgsSectionState extends State<_OrgsSection> {
  late bool _adding = widget.adding;

  /// Settings a new org starts from when it duplicates another (everything but name and folders).
  OrgConfig? _template;
  String? _selected;

  List<OrgConfig> get _orgs => widget.config.orgs;

  /// Falls back to the first org when the selection was renamed elsewhere or removed.
  OrgConfig? get _current => _orgs.where((o) => o.name == _selected).firstOrNull ?? _orgs.firstOrNull;

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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final current = _adding ? null : _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _SectionTitle(_Section.orgs.label, key: widget.anchor)),
            TextButton.icon(
              key: const ValueKey('settings-new-org-button'),
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => _select(null),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Nova org', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Muted(
            'Uma org reúne os projetos das pastas dela. Os repositórios dentro delas aparecem sozinhos.',
            size: 12,
          ),
        ),
        if (_adding)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Panel(
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
            ),
          ),
        for (final org in _orgs)
          Column(
            key: ValueKey('org-slot-${org.name}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _OrgRow(
                  org: org,
                  roots: orgRootsLabel(org.roots, widget.home),
                  summary: orgSummaryLine(org, widget.config),
                  projects: projectsInOrg(widget.projects, org.name).length,
                  selected: identical(org, current),
                  onTap: () => _select(org.name),
                ),
              ),
              if (identical(org, current))
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Panel(
                    key: ValueKey('settings-org-form-${org.name}'),
                    title: org.name,
                    trailing: TextButton.icon(
                      key: const ValueKey('settings-org-duplicate'),
                      style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                      onPressed: () => _duplicate(org),
                      icon: const Icon(Icons.copy_all_outlined, size: 15),
                      label: const Text('Duplicar', style: TextStyle(fontSize: 12)),
                    ),
                    child: OrgForm(
                      globalMode: widget.config.permissionMode,
                      globalBudget: widget.config.cycleBudget,
                      key: ValueKey(org.name),
                      initial: org,
                      others: [
                        for (final o in _orgs)
                          if (!identical(o, org)) o,
                      ],
                      onSave: (draft) => _update(org, draft),
                      onRemove: () => _remove(org),
                      onDirtyChanged: (dirty) => widget.unsaved.value = dirty,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _OrgRow extends StatelessWidget {
  const _OrgRow({
    required this.org,
    required this.roots,
    required this.summary,
    required this.projects,
    required this.selected,
    required this.onTap,
  });

  final OrgConfig org;
  final String roots;
  final String summary;
  final int projects;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: [org.name, ...org.roots].join('\n'),
      waitDuration: const Duration(milliseconds: 600),
      child: _CardFrame(
        key: ValueKey('settings-org-row-${org.name}'),
        selected: selected,
        onTap: onTap,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          org.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Muted(countLabel(projects, 'projeto'), size: 11),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          roots,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: c.textMuted),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: c.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(selected ? Icons.expand_more : Icons.chevron_right, size: 18, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({super.key, required this.selected, required this.onTap, required this.child});

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.elevated : c.surface,
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
  const _ProjectsSection({required this.anchor, required this.config, required this.projects});

  final GlobalKey anchor;
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
            Expanded(child: _SectionTitle(_Section.projects.label, key: widget.anchor)),
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
