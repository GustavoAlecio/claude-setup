import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// `PopupMenuButton` treats a `null` value as a cancel, so "provider default" travels as this sentinel.
const _kDefault = '';

/// Model picker for [provider] (and the Antigravity [account]), listing what the engine reports. [model] `null` is
/// the provider default, offered only when [allowDefault]; [onSelected] `null` disables the menu.
class ModelMenu extends StatefulWidget {
  const ModelMenu({
    super.key,
    required this.provider,
    this.account,
    required this.model,
    required this.onSelected,
    this.allowDefault = true,
    this.tooltip = 'Modelo',
    this.color,
  });

  final AgentProvider provider;
  final String? account;
  final String? model;
  final ValueChanged<String?>? onSelected;
  final bool allowDefault;
  final String tooltip;

  /// Tint of the chip; `textSecondary` when `null`.
  final Color? color;

  @override
  State<ModelMenu> createState() => _ModelMenuState();
}

class _ModelMenuState extends State<ModelMenu> {
  List<AgentModel>? _models;
  String? _error;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_generation == 0) unawaited(_load());
  }

  @override
  void didUpdateWidget(ModelMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider || oldWidget.account != widget.account) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final sessions = SessionsScope.of(context);
    setState(() {
      _models = null;
      _error = null;
    });
    try {
      final models = switch (widget.provider) {
        AgentProvider.anthropic => await sessions.claudeModels(),
        AgentProvider.antigravity => await sessions.agentModels(widget.account ?? kDefaultAgentAccount),
      };
      if (mounted && generation == _generation) setState(() => _models = models);
    } on SessionsException catch (e, st) {
      log('models unavailable', name: 'ModelMenu', error: e, stackTrace: st);
      if (mounted && generation == _generation) setState(() => _error = e.message);
    }
  }

  String _label(String? model) {
    if (model == null) return 'modelo padrão';
    return _models?.where((m) => m.id == model).firstOrNull?.label ?? model;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final models = _models;
    final enabled = widget.onSelected != null;
    final current = models?.where((m) => m.id == widget.model).firstOrNull;
    // The session's own model ran out: the chip says so before the next turn fails.
    final exhausted = current?.quota?.exhausted ?? false;
    final tint = exhausted ? c.warn : widget.color ?? c.textSecondary;
    return PopupMenuButton<String>(
      tooltip: exhausted ? '${widget.tooltip} · ${current!.quota!.label(DateTime.now())}' : widget.tooltip,
      enabled: enabled,
      color: c.elevated,
      initialValue: widget.model ?? _kDefault,
      onSelected: (value) => widget.onSelected?.call(value == _kDefault ? null : value),
      itemBuilder: (_) => [
        if (widget.allowDefault)
          const PopupMenuItem(
            value: _kDefault,
            height: 36,
            child: Text('modelo padrão', style: TextStyle(fontSize: 13)),
          ),
        if (models == null)
          PopupMenuItem(
            enabled: false,
            height: 36,
            child: Text(_error ?? 'carregando modelos…', style: TextStyle(fontSize: 12, color: c.textMuted)),
          )
        else
          for (final m in models)
            PopupMenuItem(
              value: m.id,
              height: m.quota == null ? 44 : 56,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(m.label, style: const TextStyle(fontSize: 13)),
                  Text(
                    m.id,
                    style: TextStyle(fontFamily: monoFamily, fontSize: 10, color: c.textMuted),
                  ),
                  if (m.quota case final quota?)
                    Text(
                      quota.label(DateTime.now()),
                      style: TextStyle(fontSize: 10, color: quota.exhausted ? c.warn : c.textSecondary),
                    ),
                ],
              ),
            ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
        decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.memory, size: 12, color: tint),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                _label(widget.model),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tint, fontSize: 11, fontFamily: monoFamily),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 14, color: enabled ? tint : c.textMuted),
          ],
        ),
      ),
    );
  }
}
