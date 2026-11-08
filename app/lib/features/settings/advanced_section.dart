import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/config_mutations.dart';
import '../../data/flow_repository.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';

/// Engine location, Node and the palette's skills: closed by default, set once at install.
class AdvancedSection extends StatefulWidget {
  const AdvancedSection({super.key, required this.config});

  final DashboardConfig config;

  @override
  State<AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<AdvancedSection> {
  late final _engineDir = TextEditingController(text: widget.config.engineDir ?? '');
  late final _nodePath = TextEditingController(text: widget.config.nodePath ?? '');
  late final _skills = TextEditingController(text: widget.config.paletteSkills?.join(', ') ?? '');
  bool _open = false;
  bool _saving = false;
  bool _savedEngine = false;
  String? _error;

  @override
  void dispose() {
    _engineDir.dispose();
    _nodePath.dispose();
    _skills.dispose();
    super.dispose();
  }

  List<String> get _skillList => _skills.text.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toList();

  bool get _engineChanged =>
      _engineDir.text.trim() != (widget.config.engineDir ?? '') ||
      _nodePath.text.trim() != (widget.config.nodePath ?? '');

  bool get _dirty => _engineChanged || _skillList.join(',') != (widget.config.paletteSkills ?? const []).join(',');

  Future<void> _save() async {
    if (_engineDir.text.trim().isEmpty) {
      setState(() => _error = 'informe a pasta da engine: sem ela a engine não sobe');
      return;
    }
    final engineChanged = _engineChanged;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await RepositoryScope.of(
        context,
      ).updateConfig(setAdvanced(engineDir: _engineDir.text, nodePath: _nodePath.text, paletteSkills: _skillList));
      if (mounted) setState(() => _savedEngine = engineChanged);
    } on ConfigWriteException catch (e, st) {
      log('advanced write rejected', name: 'SettingsPage', error: e, stackTrace: st);
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget field(String key, String label, TextEditingController controller, String hint, String help) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        key: ValueKey('settings-advanced-$key'),
        controller: controller,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(labelText: label, hintText: hint, helperText: help, isDense: true),
      ),
    );
    return Panel(
      key: const ValueKey('settings-advanced'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('settings-advanced-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 18, color: c.textMuted),
                const SizedBox(width: 6),
                Text('Engine e paleta', style: TextStyle(fontSize: 13, color: c.textPrimary)),
                const SizedBox(width: 10),
                const Expanded(child: Muted('pasta da engine, Node e skills da ⌘K', size: 12)),
              ],
            ),
          ),
          if (_open) ...[
            const SizedBox(height: 16),
            field(
              'engine-dir',
              'Pasta da engine',
              _engineDir,
              'ex.: ~/development/claude-setup/engine',
              'pasta engine/ do claude-setup; vale ao reiniciar a engine',
            ),
            field('node-path', 'Node', _nodePath, 'padrão: node do PATH', 'caminho do executável do node'),
            field(
              'palette-skills',
              'Skills na paleta (⌘K)',
              _skills,
              'vazio: todas',
              'nomes separados por vírgula, ex.: fix, status, review',
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
              ),
            Row(
              children: [
                FilledButton(
                  key: const ValueKey('settings-advanced-save'),
                  style: FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white),
                  onPressed: _dirty && !_saving ? _save : null,
                  child: const Text('Salvar', style: TextStyle(fontSize: 12)),
                ),
                if (_savedEngine) ...[
                  const SizedBox(width: 12),
                  const Muted('salvo; a engine usa os novos caminhos ao reiniciar', size: 12),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: c.accent),
                    onPressed: () {
                      setState(() => _savedEngine = false);
                      unawaited(SessionsScope.engineOf(context).restart());
                    },
                    child: const Text('Reiniciar engine', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
