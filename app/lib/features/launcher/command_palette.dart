import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../data/kickoff.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
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

/// [newConversation] skips the skill list and opens straight on the free prompt.
Future<void> showCommandPalette(BuildContext context, PaletteTarget target, {bool newConversation = false}) {
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
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _CommandPalette(
      target: target,
      sessions: sessions,
      githubAccount: githubAccount,
      permissionMode: effectivePermissionMode(null, org, config),
      startOnPrompt: newConversation && (target is OrgTarget || project != null),
      onCreated: (s) => router.go(switch (target) {
        ProjectTarget() => '/p/${s.project}/sessions/${s.id}',
        OrgTarget(:final org) => orgSessionsLocation(org, session: s.id),
      }),
      onKickoff: () => showKickoffForm(context, project),
    ),
  );
}

enum _Mode { list, args, prompt }

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({
    required this.target,
    required this.sessions,
    required this.githubAccount,
    required this.permissionMode,
    required this.startOnPrompt,
    required this.onCreated,
    required this.onKickoff,
  });

  final PaletteTarget target;
  final SessionsRepository sessions;

  /// Of the target's org; `null` keeps the `gh` active account.
  final String? githubAccount;

  /// Effective mode of the target's org; changing it in the palette applies to this session only.
  final PermissionMode permissionMode;
  final bool startOnPrompt;
  final void Function(SessionSummary session) onCreated;

  /// Runs after the palette closes; the kickoff form replaces it.
  final VoidCallback onKickoff;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _field = TextEditingController();
  late _Mode _mode = widget.startOnPrompt ? _Mode.prompt : _Mode.list;
  List<PaletteSkill> _skills = const [];
  String? _skillsError;
  PaletteSkill? _skill;
  int _index = 0;
  bool _creating = false;
  String? _error;
  late PermissionMode _permissionMode = widget.permissionMode;

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _loadSkills() async {
    try {
      final skills = await widget.sessions.skills();
      if (mounted) setState(() => _skills = skills);
    } on Exception catch (e, st) {
      log('cannot list skills', name: 'CommandPalette', error: e, stackTrace: st);
      if (mounted) setState(() => _skillsError = '$e');
    }
  }

  void _onChanged(String _) => setState(() {
    _error = null;
    if (_mode == _Mode.list) _index = 0;
  });

  Project? get _project => switch (widget.target) {
    ProjectTarget(:final project) => project,
    OrgTarget() => null,
  };

  bool get _canStart => widget.target is OrgTarget || _project != null;

  List<PaletteSkill> get _filtered {
    final q = _field.text.trim().toLowerCase();
    final orgMode = widget.target is OrgTarget;
    return _skills
        .where((s) => s.name.toLowerCase().contains(q) && !(orgMode && kPipelineSkills.contains(s.name)))
        .toList();
  }

  /// Skills plus the fixed "Novo kickoff" (projects only) and "Nova conversa" entries at the end.
  int get _count => _filtered.length + (widget.target is OrgTarget ? 1 : 2);

  void _enter(_Mode mode, {PaletteSkill? skill}) => setState(() {
    _mode = mode;
    _skill = skill;
    _error = null;
    _field.clear();
  });

  void _choose(int index) {
    if (!_canStart) return;
    final filtered = _filtered;
    if (widget.target is OrgTarget) {
      if (index == filtered.length) {
        _enter(_Mode.prompt);
      } else {
        _enter(_Mode.args, skill: filtered[index]);
      }
    } else if (index == filtered.length + 1) {
      _enter(_Mode.prompt);
    } else if (index == filtered.length || filtered[index].name == _kickoffSkill) {
      Navigator.of(context).pop();
      widget.onKickoff();
    } else {
      _enter(_Mode.args, skill: filtered[index]);
    }
  }

  void _submit() {
    switch (_mode) {
      case _Mode.list:
        _choose(_index);
      case _Mode.args:
        final args = _field.text.trim();
        _create(args.isEmpty ? '/${_skill!.name}' : '/${_skill!.name} $args');
      case _Mode.prompt:
        final prompt = _field.text.trim();
        if (prompt.isNotEmpty) _create(prompt);
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
        ),
        OrgTarget() => await widget.sessions.createInOrg(
          target.org,
          command,
          cwd: target.cwd,
          additionalDirectories: target.additionalDirectories,
          githubAccount: widget.githubAccount,
          permissionMode: _permissionMode,
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

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
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
    if (_mode != _Mode.list) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _index = (_index + 1) % _count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _index = (_index - 1 + _count) % _count);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
                            OrgTarget(:final org) => 'Atividade em $org…',
                            ProjectTarget(project: final p?) => 'Executar skill em ${p.name}…',
                            ProjectTarget() => 'Skills (sem projeto nesta org)',
                          },
                          _Mode.args => 'argumentos (opcional)',
                          _Mode.prompt => switch (widget.target) {
                            OrgTarget(:final org) => 'Nova conversa em $org: escreva o prompt',
                            ProjectTarget(:final project) => 'Nova conversa em ${project!.name}: escreva o prompt',
                          },
                        },
                        hintStyle: TextStyle(color: c.textMuted),
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
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
                    ),
                  if (_mode == _Mode.list) ...[
                    Divider(height: 1, color: c.border),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(6),
                        children: [
                          for (final (i, s) in _filtered.indexed)
                            _Item(
                              selected: i == _index,
                              onTap: _canStart ? () => _choose(i) : null,
                              leading: Mono('/${s.name}', color: c.textPrimary, size: 13),
                              description: s.description,
                            ),
                          if (_skillsError case final error?)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                              child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
                            ),
                          if (widget.target is ProjectTarget)
                            _Item(
                              selected: _index == _count - 2,
                              onTap: _canStart ? () => _choose(_count - 2) : null,
                              leading: Text(
                                'Novo kickoff',
                                style: TextStyle(fontSize: 13, color: _canStart ? c.textPrimary : c.textMuted),
                              ),
                              description: _canStart ? 'ID do card ou descrição' : 'sem projeto',
                            ),
                          _Item(
                            selected: _index == _count - 1,
                            onTap: _canStart ? () => _choose(_count - 1) : null,
                            leading: Text(switch (widget.target) {
                              OrgTarget(:final org) => 'Nova conversa em $org',
                              ProjectTarget(project: final p?) => 'Nova conversa em ${p.name}',
                              ProjectTarget() => 'Nova conversa',
                            }, style: TextStyle(fontSize: 13, color: _canStart ? c.textPrimary : c.textMuted)),
                            description: _canStart ? 'prompt livre' : 'nenhum projeto nesta org',
                          ),
                        ],
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
                                ? '↑↓ navegar · ↵ escolher · esc fechar · roda no engine local'
                                : '↵ iniciar · esc voltar · permissões aparecem na aba Sessões',
                            size: 11,
                          ),
                        ),
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
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.selected, required this.onTap, required this.leading, required this.description});

  final bool selected;

  /// `null` renders the entry disabled.
  final VoidCallback? onTap;
  final Widget leading;
  final String description;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
              leading,
              const SizedBox(width: 14),
              Expanded(child: Muted(description)),
              if (selected && onTap != null) Mono('↵', color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
