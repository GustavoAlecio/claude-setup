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

const _noHypotheses = 'O diagnóstico não trouxe hipóteses. Use a paleta para seguir.';

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
  bool _showOthers = false;

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

  Widget _button(DiagnosisMode mode, String action, {required bool primary, bool filled = false}) => _ActionButton(
    buttonKey: ValueKey(
      widget.onExpand == null ? 'diagnosis-action-$action' : 'diagnosis-action-${widget.run.id}-$action',
    ),
    action: action,
    primary: primary,
    filled: filled,
    onPressed: _onPressed(mode, action),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final mode = diagnosisMode(widget.project, widget.task, widget.run, sessions);
    final note = _notes[mode.kind];
    final lastKey = _lastKey;
    final error = _pathError ?? (lastKey == null ? null : createError(lastKey));
    final ranked = rankedHypotheses(widget.task);
    final feedback = [
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
    ];
    final onExpand = widget.onExpand;
    return onExpand == null
        ? _decide(context, mode, ranked, feedback)
        : _compact(context, mode, ranked, feedback, onExpand);
  }

  Widget _compact(
    BuildContext context,
    DiagnosisMode mode,
    List<Hypothesis> ranked,
    List<Widget> feedback,
    VoidCallback onExpand,
  ) {
    final c = context.colors;
    final task = widget.task;
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
          Muted(blockedReasonText(task.blockedReason), size: 12),
          const SizedBox(height: 14),
          if (ranked.isNotEmpty)
            _CompactTop(
              h: ranked.first,
              others: ranked.length - 1,
              onExpand: onExpand,
              button: _button(mode, ranked.first.action, primary: true),
            ),
          ...feedback,
        ],
      ),
    );
  }

  Widget _decide(BuildContext context, DiagnosisMode mode, List<Hypothesis> ranked, List<Widget> feedback) {
    final c = context.colors;
    final reason = blockedReasonText(widget.task.blockedReason);
    // One button per action, in ranking order: the key `diagnosis-action-<action>` must stay unique on the screen.
    final offered = <String>{};
    final exits = [
      for (final (i, h) in ranked.indexed)
        if (!_actions.containsKey(h.action))
          Muted('ação desconhecida: ${h.action}')
        else if (!offered.add(h.action))
          const Muted('mesma saída da hipótese acima')
        else
          _button(mode, h.action, primary: i == 0, filled: i == 0),
    ];
    return Container(
      key: const ValueKey('task-decide'),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.warn.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            kNeedsYou,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.warn),
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(reason, style: TextStyle(fontSize: 13, height: 1.45, color: c.textSecondary)),
          ],
          const SizedBox(height: 14),
          if (ranked.isEmpty)
            widget.task.blockedReason == 'agent_failed'
                ? _button(mode, 'fix_environment', primary: true, filled: true)
                : Text(_noHypotheses, style: TextStyle(fontSize: 13, color: c.textSecondary))
          else ...[
            Text(
              ranked.first.hypothesis,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, height: 1.45, color: c.textPrimary),
            ),
            if (ranked.first.evidence.isNotEmpty) ...[
              const SizedBox(height: 10),
              _Evidence(ranked.first.evidence, key: const ValueKey('task-decide-evidence')),
            ],
            const SizedBox(height: 14),
            exits.first,
            const SizedBox(height: 6),
            Row(
              key: const ValueKey('task-decide-rank'),
              children: [
                Flexible(
                  child: Muted(ranked.length == 1 ? 'única hipótese' : 'hipótese mais provável de ${ranked.length}'),
                ),
                if (ranked.length > 1)
                  TextButton(
                    key: const ValueKey('task-other-options'),
                    onPressed: () => setState(() => _showOthers = !_showOthers),
                    child: Text(
                      _showOthers ? 'ocultar as outras' : 'ver as outras',
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                    ),
                  ),
              ],
            ),
            if (_showOthers)
              for (final (i, h) in ranked.indexed.skip(1))
                Container(
                  key: ValueKey('task-hypothesis-$i'),
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: c.elevated,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(h.hypothesis, style: TextStyle(fontSize: 13, height: 1.45, color: c.textPrimary)),
                      if (h.evidence.isNotEmpty) ...[const SizedBox(height: 8), _Evidence(h.evidence)],
                      const SizedBox(height: 12),
                      exits[i],
                    ],
                  ),
                ),
          ],
          ...feedback,
        ],
      ),
    );
  }
}

class _Evidence extends StatelessWidget {
  const _Evidence(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final line in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Muted('↳ ', size: 11),
              Expanded(child: Mono(line, size: 11)),
            ],
          ),
        ),
    ],
  );
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
  const _ActionButton({
    required this.buttonKey,
    required this.action,
    required this.primary,
    required this.filled,
    required this.onPressed,
  });

  final Key buttonKey;
  final String action;
  final bool primary;
  final bool filled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (label, command) = _actions[action] ?? (action, null);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
    const padding = EdgeInsets.symmetric(vertical: 12);
    final child = Text(command == null ? label : '$label  $command', style: const TextStyle(fontSize: 12));
    if (filled) {
      return FilledButton(
        key: buttonKey,
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          shape: shape,
          padding: padding,
        ),
        onPressed: onPressed,
        child: child,
      );
    }
    return OutlinedButton(
      key: buttonKey,
      style: OutlinedButton.styleFrom(
        foregroundColor: primary ? c.accent : c.textSecondary,
        side: BorderSide(color: onPressed == null ? c.border : (primary ? c.accent : c.borderStrong)),
        shape: shape,
        padding: padding,
      ),
      onPressed: onPressed,
      child: child,
    );
  }
}
