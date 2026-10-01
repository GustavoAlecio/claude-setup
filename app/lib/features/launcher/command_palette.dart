import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';

/// [newConversation] skips the skill list and opens straight on the free prompt.
Future<void> showCommandPalette(BuildContext context, String project, {bool newConversation = false}) {
  final router = GoRouter.of(context);
  final sessions = SessionsScope.of(context);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _CommandPalette(
      project: project,
      sessions: sessions,
      startOnPrompt: newConversation,
      onCreated: (s) => router.go('/p/${s.project}/sessions/${s.id}'),
    ),
  );
}

enum _Mode { list, args, prompt }

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({
    required this.project,
    required this.sessions,
    required this.startOnPrompt,
    required this.onCreated,
  });

  final String project;
  final SessionsRepository sessions;
  final bool startOnPrompt;
  final void Function(SessionSummary session) onCreated;

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

  List<PaletteSkill> get _filtered {
    final q = _field.text.trim().toLowerCase();
    return _skills.where((s) => s.name.toLowerCase().contains(q)).toList();
  }

  /// Skills plus the fixed "Nova conversa" entry at the end.
  int get _count => _filtered.length + 1;

  void _enter(_Mode mode, {PaletteSkill? skill}) => setState(() {
    _mode = mode;
    _skill = skill;
    _error = null;
    _field.clear();
  });

  void _choose(int index) {
    final filtered = _filtered;
    if (index < filtered.length) {
      _enter(_Mode.args, skill: filtered[index]);
    } else {
      _enter(_Mode.prompt);
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
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final session = await widget.sessions.create(widget.project, command);
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
    return Align(
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
                        _Mode.list => 'Executar skill em ${widget.project}…',
                        _Mode.args => 'argumentos (opcional)',
                        _Mode.prompt => 'Nova conversa em ${widget.project}: escreva o prompt',
                      },
                      hintStyle: TextStyle(color: c.textMuted),
                      prefixIcon: _mode == _Mode.args
                          ? Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Center(widthFactor: 1, child: Mono('/${_skill!.name}', color: c.accent, size: 14)),
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
                            onTap: () => _choose(i),
                            leading: Mono('/${s.name}', color: c.textPrimary, size: 13),
                            description: s.description,
                          ),
                        if (_skillsError case final error?)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                            child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
                          ),
                        _Item(
                          selected: _index == _count - 1,
                          onTap: () => _choose(_count - 1),
                          leading: Text(
                            'Nova conversa em ${widget.project}',
                            style: TextStyle(fontSize: 13, color: c.textPrimary),
                          ),
                          description: 'prompt livre',
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
                  child: Muted(
                    _mode == _Mode.list
                        ? '↑↓ navegar · ↵ escolher · esc fechar · roda no engine local'
                        : '↵ iniciar · esc voltar · permissões aparecem na aba Sessões',
                    size: 11,
                  ),
                ),
              ],
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
  final VoidCallback onTap;
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
              if (selected) Mono('↵', color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
