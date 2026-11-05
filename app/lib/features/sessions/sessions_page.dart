import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import '../../data/session_models.dart';
import 'session_events.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key, required this.projectName, this.sessionId});

  final String projectName;
  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    final all = RepositoryScope.of(context).sessions();
    final mine = all.where((s) => s.project == projectName).toList();
    final others = all.where((s) => s.project != projectName).toList();
    final selected =
        all.where((s) => s.id == sessionId).firstOrNull ??
        mine.where((s) => s.pendingPermissions > 0).firstOrNull ??
        mine.firstOrNull;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SessionList(project: projectName, mine: mine, others: others, selected: selected?.id),
        Expanded(
          child: selected == null
              ? const Center(child: Muted('Nenhuma sessão. Rode uma skill com ⌘K.', size: 13))
              : _SessionPanel(key: ValueKey(selected.id), session: selected),
        ),
      ],
    );
  }
}

Color statusColor(AppColors c, SessionStatus s) => switch (s) {
  SessionStatus.starting || SessionStatus.running => c.running,
  SessionStatus.waitingPermission => c.warn,
  SessionStatus.idle => c.accent,
  SessionStatus.done => c.pass,
  SessionStatus.error => c.fail,
  SessionStatus.stopped || SessionStatus.detached => c.idle,
};

String statusLabel(SessionStatus s) => switch (s) {
  SessionStatus.starting => 'iniciando',
  SessionStatus.running => 'rodando',
  SessionStatus.waitingPermission => 'aguardando permissão',
  SessionStatus.idle => 'aguardando resposta',
  SessionStatus.done => 'concluída',
  SessionStatus.stopped => 'interrompida',
  SessionStatus.error => 'erro',
  SessionStatus.detached => 'desanexada',
};

class _SessionList extends StatelessWidget {
  const _SessionList({required this.project, required this.mine, required this.others, required this.selected});

  final String project;
  final List<SessionSummary> mine;
  final List<SessionSummary> others;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget header(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 6), child: Muted(t, size: 10));
    return Container(
      width: 300,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          header('ESTE PROJETO'),
          for (final s in mine) _SessionTile(project: project, session: s, selected: s.id == selected),
          if (others.isNotEmpty) ...[
            header('OUTROS PROJETOS'),
            for (final s in others) _SessionTile(project: project, session: s, selected: s.id == selected),
          ],
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.project, required this.session, required this.selected});

  final String project;
  final SessionSummary session;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pending = session.pendingPermissions;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: selected ? c.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: c.hover,
          onTap: () => context.go('/p/${session.project}/sessions/${session.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: statusColor(c, session.status), shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Mono(session.command, size: 11, color: c.textMuted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '· ${session.project} · ${session.startedAt}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: c.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (pending > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 6, top: 1),
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: c.warn, borderRadius: BorderRadius.circular(9)),
                    child: Text(
                      '$pending',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.canvas),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionPanel extends StatelessWidget {
  const _SessionPanel({super.key, required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = session;
    final live =
        s.status == SessionStatus.running ||
        s.status == SessionStatus.waitingPermission ||
        s.status == SessionStatus.idle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: [
              Pill(label: statusLabel(s.status), color: statusColor(c, s.status)),
              const SizedBox(width: 12),
              Mono(s.command, color: c.textPrimary, size: 13),
              const SizedBox(width: 12),
              Pill(label: s.model, color: _modelColor(c, s.model), mono: true, dot: false),
              const SizedBox(width: 12),
              Expanded(child: Mono(s.cwd, size: 11, color: c.textMuted)),
              Mono('\$${s.cost.toStringAsFixed(2)}', size: 12),
              const SizedBox(width: 16),
              if (live)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.fail,
                    side: BorderSide(color: c.fail.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () {},
                  icon: const Icon(Icons.stop_rounded, size: 16),
                  label: const Text('Interromper', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            children: [
              if (s.status == SessionStatus.detached) ...[
                _DetachedBanner(resumable: s.resumable),
                const SizedBox(height: 16),
              ],
              for (final e in s.events) Padding(padding: const EdgeInsets.only(bottom: 12), child: SessionEventView(e)),
              if (s.status == SessionStatus.running) const _Typing(),
            ],
          ),
        ),
        _Composer(
          enabled: live && s.status != SessionStatus.waitingPermission,
          waiting: s.status == SessionStatus.waitingPermission,
        ),
      ],
    );
  }
}

class _DetachedBanner extends StatelessWidget {
  const _DetachedBanner({required this.resumable});

  final bool resumable;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.borderStrong),
        color: c.elevated,
      ),
      child: Row(
        children: [
          Icon(Icons.link_off, size: 16, color: c.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'O processo desta sessão terminou com o app. Retomar reanexa com o histórico completo; '
              'uma permissão que estava pendente é refeita pelo modelo.',
              style: TextStyle(fontSize: 12.5, color: c.textSecondary),
            ),
          ),
          if (resumable)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: () {},
              child: const Text('Retomar', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.running)),
        const SizedBox(width: 10),
        const Muted('trabalhando…'),
      ],
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.enabled, required this.waiting});

  final bool enabled;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: waiting
                    ? 'Decida a permissão acima para continuar'
                    : enabled
                    ? 'Responder à sessão…  (⌘↵ envia)'
                    : 'Sessão encerrada',
                hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                filled: true,
                fillColor: c.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.border),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: c.accent),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: c.accent,
              disabledBackgroundColor: c.elevated,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: enabled ? () {} : null,
            icon: Icon(Icons.arrow_upward, size: 18, color: enabled ? Colors.white : c.textMuted),
          ),
        ],
      ),
    );
  }
}

Color _modelColor(AppColors c, String model) {
  final tier = Tier.values.where((t) => model.contains(t.name)).firstOrNull;
  return tier == null ? c.idle : c.tier(tier);
}
