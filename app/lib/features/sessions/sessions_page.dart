import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';
import '../../data/workflow_parser.dart';
import '../launcher/command_palette.dart';
import 'session_cubit.dart';
import 'session_events.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.projectName, this.sessionId});

  final String projectName;
  final String? sessionId;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  /// Without an id in the route the first pending session is picked once; re-picking on every update
  /// would jump to another session as soon as the user answers the one on screen.
  String? _autoSelected;

  @override
  void didUpdateWidget(SessionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectName != widget.projectName) _autoSelected = null;
  }

  @override
  Widget build(BuildContext context) {
    final projectName = widget.projectName;
    final all = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final mine = all.where((s) => s.project == projectName).toList();
    final others = all.where((s) => s.project != projectName).toList();
    final selected =
        all.where((s) => s.id == (widget.sessionId ?? _autoSelected)).firstOrNull ??
        mine.where((s) => s.pendingPermissions > 0).firstOrNull ??
        mine.firstOrNull;
    if (widget.sessionId == null) _autoSelected = selected?.id;
    final sessions = SessionsScope.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SessionList(project: projectName, mine: mine, others: others, selected: selected?.id),
        Expanded(
          child: selected == null
              ? const Center(child: Muted('Nenhuma sessão. Rode uma skill com ⌘K.', size: 13))
              : BlocProvider(
                  key: ValueKey(selected.id),
                  create: (_) => SessionCubit(sessions, selected.id),
                  child: _SessionPanel(session: selected),
                ),
        ),
      ],
    );
  }
}

/// Engine errors (stopped engine, 404, invalid request) surface as a snackbar instead of failing silently.
Future<void> _act(BuildContext context, Future<void> Function() action) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } on Exception catch (e, st) {
    log('session action failed', name: 'SessionsPage', error: e, stackTrace: st);
    messenger.showSnackBar(SnackBar(content: Text('$e')));
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: c.textPrimary,
                side: BorderSide(color: c.borderStrong),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: () => showCommandPalette(context, project, newConversation: true),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Nova conversa', style: TextStyle(fontSize: 12)),
            ),
          ),
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
                              '· ${session.project} · ${_createdAt(session.createdAt)}',
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

const _live = {SessionStatus.running, SessionStatus.waitingPermission, SessionStatus.idle};
const _interruptible = {SessionStatus.starting, SessionStatus.running, SessionStatus.waitingPermission};

class _SessionPanel extends StatelessWidget {
  const _SessionPanel({required this.session});

  /// List entry: shown until the session stream delivers its first detail.
  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final detail = context.watch<SessionCubit>().state.data;
    final s = detail?.summary ?? session;
    final sessions = SessionsScope.of(context);
    final events = detail?.events ?? const <SessionEvent>[];
    final partialText = detail?.partialText ?? '';
    final partialThinking = detail?.partialThinking ?? '';
    Future<void> answer(String requestId, PermissionDecision decision, {Map<String, String>? answers}) =>
        _act(context, () => sessions.answer(s.id, requestId, decision, answers: answers));
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
              Flexible(child: Mono(s.command, color: c.textPrimary, size: 13)),
              const SizedBox(width: 12),
              if (s.model case final model?) Pill(label: model, color: _modelColor(c, model), mono: true, dot: false),
              const Spacer(),
              Mono('\$${s.cost.toStringAsFixed(2)}', size: 12),
              const SizedBox(width: 16),
              if (_interruptible.contains(s.status))
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.fail,
                    side: BorderSide(color: c.fail.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () => _act(context, () => sessions.interrupt(s.id)),
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
                _DetachedBanner(resumable: s.resumable, onResume: () => _act(context, () => sessions.resume(s.id))),
                const SizedBox(height: 16),
              ],
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SessionEventView(e, onAnswer: answer),
                ),
              if (partialThinking.isNotEmpty)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: Muted('pensando… $partialThinking')),
              if (partialText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SessionEventView(AssistantText('', partialText), onAnswer: answer),
                ),
              if (s.status == SessionStatus.running && partialText.isEmpty) const _Typing(),
            ],
          ),
        ),
        _Composer(
          enabled: _live.contains(s.status) && s.status != SessionStatus.waitingPermission,
          waiting: s.status == SessionStatus.waitingPermission,
          onSend: (text) => _act(context, () => sessions.send(s.id, text)),
        ),
      ],
    );
  }
}

class _DetachedBanner extends StatelessWidget {
  const _DetachedBanner({required this.resumable, required this.onResume});

  final bool resumable;
  final VoidCallback onResume;

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
              onPressed: onResume,
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

class _Composer extends StatefulWidget {
  const _Composer({required this.enabled, required this.waiting, required this.onSend});

  final bool enabled;
  final bool waiting;
  final Future<void> Function(String text) onSend;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (!widget.enabled || text.isEmpty) return;
    _controller.clear();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.enabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send},
              child: TextField(
                controller: _controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.waiting
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
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: c.accent,
              disabledBackgroundColor: c.elevated,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: enabled ? _send : null,
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

String _createdAt(String iso) {
  final at = DateTime.tryParse(iso);
  return at == null ? '' : formatStartedAt(at, DateTime.now());
}
