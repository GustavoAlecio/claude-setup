import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';
import '../../data/report_models.dart';
import '../../data/session_models.dart';
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
  });

  final String projectName;
  final Project? project;
  final ReportDoc? report;
  final SessionSummary? session;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    return LayoutBuilder(
      key: const ValueKey('flow-side-panel'),
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.45),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: AwaitingPanel(projectName: projectName, report: report, shownSessionId: session?.id),
            ),
          ),
          Expanded(
            child: session == null ? _NoSession(project: project) : SessionPanel(session: session),
          ),
        ],
      ),
    );
  }
}

class _NoSession extends StatelessWidget {
  const _NoSession({required this.project});

  final Project? project;

  @override
  Widget build(BuildContext context) {
    final project = this.project;
    return Center(
      key: const ValueKey('flow-no-session'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Muted('nenhuma sessão ativa nesta etapa', size: 13),
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
