import 'dart:developer';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/orgs.dart';
import '../../engine/engine_config.dart';

/// Name + folders of one org, validated against [others] before [onSave]. Shared by the landing's
/// "Criar org" (`maxRoots: 1`, with [suggestions]) and each org in Configurações.
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
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
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
    final draft = OrgConfig(name: _name.text.trim(), roots: _roots);
    final error = _roots.isEmpty ? 'escolha uma pasta para a org' : validateOrgs([...widget.others, draft]);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await _run(() => widget.onSave(draft));
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
          onSubmitted: (_) => _busy ? null : _save(),
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
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 12, color: c.fail)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
              onPressed: _busy ? null : _save,
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
