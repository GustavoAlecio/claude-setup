import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_models.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
import '../launcher/command_palette.dart';
import '../sessions/session_view.dart';

/// Live pipeline sessions of [project]: pausing or archiving the cycle stops them first.
List<SessionSummary> _livePipeline(BuildContext context, String project) => [
  for (final s in context.read<SessionsCubit>().state.data ?? const <SessionSummary>[])
    if (!s.isOrgSession && s.project == project && isLive(s.status) && isPipelineSession(s)) s,
];

Future<void> _run(BuildContext context, Project project, CycleAction action, List<SessionSummary> stop) =>
    sessionAction(context, () async {
      final sessions = SessionsScope.of(context);
      for (final s in stop) {
        await sessions.interrupt(s.id);
      }
      await sessions.cycleAction(project.name, action);
    });

Future<bool> _confirm(BuildContext context, {required String title, required String body, required String ok}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(ok)),
        ],
      ),
    ) ==
    true;

String _stopping(List<SessionSummary> live) =>
    live.isEmpty ? '' : '\n\nAntes, interrompe ${live.map((s) => s.command.split(' ').first).join(', ')}.';

Future<void> pauseCycle(BuildContext context, Project project) async {
  final live = _livePipeline(context, project.name);
  if (live.isNotEmpty &&
      !await _confirm(
        context,
        title: 'Pausar o ciclo?',
        body: 'O ciclo fica parado até você retomar, sem cobrar decisões nem avisar orçamento.${_stopping(live)}',
        ok: 'Pausar',
      )) {
    return;
  }
  if (context.mounted) await _run(context, project, CycleAction.pause, live);
}

Future<void> resumeCycle(BuildContext context, Project project) async {
  await _run(context, project, CycleAction.resume, const []);
  if (context.mounted) unawaited(showCommandPalette(context, ProjectTarget(project)));
}

Future<void> archiveCycle(BuildContext context, Project project) async {
  final live = _livePipeline(context, project.name);
  final feature = project.cycle?.feature ?? project.name;
  if (!await _confirm(
    context,
    title: 'Arquivar «$feature» como abandonado?',
    body:
        'O ciclo vai para o histórico (Métricas) com status abandonado e o projeto fica livre para um novo kickoff. '
        'phases.md, prs.json e os detalhamentos continuam.${_stopping(live)}',
    ok: 'Arquivar',
  )) {
    return;
  }
  if (context.mounted) await _run(context, project, CycleAction.archive, live);
}

/// "⋯" of the Ciclo panel.
class CycleMenu extends StatelessWidget {
  const CycleMenu({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final paused = project.cycle?.paused ?? false;
    return PopupMenuButton<String>(
      key: const ValueKey('flow-cycle-menu'),
      tooltip: 'Ações do ciclo',
      color: c.elevated,
      icon: Icon(Icons.more_horiz, size: 18, color: c.textSecondary),
      onSelected: (value) => switch (value) {
        'pause' => pauseCycle(context, project),
        'resume' => resumeCycle(context, project),
        _ => archiveCycle(context, project),
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: paused ? 'resume' : 'pause',
          height: 36,
          child: Row(
            children: [
              Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 16, color: c.textSecondary),
              const SizedBox(width: 10),
              Flexible(child: Text(paused ? 'Retomar ciclo' : 'Pausar ciclo', style: const TextStyle(fontSize: 13))),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'archive',
          height: 36,
          child: Row(
            children: [
              Icon(Icons.archive_outlined, size: 16, color: c.fail),
              const SizedBox(width: 10),
              Flexible(
                child: Text('Arquivar como abandonado', style: TextStyle(fontSize: 13, color: c.fail)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Top of a paused cycle's Fluxo: since when, and the way back.
class PausedBanner extends StatelessWidget {
  const PausedBanner({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final since = project.cycle?.pausedAt;
    final when = since == null || since.millisecondsSinceEpoch == 0
        ? ''
        : ' desde ${since.toLocal().day.toString().padLeft(2, '0')}/${since.toLocal().month.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        key: const ValueKey('flow-paused-banner'),
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        decoration: BoxDecoration(
          color: c.idle.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.idle.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.pause_circle_outline, size: 18, color: c.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Ciclo pausado$when: sem cobranças de decisão nem avisos de orçamento.',
                style: TextStyle(fontSize: 12.5, color: c.textPrimary),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('flow-resume-cycle'),
              style: TextButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => resumeCycle(context, project),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text('Retomar', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
