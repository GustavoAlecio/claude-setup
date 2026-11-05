import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/kickoff.dart';
import '../../data/models.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';

/// Without a [project] there is nowhere to start the session, so nothing opens.
Future<void> showKickoffForm(BuildContext context, Project? project) async {
  if (project == null) return;
  final router = GoRouter.of(context);
  final sessions = SessionsScope.of(context);
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _KickoffForm(
      project: project,
      sessions: sessions,
      onCreated: (s) => router.go('/p/${s.project}/sessions/${s.id}'),
    ),
  );
}

class _KickoffForm extends StatefulWidget {
  const _KickoffForm({required this.project, required this.sessions, required this.onCreated});

  final Project project;
  final SessionsRepository sessions;
  final void Function(SessionSummary session) onCreated;

  @override
  State<_KickoffForm> createState() => _KickoffFormState();
}

class _KickoffFormState extends State<_KickoffForm> {
  final _id = TextEditingController();
  final _description = TextEditingController();
  var _type = KickoffType.auto;
  String? _idError;
  String? _descriptionError;
  String? _error;
  bool _creating = false;

  bool get _hasId => _id.text.trim().isNotEmpty;

  bool get _tooLong => _description.text.length > kKickoffMaxChars;

  @override
  void dispose() {
    _id.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_creating) return;
    final project = widget.project;
    String? id;
    if (_hasId) {
      id = normalizeCardId(_id.text);
      if (id == null) {
        setState(() => _idError = 'ID inválido');
        return;
      }
    } else if (_description.text.trim().isEmpty) {
      setState(() => _descriptionError = 'descreva o card ou informe um ID');
      return;
    } else if (_tooLong) {
      return;
    }
    if (project.path == null) {
      setState(() => _error = missingProjectPathError(project));
      return;
    }
    final command = kickoffCommand(id: id, description: _description.text, type: _type);
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final session = await widget.sessions.create(project.name, command, cwd: project.path);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onCreated(session);
    } on Exception catch (e, st) {
      log('cannot create kickoff session', name: 'KickoffForm', error: e, stackTrace: st);
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasId = _hasId;
    final length = _description.text.length;
    // Closing mid-create would orphan the session the engine is already starting.
    return PopScope(
      canPop: !_creating,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): _submit,
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (!_creating) Navigator.of(context).pop();
          },
        },
        child: Align(
          alignment: const Alignment(0, -0.5),
          child: Material(
            color: c.elevated,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Container(
              width: 560,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              decoration: BoxDecoration(
                border: Border.all(color: c.borderStrong),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Novo kickoff em ${widget.project.name}', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 14),
                  CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): _submit,
                      const SingleActivator(LogicalKeyboardKey.numpadEnter): _submit,
                    },
                    child: TextField(
                      key: const ValueKey('kickoff-id'),
                      controller: _id,
                      autofocus: true,
                      readOnly: _creating,
                      onChanged: (_) => setState(() {
                        _idError = null;
                        _error = null;
                      }),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'ID do card',
                        hintText: 'opcional · 123 ou LC-101',
                        hintStyle: TextStyle(color: c.textMuted),
                        errorText: _idError,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('kickoff-description'),
                    controller: _description,
                    enabled: !hasId,
                    readOnly: _creating,
                    minLines: 5,
                    maxLines: 12,
                    keyboardType: TextInputType.multiline,
                    onChanged: (_) => setState(() {
                      _descriptionError = null;
                      _error = null;
                    }),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Descrição',
                      alignLabelWithHint: true,
                      helperText: hasId ? 'ignorado com ID' : null,
                      counterText: '$length/$kKickoffMaxChars',
                      errorText: hasId
                          ? null
                          : _tooLong
                          ? 'descrição acima de $kKickoffMaxChars caracteres'
                          : _descriptionError,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SegmentedButton<KickoffType>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: KickoffType.auto, label: Text('Automático')),
                          ButtonSegment(value: KickoffType.feature, label: Text('Feature')),
                          ButtonSegment(value: KickoffType.bug, label: Text('Bug')),
                        ],
                        selected: {_type},
                        onSelectionChanged: hasId || _creating ? null : (s) => setState(() => _type = s.first),
                      ),
                      if (hasId) ...[
                        const SizedBox(width: 12),
                        const Flexible(child: Muted('ignorado com ID', size: 11)),
                      ],
                    ],
                  ),
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
                    ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Expanded(child: Muted('⌘↵ iniciar · esc fechar · roda no engine local', size: 11)),
                      TextButton(
                        onPressed: _creating ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancelar'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
                        onPressed: _creating ? null : _submit,
                        child: const Text('Iniciar'),
                      ),
                    ],
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
