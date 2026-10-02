import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';
import '../../data/session_models.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';
import 'session_cubit.dart';
import 'session_events.dart';
import 'session_labels.dart';

/// Runs a session action; engine errors (stopped engine, 404, invalid request) surface as a snackbar instead of
/// failing silently. Shared by the session panel and the Fluxo "Aguardando você" card.
Future<void> sessionAction(BuildContext context, Future<void> Function() action) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } on Exception catch (e, st) {
    log('session action failed', name: 'SessionPanel', error: e, stackTrace: st);
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

const _interruptible = {SessionStatus.starting, SessionStatus.running, SessionStatus.waitingPermission};

/// One session's detail: header (status, mode, Interromper), the feed with answerable cards, and the composer.
/// Shared by Sessões and the Fluxo side panel; owns the session's stream.
class SessionPanel extends StatelessWidget {
  const SessionPanel({super.key, required this.session});

  /// List entry: shown until the session stream delivers its first detail.
  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final sessions = SessionsScope.of(context);
    return BlocProvider(
      key: ValueKey(session.id),
      create: (_) => SessionCubit(sessions, session.id),
      child: _SessionBody(session: session),
    );
  }
}

/// [session] with `interrupted` from its own event log, which the list does not carry. Only idle sessions can be
/// interrupted, so only those open the session stream.
class LiveSessionSummary extends StatelessWidget {
  const LiveSessionSummary({super.key, required this.session, required this.builder});

  final SessionSummary session;
  final Widget Function(BuildContext context, SessionSummary session) builder;

  @override
  Widget build(BuildContext context) {
    if (session.status != SessionStatus.idle) return builder(context, session);
    final sessions = SessionsScope.of(context);
    return BlocProvider(
      key: ValueKey('live-${session.id}'),
      create: (_) => SessionCubit(sessions, session.id),
      child: BlocBuilder<SessionCubit, AsyncSnapshot<SessionDetail>>(
        builder: (context, snapshot) =>
            builder(context, session.copyWith(interrupted: snapshot.data?.summary.showsInterrupted ?? false)),
      ),
    );
  }
}

class _SessionBody extends StatelessWidget {
  const _SessionBody({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final detail = context.watch<SessionCubit>().state.data;
    final s = detail?.summary ?? session;
    final sessions = SessionsScope.of(context);
    final events = detail?.events ?? const <SessionEvent>[];
    final partialText = detail?.partialText ?? '';
    final partialThinking = detail?.partialThinking ?? '';
    Future<void> answer(String requestId, PermissionDecision decision, {Map<String, String>? answers}) =>
        sessionAction(context, () => sessions.answer(s.id, requestId, decision, answers: answers));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(session: s),
        Expanded(
          child: _Feed(
            version: (detail?.lastSeq, events.length, partialText.length, partialThinking.length, s.status),
            children: [
              if (s.isOrgSession) ...[_Directories(session: s), const SizedBox(height: 16)],
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
        // Above the composer, not atop the feed: the feed opens scrolled to the end and would hide it.
        if (s.status == SessionStatus.detached)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _DetachedBanner(
              resumable: s.resumable,
              onResume: () => sessionAction(context, () => sessions.resume(s.id)),
            ),
          ),
        _Composer(
          enabled: isLive(s.status) && s.status != SessionStatus.waitingPermission,
          waiting: s.status == SessionStatus.waitingPermission,
          onSend: (text) => sessionAction(context, () => sessions.send(s.id, text)),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session});

  final SessionSummary session;

  /// Below this the header splits in two rows, as in the Fluxo side panel.
  static const _wide = 640.0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = session;
    final sessions = SessionsScope.of(context);
    final label = sessionStatusLabel(s);
    final status = Tooltip(
      message: label,
      child: Pill(key: const ValueKey('session-status'), label: label, color: statusColor(c, s.status)),
    );
    final command = Flexible(
      child: Text(
        s.command,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: monoFamily, fontSize: 13, color: c.textPrimary),
      ),
    );
    final details = <Widget>[
      if (s.model case final model?) ...[
        Pill(label: model, color: _modelColor(c, model), mono: true, dot: false),
        const SizedBox(width: 8),
      ],
      _PermissionModeSelector(key: ValueKey('mode-${s.id}'), session: s),
    ];
    final cost = Mono('\$${s.cost.toStringAsFixed(2)}', size: 12);
    final interrupt = _interruptible.contains(s.status)
        ? OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: c.fail,
              side: BorderSide(color: c.fail.withValues(alpha: 0.5)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () => sessionAction(context, () => sessions.interrupt(s.id)),
            icon: const Icon(Icons.stop_rounded, size: 16),
            label: const Text('Interromper', style: TextStyle(fontSize: 12)),
          )
        : null;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= _wide
            ? Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Flexible(child: status),
                    const SizedBox(width: 12),
                    command,
                    const SizedBox(width: 12),
                    ...details,
                    const Spacer(),
                    cost,
                    const SizedBox(width: 16),
                    ?interrupt,
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 36,
                      child: Row(
                        children: [
                          Expanded(
                            child: Align(alignment: Alignment.centerLeft, child: status),
                          ),
                          ?interrupt,
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [command, const SizedBox(width: 8), ...details, const Spacer(), cost]),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Opens at the end, follows new content only while the user is within [_followSlack] of it, and otherwise offers
/// a button back to the end.
class _Feed extends StatefulWidget {
  const _Feed({required this.version, required this.children});

  /// Changes whenever content is appended or grows (events, tool results, streaming deltas, status).
  final Object version;
  final List<Widget> children;

  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  static const _followSlack = 80.0;

  final _controller = ScrollController();
  bool _newBelow = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _toEnd();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _nearEnd {
    if (!_controller.hasClients) return true;
    final p = _controller.position;
    return p.maxScrollExtent - p.pixels <= _followSlack;
  }

  void _onScroll() {
    if (_newBelow && _nearEnd) setState(() => _newBelow = false);
  }

  @override
  void didUpdateWidget(_Feed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.version == widget.version) return;
    if (_nearEnd) {
      _toEnd();
    } else {
      _newBelow = true;
    }
  }

  /// Children are laid out lazily, so the first max extent is an estimate; jump again until it stops moving.
  void _toEnd([int tries = 4]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final p = _controller.position;
      if (p.pixels >= p.maxScrollExtent) return;
      p.jumpTo(p.maxScrollExtent);
      if (tries > 1) _toEnd(tries - 1);
    });
  }

  void _jumpToEnd() {
    setState(() => _newBelow = false);
    _controller.jumpTo(_controller.position.maxScrollExtent);
    _toEnd();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView(
            key: const ValueKey('session-feed'),
            controller: _controller,
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            children: widget.children,
          ),
        ),
        if (_newBelow)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: FilledButton(
                key: const ValueKey('session-new-messages'),
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _jumpToEnd,
                child: const Text('↓ novas mensagens', style: TextStyle(fontSize: 12)),
              ),
            ),
          ),
      ],
    );
  }
}

/// The session's own mode, changed live through the engine. On a refusal the pill goes back to the previous mode
/// and the engine text shows in a snackbar.
class _PermissionModeSelector extends StatefulWidget {
  const _PermissionModeSelector({super.key, required this.session});

  final SessionSummary session;

  @override
  State<_PermissionModeSelector> createState() => _PermissionModeSelectorState();
}

class _PermissionModeSelectorState extends State<_PermissionModeSelector> {
  /// Chosen mode until the summary catches up; the summary stays the source of truth.
  PermissionMode? _pending;
  bool _busy = false;

  @override
  void didUpdateWidget(_PermissionModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session.permissionMode != oldWidget.session.permissionMode) _pending = null;
  }

  Future<void> _change(PermissionMode mode) async {
    final current = _pending ?? widget.session.permissionMode;
    if (_busy || mode == current) return;
    final sessions = SessionsScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _pending = mode;
    });
    try {
      await sessions.setPermissionMode(widget.session.id, mode);
    } on Exception catch (e, st) {
      log('cannot change permission mode', name: 'SessionPanel', error: e, stackTrace: st);
      if (mounted) setState(() => _pending = null);
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PermissionModeMenu(
    key: const ValueKey('session-permission-mode'),
    mode: _pending ?? widget.session.permissionMode,
    tooltip: 'Permissões da sessão',
    onSelected: _busy ? null : _change,
  );
}

/// Where an org session runs: its `cwd` (the org's first root) and the other roots it can reach.
class _Directories extends StatelessWidget {
  const _Directories({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      key: const ValueKey('session-directories'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Muted('DIRETÓRIOS', size: 10),
        const SizedBox(height: 6),
        if (session.cwd case final cwd?) Mono(cwd, color: c.textPrimary, size: 12),
        for (final dir in session.additionalDirectories)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Mono(dir, color: c.textSecondary, size: 12),
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
