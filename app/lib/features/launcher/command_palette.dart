import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/image_attachments.dart';
import '../../core/widgets/model_menu.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../data/attention.dart';
import '../../data/docs_repository.dart';
import '../../data/docs_models.dart';
import '../../data/docs_parser.dart';
import '../../data/inventory_models.dart';
import '../../data/inventory_parser.dart';
import '../../data/inventory_repository.dart';
import '../../data/kickoff.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/search.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';
import 'kickoff_form.dart';

const _kickoffSkill = 'kickoff';

sealed class PaletteTarget {
  const PaletteTarget();
}

/// A session of a project. Without a [project] (unknown, or an org with no projects) the palette only lists
/// skills and nothing can be started.
class ProjectTarget extends PaletteTarget {
  const ProjectTarget(this.project);

  final Project? project;
}

/// An activity of an org: runs in the first root with the others as additional directories.
class OrgTarget extends PaletteTarget {
  const OrgTarget(this.org, this.cwd, this.additionalDirectories);

  /// `null` when the org is unknown or has no roots, so nothing can be started.
  static OrgTarget? of(OrgConfig? org) {
    final dirs = org == null ? null : orgSessionDirs(org);
    return dirs == null ? null : OrgTarget(org!.name, dirs.$1, dirs.$2);
  }

  final String org;
  final String cwd;
  final List<String> additionalDirectories;
}

/// [newConversation] skips the list and opens straight on the free prompt; [skill] opens on the arguments of
/// that command, without waiting for the engine to list it.
Future<void> showCommandPalette(
  BuildContext context,
  PaletteTarget target, {
  bool newConversation = false,
  String? skill,
}) {
  final router = GoRouter.of(context);
  final sessions = SessionsScope.of(context);
  final project = switch (target) {
    ProjectTarget(:final project) => project,
    OrgTarget() => null,
  };
  final org = switch (target) {
    ProjectTarget(:final project) => project?.org,
    OrgTarget(:final org) => org,
  };
  final config = context.read<ConfigCubit>().state.data;
  final githubAccount = githubFor(org, config).account;
  final jumps = _jumpIndex(context, project, org, config);
  // Read once, like ⌘J does: every org, and the route is relative to where the palette was opened.
  final pending = pendingAttention(
    context.read<SessionsCubit>().state.data ?? const [],
    context.read<ProjectsCubit>().state.data ?? const [],
  );
  final pendingRoute = nextAttentionRoute(pending, router.routerDelegate.currentConfiguration.uri.toString());
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _CommandPalette(
      target: target,
      sessions: sessions,
      githubAccount: githubAccount,
      agentOf: (command) => agentFor(org, config, command),
      permissionMode: effectivePermissionMode(null, org, config),
      startOnPrompt: newConversation && (target is OrgTarget || project != null),
      initialSkill: skill,
      onCreated: (s) => router.go(switch (target) {
        ProjectTarget() => '/p/${s.project}/sessions/${s.id}',
        OrgTarget(:final org) => orgSessionsLocation(org, session: s.id),
      }),
      onKickoff: () => showKickoffForm(context, project),
      pending: pending.length,
      onPending: pendingRoute == null ? null : () => router.go(pendingRoute),
      jumps: jumps,
      onJump: router.go,
    ),
  );
}

/// Something the palette search can open: a session, a document or an ADR.
class PaletteJump {
  const PaletteJump({
    required this.icon,
    required this.label,
    required this.caption,
    required this.route,
    this.keywords = const [],
  });

  final IconData icon;
  final String label;
  final String caption;
  final String route;

  /// Matched by the search besides [label] and [caption], never shown.
  final List<String> keywords;
}

const _conversationKey = 'palette-action-conversation';

/// Key of the entry a non-empty [query] selects: the first of [skills] (names of the visible shortcuts) whose name
/// starts with it, else `jump` (the first jump) when [hasJump], else the conversation action. Matching only the
/// phrase of a shortcut does not select it, so free text such as "revisar" does not land on `/review`.
String paletteSelection(String query, {required List<String> skills, required bool hasJump}) {
  final q = query.trim().toLowerCase();
  for (final name in skills) {
    if (name.toLowerCase().startsWith(q)) return 'palette-skill-$name';
  }
  return hasJump ? 'jump' : _conversationKey;
}

/// Sessions of the org, plus the documents and ADRs of [project]; a source that fails to load is left out.
Future<List<PaletteJump>> _jumpIndex(
  BuildContext context,
  Project? project,
  String? org,
  DashboardConfig? config,
) async {
  final projects = context.read<ProjectsCubit>().state.data ?? const <Project>[];
  final sessions = [
    for (final s in context.read<SessionsCubit>().state.data ?? const <SessionSummary>[])
      if (org == null || sessionOrg(s, projects, config) == org)
        PaletteJump(
          icon: Icons.chat_bubble_outline,
          label: s.title,
          caption: 'sessão · ${s.isOrgSession ? s.org : s.project} · ${s.command}',
          route: sessionRoute(s),
        ),
  ];
  if (project == null) return sessions;
  final docs = DocsScope.of(context);
  final inventory = InventoryScope.of(context);
  final (listing, adrs) = await (
    docs.list(project.name).catchError((Object _) => DocsListing.empty),
    inventory.loadProject(project).then((p) => p.adrs, onError: (Object _) => const <AdrEntry>[]),
  ).wait;
  return [
    ...sessions,
    for (final e in [...listing.artifacts, ...listing.details])
      PaletteJump(
        icon: Icons.description_outlined,
        label: docTitle(e.rel),
        caption: 'documento · ${project.name}',
        route: artifactsLocation(project.name, e.rel),
        keywords: [e.rel],
      ),
    // `?adr=<id>` cannot open an ADR whose id is empty or repeated, and the route is what identifies the entry.
    for (final a in adrs.where(adrSelectable))
      PaletteJump(
        icon: Icons.gavel_outlined,
        label: '${a.id} ${a.title}',
        caption: 'decisão · ${adrStatusLabel(a.status)}',
        route: '/p/${project.name}/adrs?adr=${Uri.encodeQueryComponent(a.id)}',
      ),
  ];
}

enum _Mode { list, args, prompt }

enum _EntryKind { action, skill, jump }

/// One line of the list. A disabled entry can be selected, but ↵ and a tap do nothing.
class _Entry {
  const _Entry(
    this.kind, {
    required this.key,
    required this.title,
    required this.onChoose,
    this.detail = '',
    this.icon,
    this.trailing,
    this.enabled = true,
  });

  final _EntryKind kind;
  final String key;
  final String title;
  final String detail;
  final IconData? icon;
  final String? trailing;
  final bool enabled;
  final VoidCallback onChoose;
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({
    required this.target,
    required this.sessions,
    required this.githubAccount,
    required this.agentOf,
    required this.permissionMode,
    required this.startOnPrompt,
    required this.initialSkill,
    required this.onCreated,
    required this.onKickoff,
    required this.pending,
    required this.onPending,
    required this.jumps,
    required this.onJump,
  });

  final PaletteTarget target;
  final SessionsRepository sessions;

  /// Of the target's org; `null` keeps the `gh` active account.
  final String? githubAccount;

  /// Agent of the session a command would start: the org's for a free prompt, Anthropic for a `/skill`.
  final OrgAgent Function(String command) agentOf;

  /// Effective mode of the target's org; changing it in the palette applies to this session only.
  final PermissionMode permissionMode;
  final bool startOnPrompt;

  /// Opens on the arguments of this command; the engine, not the listed skills, says whether it exists.
  final String? initialSkill;
  final void Function(SessionSummary session) onCreated;

  /// Runs after the palette closes; the kickoff form replaces it.
  final VoidCallback onKickoff;

  /// How many items wait on the user, in every org, when the palette opened.
  final int pending;

  /// Runs after the palette closes; `null` when nothing waits.
  final VoidCallback? onPending;

  /// What the search can open, besides skills; matched against the typed text from 2 characters on.
  final Future<List<PaletteJump>> jumps;
  final void Function(String route) onJump;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> with ImageAttachments<_CommandPalette> {
  final _field = TextEditingController();
  final _anchors = <String, GlobalKey>{};
  late _Mode _mode = widget.initialSkill != null
      ? _Mode.args
      : widget.startOnPrompt
      ? _Mode.prompt
      : _Mode.list;
  List<PaletteSkill> _skills = const [];
  String? _skillsError;
  late PaletteSkill? _skill = switch (widget.initialSkill) {
    final name? => PaletteSkill(name, ''),
    null => null,
  };
  int _index = 0;

  /// Set by ↑↓ and cleared by typing: while unset, the selection follows the text when the list changes shape.
  bool _navigated = false;
  bool _creating = false;
  String? _error;
  late PermissionMode _permissionMode = widget.permissionMode;

  /// Model picked per provider in this palette; a missing key keeps the org's (or the provider's) default.
  final _models = <AgentProvider, String?>{};

  /// Agent the current mode would start: the org's for a free prompt, Anthropic for a `/skill`.
  OrgAgent get _agent => widget.agentOf(_mode == _Mode.prompt ? 'prompt' : '/skill');

  OrgAgent _withChosenModel(OrgAgent agent) =>
      _models.containsKey(agent.provider) ? agent.withModel(_models[agent.provider]) : agent;

  List<PaletteJump> _allJumps = const [];

  @override
  void initState() {
    super.initState();
    _loadSkills();
    widget.jumps.then(
      (j) {
        if (!mounted) return;
        setState(() => _keepSelection(() => _allJumps = j));
      },
      onError: (Object e, StackTrace st) =>
          log('cannot index palette', name: 'CommandPalette', error: e, stackTrace: st),
    );
  }

  List<PaletteJump> get _jumps {
    final q = _field.text.trim();
    if (q.length < 2) return const [];
    return _allJumps.where((j) => matchesQuery([j.label, j.caption, ...j.keywords], q)).take(8).toList();
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _loadSkills() async {
    try {
      final skills = await widget.sessions.skills();
      if (!mounted) return;
      // The engine can list the same name twice (two folders, one `name:`), and the name is what identifies the entry.
      final names = <String>{};
      setState(
        () => _keepSelection(
          () => _skills = [
            for (final s in skills)
              if (names.add(s.name)) s,
          ],
        ),
      );
    } on Exception catch (e, st) {
      log('cannot list skills', name: 'CommandPalette', error: e, stackTrace: st);
      if (mounted) setState(() => _skillsError = '$e');
    }
  }

  void _onChanged(String _) => setState(() {
    _error = null;
    if (_mode != _Mode.list) return;
    _navigated = false;
    _select();
    _revealSelection();
  });

  /// Typing moves the selection to another entry without a ↑↓: the list keeps its old scroll offset.
  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final entries = _entries;
      final anchor = _anchors[entries[_selectedIn(entries)].key]?.currentContext;
      if (anchor == null) return;
      unawaited(Scrollable.ensureVisible(anchor, duration: const Duration(milliseconds: 100)));
    });
  }

  void _select() {
    final query = _field.text.trim();
    if (query.isEmpty) {
      _index = 0;
      return;
    }
    final entries = _entries;
    final key = paletteSelection(
      query,
      skills: [for (final s in _filtered) s.name],
      hasJump: entries.any((e) => e.kind == _EntryKind.jump),
    );
    _index = entries.indexWhere((e) => key == 'jump' ? e.kind == _EntryKind.jump : e.key == key);
  }

  /// After ↑↓ the selection is the entry, not its position: [change] can put shortcuts above it.
  void _keepSelection(VoidCallback change) {
    final before = _entries;
    final key = _mode == _Mode.list && _navigated ? before[_selectedIn(before)].key : null;
    change();
    if (key == null) return _reselect();
    final at = _entries.indexWhere((e) => e.key == key);
    if (at >= 0) {
      _index = at;
    } else {
      _select();
    }
  }

  /// Skills and jumps arrive after the first frame and shortcuts land above the jumps: without this, ↵ would
  /// choose another entry than the one the typed text had selected.
  void _reselect() {
    if (_mode == _Mode.list && !_navigated && _field.text.trim().isNotEmpty) _select();
  }

  Project? get _project => switch (widget.target) {
    ProjectTarget(:final project) => project,
    OrgTarget() => null,
  };

  bool get _canStart => widget.target is OrgTarget || _project != null;

  List<PaletteSkill> get _filtered {
    final q = _field.text;
    final orgMode = widget.target is OrgTarget;
    return _skills
        // `/kickoff` is the "Começar um ciclo" action, with its form; listed as a shortcut it would show twice.
        .where(
          (s) =>
              s.name != _kickoffSkill &&
              !(orgMode && kPipelineSkills.contains(s.name)) &&
              matchesQuery([s.name, skillLabel(s.name, s.description)], q),
        )
        .toList();
  }

  /// Actions, then shortcuts, then jumps: the only order ↑↓, ↵ and taps know.
  List<_Entry> get _entries {
    final canStart = _canStart;
    void close(VoidCallback? then) {
      Navigator.of(context).pop();
      then?.call();
    }

    return [
      if (widget.target is ProjectTarget)
        _Entry(
          _EntryKind.action,
          key: 'palette-action-start',
          title: 'Começar um ciclo',
          detail: canStart ? 'de um card ou de uma descrição' : 'sem projeto nesta org',
          enabled: canStart,
          onChoose: () => close(widget.onKickoff),
        ),
      _Entry(
        _EntryKind.action,
        key: _conversationKey,
        title: 'Nova conversa',
        detail: canStart ? 'perguntar ou pedir algo fora de um ciclo' : 'sem projeto nesta org',
        enabled: canStart,
        onChoose: () => _enter(_Mode.prompt, keepText: true),
      ),
      _Entry(
        _EntryKind.action,
        key: 'palette-action-pending',
        title: 'Ir para a próxima pendência',
        detail: pendingLine(widget.pending),
        trailing: '⌘J',
        enabled: widget.onPending != null,
        onChoose: () => close(widget.onPending),
      ),
      for (final s in _filtered)
        _Entry(
          _EntryKind.skill,
          key: 'palette-skill-${s.name}',
          title: skillLabel(s.name, s.description),
          trailing: '/${s.name}',
          enabled: canStart,
          onChoose: () => _enter(_Mode.args, skill: s),
        ),
      for (final j in _jumps)
        _Entry(
          _EntryKind.jump,
          key: 'palette-jump-${j.route}',
          title: j.label,
          detail: j.caption,
          icon: j.icon,
          onChoose: () => close(() => widget.onJump(j.route)),
        ),
    ];
  }

  int _selectedIn(List<_Entry> entries) => _index.clamp(0, entries.length - 1);

  void _enter(_Mode mode, {PaletteSkill? skill, bool keepText = false}) => setState(() {
    _mode = mode;
    _skill = skill;
    _error = null;
    _index = 0;
    _navigated = false;
    if (keepText) {
      _field.selection = TextSelection.collapsed(offset: _field.text.length);
    } else {
      _field.clear();
    }
  });

  void _move(int delta) {
    final entries = _entries;
    final from = _selectedIn(entries);
    final to = (from + delta) % entries.length;
    setState(() {
      _index = to;
      _navigated = true;
    });
    final anchor = _anchors[entries[to].key]?.currentContext;
    if (anchor == null) return;
    unawaited(
      Scrollable.ensureVisible(
        anchor,
        duration: const Duration(milliseconds: 100),
        alignmentPolicy: to > from
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ),
    );
  }

  void _submit() {
    switch (_mode) {
      case _Mode.list:
        final entries = _entries;
        final entry = entries[_selectedIn(entries)];
        if (entry.enabled) entry.onChoose();
      case _Mode.args:
        final args = _field.text.trim();
        _create(args.isEmpty ? '/${_skill!.name}' : '/${_skill!.name} $args');
      case _Mode.prompt:
        final prompt = _field.text.trim();
        if (prompt.isNotEmpty || images.isNotEmpty) _create(prompt.isEmpty ? kImagesOnlyText : prompt);
    }
  }

  Future<void> _create(String command) async {
    if (_creating) return;
    final target = widget.target;
    if (target is ProjectTarget) {
      final project = target.project;
      if (project == null) return;
      if (project.path == null) {
        setState(() => _error = missingProjectPathError(project));
        return;
      }
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final session = switch (target) {
        ProjectTarget(project: final project!) => await widget.sessions.create(
          project.name,
          command,
          cwd: project.path,
          githubAccount: widget.githubAccount,
          permissionMode: _permissionMode,
          agent: _withChosenModel(widget.agentOf(command)),
          images: _mode == _Mode.prompt ? images : const [],
        ),
        OrgTarget() => await widget.sessions.createInOrg(
          target.org,
          command,
          cwd: target.cwd,
          additionalDirectories: target.additionalDirectories,
          githubAccount: widget.githubAccount,
          permissionMode: _permissionMode,
          agent: _withChosenModel(widget.agentOf(command)),
          images: _mode == _Mode.prompt ? images : const [],
        ),
      };
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onCreated(session);
    } on Exception catch (e, st) {
      log('cannot create session', name: 'CommandPalette', error: e, stackTrace: st);
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _back() {
    if (_creating) return;
    if (_mode == _Mode.list || widget.startOnPrompt) {
      Navigator.of(context).pop();
    } else {
      _enter(_Mode.list);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _back();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) _submit();
      return KeyEventResult.handled;
    }
    if (_mode == _Mode.prompt) return onPasteKey(node, event);
    if (_mode != _Mode.list) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entries = _entries;
    final selected = _selectedIn(entries);
    Widget item(int i) {
      final e = entries[i];
      return KeyedSubtree(
        key: _anchors.putIfAbsent(e.key, GlobalKey.new),
        child: _Item(
          key: ValueKey(e.key),
          selected: i == selected,
          onTap: e.enabled ? e.onChoose : null,
          title: e.title,
          detail: e.detail,
          icon: e.icon,
          trailing: e.trailing,
          action: e.kind == _EntryKind.action,
        ),
      );
    }

    List<Widget> items(_EntryKind kind) => [
      for (final (i, e) in entries.indexed)
        if (e.kind == kind) item(i),
    ];
    final shortcuts = items(_EntryKind.skill);
    final jumps = items(_EntryKind.jump);
    return PopScope(
      canPop: !_creating,
      child: Align(
        alignment: const Alignment(0, -0.5),
        child: Material(
          color: c.elevated,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Focus(
            onKeyEvent: _onKey,
            child: imageDropTarget(
              context,
              enabled: _mode == _Mode.prompt && !_creating,
              child: Container(
                width: 560,
                decoration: BoxDecoration(
                  border: Border.all(color: c.borderStrong),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: TextField(
                        controller: _field,
                        autofocus: true,
                        readOnly: _creating,
                        onChanged: _onChanged,
                        style: const TextStyle(fontSize: 15),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: switch (_mode) {
                            _Mode.list => switch (widget.target) {
                              OrgTarget(:final org) => 'O que você quer fazer em $org?',
                              ProjectTarget(project: final p?) => 'O que você quer fazer em ${p.name}?',
                              ProjectTarget() => 'O que você quer fazer?',
                            },
                            _Mode.args => 'argumentos (opcional)',
                            _Mode.prompt => switch (widget.target) {
                              OrgTarget(:final org) => 'Nova conversa em $org: escreva o prompt',
                              ProjectTarget(:final project) => 'Nova conversa em ${project!.name}: escreva o prompt',
                            },
                          },
                          hintStyle: TextStyle(color: c.textMuted),
                          suffixIcon: _mode == _Mode.prompt
                              ? IconButton(
                                  key: const ValueKey('palette-attach'),
                                  tooltip: 'Anexar imagem (ou cole com ⌘V)',
                                  onPressed: _creating ? null : pickImages,
                                  icon: Icon(Icons.add_photo_alternate_outlined, size: 18, color: c.textSecondary),
                                )
                              : null,
                          prefixIcon: _mode == _Mode.args
                              ? Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Center(
                                    widthFactor: 1,
                                    child: Mono('/${_skill!.name}', color: c.accent, size: 14),
                                  ),
                                )
                              : Icon(
                                  _mode == _Mode.list ? Icons.search : Icons.chat_bubble_outline,
                                  color: c.textMuted,
                                  size: 18,
                                ),
                        ),
                      ),
                    ),
                    if (_mode == _Mode.prompt)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: imagesPreview(context, keyPrefix: 'palette-image'),
                      ),
                    if (_error case final error?)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
                      ),
                    if (_mode == _Mode.list) ...[
                      Divider(height: 1, color: c.border),
                      // Fixed height: filtering would otherwise resize the dialog on every keystroke.
                      SizedBox(
                        height: 360,
                        // Not a lazy list: the selected entry has to exist to be scrolled into view.
                        child: SingleChildScrollView(
                          key: const ValueKey('palette-list'),
                          padding: const EdgeInsets.all(6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ...items(_EntryKind.action),
                              if (_skillsError case final error?)
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                  child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
                                ),
                              if (shortcuts.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                                  child: Muted(
                                    widget.target is OrgTarget ? 'Atalhos da org' : 'Atalhos do projeto',
                                    size: 11,
                                  ),
                                ),
                                ...shortcuts,
                              ],
                              if (jumps.isNotEmpty) ...[
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
                                  child: Muted('Ir para', size: 11),
                                ),
                                ...jumps,
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.border)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Muted(
                              _mode == _Mode.list
                                  ? 'Digite para buscar conversas, documentos e decisões · esc fecha'
                                  : '↵ iniciar · esc voltar · permissões aparecem na aba Sessões',
                              size: 11,
                            ),
                          ),
                          if (_canStart) ...[
                            ModelMenu(
                              key: ValueKey('palette-model-${_agent.provider.wire}'),
                              provider: _agent.provider,
                              account: _agent.account,
                              model: _withChosenModel(_agent).model,
                              tooltip: 'Modelo desta sessão',
                              onSelected: _creating ? null : (m) => setState(() => _models[_agent.provider] = m),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (_canStart)
                            PermissionModeMenu(
                              key: const ValueKey('palette-permission-mode'),
                              mode: _permissionMode,
                              tooltip: 'Permissões desta sessão',
                              onSelected: _creating ? null : (m) => setState(() => _permissionMode = m),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    super.key,
    required this.selected,
    required this.onTap,
    required this.title,
    required this.detail,
    required this.icon,
    required this.trailing,
    required this.action,
  });

  final bool selected;

  /// `null` renders the entry disabled.
  final VoidCallback? onTap;
  final String title;
  final String detail;
  final IconData? icon;
  final String? trailing;

  /// One of the fixed actions at the top, which read as the heavier lines.
  final bool action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: action ? FontWeight.w600 : null,
        color: onTap == null ? c.textMuted : c.textPrimary,
      ),
    );
    return Material(
      color: selected ? c.hover : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              if (icon case final icon?) ...[Icon(icon, size: 14, color: c.textMuted), const SizedBox(width: 8)],
              if (detail.isEmpty)
                Expanded(child: label)
              else ...[
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: label),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: action ? c.textSecondary : c.textMuted),
                  ),
                ),
              ],
              if (trailing case final trailing?) ...[const SizedBox(width: 12), Mono(trailing, color: c.textMuted)],
              if (selected && onTap != null) ...[const SizedBox(width: 8), Mono('↵', color: c.textMuted)],
            ],
          ),
        ),
      ),
    );
  }
}
