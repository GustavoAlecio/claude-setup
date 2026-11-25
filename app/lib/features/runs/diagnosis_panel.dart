import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/session_launcher.dart';
import '../../data/flow_aggregates.dart';
import '../../data/kickoff.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_models.dart';
import '../launcher/command_palette.dart';

const _actions = {
  'fix_spec': ('Corrigir spec', '/challenge-spec'),
  'replan': ('Replanejar', '/plan'),
  'fix_environment': ('Corrigir ambiente', '/implement'),
  'split_task': ('Quebrar task', '/tasks'),
  _takeover: ('Assumir a task', null),
};

const _takeover = 'human_takeover';

const _notes = {
  DiagnosisKind.answer: 'A conversa da etapa já está perguntando isto: responda lá.',
  DiagnosisKind.busy: 'Já há uma conversa do pipeline rodando neste projeto.',
};

const _reasons = {
  'same_failure_across_tiers':
      'A mesma falha sobreviveu a dois modelos diferentes — não é capacidade, é spec ou plano.',
  'ladder_exhausted': 'A escada chegou ao topo (fable) sem passar nos gates.',
  'max_attempts': 'Limite de 5 tentativas atingido.',
  'agent_failed':
      'Um agente caiu (parado, limite de uso ou erro de API). Não diz nada sobre a task: rode /implement de novo.',
};

/// The decision buttons do what [diagnosisMode] says for [task] in [run].
class DiagnosisPanel extends StatefulWidget {
  const DiagnosisPanel({super.key, required this.task, required this.run, required this.project, this.onExpand});

  final TaskRun task;
  final Run run;

  /// `null` while the project is unknown: the buttons do nothing.
  final Project? project;

  /// Set when the panel is shown outside the task detail: only the top hypothesis is rendered.
  final VoidCallback? onExpand;

  @override
  State<DiagnosisPanel> createState() => _DiagnosisPanelState();
}

class _DiagnosisPanelState extends State<DiagnosisPanel> with SessionLauncher<DiagnosisPanel> {
  String? _pathError;
  String? _lastKey;

  @override
  String get logName => 'DiagnosisPanel';

  void _launch(Project project, String action, String command) {
    final config = context.read<ConfigCubit>().state.data;
    final cwd = project.path;
    if (cwd == null) {
      setState(() => _pathError = missingProjectPathError(project));
      return;
    }
    final key = '${widget.task.id}:$action';
    setState(() {
      _pathError = null;
      _lastKey = key;
    });
    unawaited(
      launchSession(
        key,
        project.name,
        command,
        cwd: cwd,
        githubAccount: githubFor(project.org, config).account,
        permissionMode: effectivePermissionMode(null, project.org, config),
      ),
    );
  }

  VoidCallback? _onPressed(DiagnosisMode mode, String action) {
    final project = widget.project;
    if (project == null || mode.kind == DiagnosisKind.inert || isCreatingAny) return null;
    if (action == _takeover) return () => showCommandPalette(context, ProjectTarget(project));
    final command = _actions[action]?.$2;
    if (command == null) return null;
    return switch (mode.kind) {
      DiagnosisKind.launch => () => _launch(project, action, command),
      DiagnosisKind.answer => () => context.go(mode.route!),
      DiagnosisKind.busy || DiagnosisKind.inert => null,
    };
  }

  Widget _button(DiagnosisMode mode, Hypothesis h, {required bool primary}) => _ActionButton(
    buttonKey: ValueKey(
      widget.onExpand == null ? 'diagnosis-action-${h.action}' : 'diagnosis-action-${widget.run.id}-${h.action}',
    ),
    action: h.action,
    primary: primary,
    onPressed: _onPressed(mode, h.action),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final task = widget.task;
    final onExpand = widget.onExpand;
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final mode = diagnosisMode(widget.project, task, widget.run, sessions);
    final note = _notes[mode.kind];
    final lastKey = _lastKey;
    final error = _pathError ?? (lastKey == null ? null : createError(lastKey));
    final ranked = [...task.diagnosis]..sort((a, b) => b.confidence.compareTo(a.confidence));
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.fail.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.account_tree_outlined, size: 18, color: c.fail),
              const SizedBox(width: 8),
              Text('${task.id} bloqueada · diagnóstico', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 10),
              Mono(task.blockedReason ?? '', color: c.fail, size: 11),
            ],
          ),
          const SizedBox(height: 6),
          Muted(_reasons[task.blockedReason] ?? '', size: 12),
          const SizedBox(height: 14),
          if (onExpand != null && ranked.isNotEmpty)
            _CompactTop(
              h: ranked.first,
              others: ranked.length - 1,
              onExpand: onExpand,
              button: _button(mode, ranked.first, primary: true),
            )
          else
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, h) in ranked.indexed) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: _HypothesisCard(
                        h: h,
                        top: i == 0,
                        button: _button(mode, h, primary: i == 0),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Muted(note, key: const ValueKey('diagnosis-note'), size: 12),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error,
                key: const ValueKey('diagnosis-error'),
                style: TextStyle(fontSize: 12, color: c.fail),
              ),
            ),
        ],
      ),
    );
  }
}

class _HypothesisCard extends StatelessWidget {
  const _HypothesisCard({required this.h, required this.top, required this.button});

  final Hypothesis h;
  final bool top;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: top ? c.accent.withValues(alpha: 0.6) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(label: 'ângulo: ${h.lens}', color: top ? c.accent : c.idle, dot: false),
              const Spacer(),
              Mono('${(h.confidence * 100).round()}%', color: c.textPrimary),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: h.confidence,
              minHeight: 3,
              backgroundColor: c.border,
              color: top ? c.accent : c.idle,
            ),
          ),
          const SizedBox(height: 12),
          Text(h.hypothesis, style: TextStyle(fontSize: 12.5, height: 1.45, color: c.textPrimary)),
          const SizedBox(height: 10),
          for (final e in h.evidence)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Muted('↳ ', size: 11),
                  Expanded(child: Mono(e, size: 11)),
                ],
              ),
            ),
          const Spacer(),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: button),
        ],
      ),
    );
  }
}

class _CompactTop extends StatelessWidget {
  const _CompactTop({required this.h, required this.others, required this.onExpand, required this.button});

  final Hypothesis h;
  final int others;
  final VoidCallback onExpand;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Pill(label: 'ângulo: ${h.lens}', color: c.accent, dot: false),
              const SizedBox(height: 6),
              Mono('${(h.confidence * 100).round()}% confiança', color: c.textPrimary, size: 11),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              h.hypothesis,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: c.textPrimary),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(width: 200, child: button),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onExpand,
            child: Text('ver as ${others + 1} hipóteses', style: TextStyle(fontSize: 12, color: c.textSecondary)),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.buttonKey, required this.action, required this.primary, required this.onPressed});

  final Key buttonKey;
  final String action;
  final bool primary;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (label, command) = _actions[action] ?? (action, null);
    return OutlinedButton(
      key: buttonKey,
      style: OutlinedButton.styleFrom(
        foregroundColor: primary ? c.accent : c.textSecondary,
        side: BorderSide(color: onPressed == null ? c.border : (primary ? c.accent : c.borderStrong)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      onPressed: onPressed,
      child: Text(command == null ? label : '$label  $command', style: const TextStyle(fontSize: 12)),
    );
  }
}
