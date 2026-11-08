import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';
import '../../data/report_models.dart';
import '../../data/session_models.dart';
import '../launcher/command_palette.dart';
import '../launcher/kickoff_form.dart';
import '../sessions/session_view.dart';
import 'awaiting_panel.dart';

/// Fluxo width from which it shows the side panel next to the timeline; below it the panel is a drawer.
const kFlowSplitWidth = 1200.0;

const kFlowSidePanelWidth = 480.0;

/// Right side of the Fluxo: "Aguardando você" on top, then the stage session (or a placeholder, with Kickoff only
/// without a cycle).
class FlowSidePanel extends StatelessWidget {
  const FlowSidePanel({
    super.key,
    required this.projectName,
    required this.project,
    required this.report,
    required this.session,
    this.orphanStage,
  });

  final String projectName;
  final Project? project;
  final ReportDoc? report;
  final SessionSummary? session;

  /// Stage that reads "em andamento" with no session behind it (`orphanCurrentStage`).
  final Stage? orphanStage;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    return LayoutBuilder(
      key: const ValueKey('flow-side-panel'),
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            // Without a session below, a question gets the whole height so its "Responder" stays reachable.
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * (session == null ? 0.7 : 0.45)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: AwaitingPanel(projectName: projectName, report: report, shownSessionId: session?.id),
            ),
          ),
          Expanded(
            child: session == null
                ? _NoSession(project: project, orphanStage: orphanStage)
                : SessionPanel(session: session),
          ),
        ],
      ),
    );
  }
}

class _NoSession extends StatelessWidget {
  const _NoSession({required this.project, required this.orphanStage});

  final Project? project;
  final Stage? orphanStage;

  @override
  Widget build(BuildContext context) {
    final project = this.project;
    final orphan = orphanStage;
    final c = context.colors;
    return Center(
      key: const ValueKey('flow-no-session'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Muted('nenhuma sessão ativa nesta etapa', size: 13),
          if (orphan != null && project != null) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Muted(
                'A etapa ${orphan.label} consta em andamento, mas a sessão dela não está rodando. '
                'Retome rodando /${orphan.label} de novo.',
                size: 12,
                align: TextAlign.center,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              key: const ValueKey('flow-orphan-resume'),
              style: OutlinedButton.styleFrom(foregroundColor: c.accent),
              onPressed: () => showCommandPalette(context, ProjectTarget(project)),
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: Text('Retomar /${orphan.label}'),
            ),
          ],
          if (project?.cycle == null) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: context.colors.accent, foregroundColor: Colors.white),
              onPressed: project == null ? null : () => showKickoffForm(context, project),
              icon: const Icon(Icons.rocket_launch_outlined, size: 15),
              label: const Text('Kickoff'),
            ),
          ],
        ],
      ),
    );
  }
}
