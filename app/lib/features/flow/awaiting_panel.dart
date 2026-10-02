import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/session_launcher.dart';
import '../../data/flow_aggregates.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/report_models.dart';
import '../../data/report_parser.dart';
import '../../data/session_models.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
import '../sessions/session_cubit.dart';
import '../sessions/session_events.dart';
import '../sessions/session_view.dart';
import 'stage_timeline.dart';

/// "Aguardando você": questions the project's sessions hold, answered here, plus pending permissions and `running`
/// stages whose session ended, both sent to Sessões. The session the side panel shows is left out. Nothing to show →
/// no space taken.
class AwaitingPanel extends StatelessWidget {
  const AwaitingPanel({super.key, required this.projectName, required this.report, required this.shownSessionId});

  final String projectName;
  final ReportDoc? report;
  final String? shownSessionId;

  @override
  Widget build(BuildContext context) {
    final all = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final pending = awaitingSessions(pendingProjectSessions(all, projectName), shownSessionId);
    final ended = endedStageSessions(report, all);
    if (pending.isEmpty && ended.isEmpty) return const SizedBox.shrink();
    final repository = SessionsScope.of(context);
    return Padding(
      key: const ValueKey('flow-awaiting'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Panel(
        title: 'Aguardando você',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in pending)
              BlocProvider(
                key: ValueKey('awaiting-${s.id}'),
                create: (_) => SessionCubit(repository, s.id),
                child: _SessionPending(session: s, report: report),
              ),
            for (final e in ended)
              _SessionsLink(
                key: ValueKey('awaiting-ended-${e.stage.name}'),
                icon: Icons.link_off,
                text: '${e.stage.label}: sessão encerrada — retome em Sessões',
                session: e.session,
              ),
          ],
        ),
      ),
    );
  }
}

class _SessionPending extends StatefulWidget {
  const _SessionPending({required this.session, required this.report});

  final SessionSummary session;
  final ReportDoc? report;

  @override
  State<_SessionPending> createState() => _SessionPendingState();
}

class _SessionPendingState extends State<_SessionPending> with SessionLauncher<_SessionPending> {
  @override
  String get logName => 'AwaitingPanel';

  /// The card's resolved state comes from the stream.
  Future<void> _answer(String requestId, PermissionDecision decision, {Map<String, String>? answers}) => sessionAction(
    context,
    () => SessionsScope.of(context).answer(widget.session.id, requestId, decision, answers: answers),
  );

  @override
  Widget build(BuildContext context) {
    final detail = context.watch<SessionCubit>().state.data;
    if (detail == null) return const SizedBox.shrink();
    final s = widget.session;
    final stage = stageOfSession(widget.report, s.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in pendingRequests(detail))
          switch (r) {
            final QuestionRequest q => Padding(
              key: ValueKey('awaiting-question-${q.requestId}'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (stage != null) ...[_StageReportBlock(stage, onLink: openLink), const SizedBox(height: 10)],
                  QuestionCard(q, onAnswer: _answer),
                ],
              ),
            ),
            final PermissionRequest p => _SessionsLink(
              key: ValueKey('awaiting-permission-${p.requestId}'),
              icon: Icons.shield_outlined,
              text: 'Permissão pendente em ${s.title} —',
              session: s,
            ),
          },
      ],
    );
  }
}

class _StageReportBlock extends StatelessWidget {
  const _StageReportBlock(this.entry, {required this.onLink});

  final StageReport entry;
  final ValueChanged<Uri> onLink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: ValueKey('awaiting-report-${entry.stage.name}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Mono(entry.stage.label, color: c.textPrimary, size: 12),
              const SizedBox(width: 8),
              const Muted('relatório da etapa', size: 11),
            ],
          ),
          const SizedBox(height: 8),
          if (entry.summaryMd.trim().isEmpty)
            const Muted('sem resumo')
          else
            MarkdownView(entry.summaryMd, onLink: onLink),
          for (final d in entry.decisions) DecisionTile(decision: d),
        ],
      ),
    );
  }
}

class _SessionsLink extends StatelessWidget {
  const _SessionsLink({super.key, required this.icon, required this.text, required this.session});

  final IconData icon;
  final String text;
  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, color: c.textPrimary)),
          ),
          TextButton(
            onPressed: () => context.go('/p/${session.project}/sessions/${session.id}'),
            child: Text('abrir em Sessões', style: TextStyle(color: c.accent, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
