import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/image_attachments.dart';
import '../../core/widgets/model_menu.dart';
import '../../core/widgets/permission_mode.dart';
import '../../core/widgets/primitives.dart';
import '../../data/docs_repository.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/session_models.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_config.dart';
import 'session_artifacts.dart';
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
  SessionStatus.idle => c.awaiting,
  SessionStatus.done => c.pass,
  SessionStatus.error => c.fail,
  SessionStatus.stopped || SessionStatus.detached => c.idle,
};

const _interruptible = {SessionStatus.starting, SessionStatus.running, SessionStatus.waitingPermission};

/// What a feed shows in place of a question's card; `null` keeps the card.
typedef RequestOverride = Widget? Function(SessionDetail detail, QuestionRequest request);

/// One session's detail: header (status, mode, Interromper), the feed with answerable cards, and the composer.
/// Shared by Sessões and the Fluxo side panel; owns the session's stream.
class SessionPanel extends StatelessWidget {
  const SessionPanel({super.key, required this.session, this.requestOverride});

  /// List entry: shown until the session stream delivers its first detail.
  final SessionSummary session;
  final RequestOverride? requestOverride;

  @override
  Widget build(BuildContext context) {
    final sessions = SessionsScope.of(context);
    return BlocProvider(
      key: ValueKey(session.id),
      create: (_) => SessionCubit(sessions, session.id),
      child: _SessionBody(session: session, requestOverride: requestOverride),
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

class _SessionBody extends StatefulWidget {
  const _SessionBody({required this.session, required this.requestOverride});

  final SessionSummary session;
  final RequestOverride? requestOverride;

  @override
  State<_SessionBody> createState() => _SessionBodyState();
}

class _SessionBodyState extends State<_SessionBody> {
  /// Work blocks the user toggled, by position in `feedBlocks`; the others follow `workOpenByDefault`.
  final _open = <int, bool>{};

  /// Blocks that stopped being open by default while the user was reading further up: kept open so the content
  /// under their eyes does not collapse. Dropped when the user comes back to the end.
  final _autoOpen = <int>{};

  /// Written by the feed's scroll position; read here only when an event arrives.
  final nearEnd = ValueNotifier<bool>(true);
  Set<int> _defaultOpen = const {};
  (int, SessionStatus)? _decidedAt;

  @override
  void initState() {
    super.initState();
    nearEnd.addListener(_onNearEnd);
  }

  @override
  void dispose() {
    nearEnd.dispose();
    super.dispose();
  }

  void _onNearEnd() {
    if (!nearEnd.value || _autoOpen.isEmpty) return;
    void drop() {
      if (mounted) setState(_autoOpen.clear);
    }

    // The scroll position can notify while the feed is laid out, where setState is not allowed.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => drop());
    } else {
      drop();
    }
  }

  void _decideAutoOpen(List<FeedBlock> blocks, int eventCount, SessionStatus status) {
    if (_decidedAt == (eventCount, status)) return;
    _decidedAt = (eventCount, status);
    final now = {
      for (final (i, b) in blocks.indexed)
        if (b.work && workOpenByDefault(blocks, i, status)) i,
    };
    if (!nearEnd.value) {
      _autoOpen.addAll(_defaultOpen.difference(now).where((i) => !_open.containsKey(i)));
    }
    _defaultOpen = now;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final requestOverride = widget.requestOverride;
    final detail = context.watch<SessionCubit>().state.data;
    final s = detail?.summary ?? session;
    final sessions = SessionsScope.of(context);
    final events = detail?.events ?? const <SessionEvent>[];
    final partialText = detail?.partialText ?? '';
    final partialThinking = detail?.partialThinking ?? '';
    Future<void> answer(String requestId, PermissionDecision decision, {Map<String, String>? answers}) =>
        sessionAction(context, () => sessions.answer(s.id, requestId, decision, answers: answers));
    final agy = s.provider == AgentProvider.antigravity;
    final blocks = feedBlocks(events);
    _decideAutoOpen(blocks, events.length, s.status);
    bool isOpen(int i) => _open[i] ?? (_autoOpen.contains(i) || workOpenByDefault(blocks, i, s.status));
    // A link to a file the agent wrote ("artefato de sessão") opens it here; anything else keeps the default.
    void onLink(Uri uri) {
      final name = artifactLinkName(uri);
      if (name == null) {
        DocsScope.openExternal(context, uri, logName: 'SessionFeed');
      } else {
        unawaited(showSessionArtifact(context, s.id, name));
      }
    }

    // Opening a block inserts or removes children mid-list; stable keys keep the State of the cards below it.
    final eventIndex = Map<SessionEvent, int>.identity()..addEntries(events.indexed.map((p) => MapEntry(p.$2, p.$1)));
    Key eventKey(SessionEvent e) => switch (e) {
      PendingRequest() => ValueKey('req-${e.requestId}'),
      _ => ValueKey('ev-${eventIndex[e]}'),
    };

    Widget eventView(SessionEvent e) =>
        (e is QuestionRequest && detail != null ? requestOverride?.call(detail, e) : null) ??
        SessionEventView(
          e,
          onAnswer: answer,
          onLink: agy ? onLink : null,
          attachmentUri: (name) => sessions.attachmentUri(s.id, name),
          failureActions: identical(e, events.last) && s.status == SessionStatus.idle
              ? _FailureActions(session: s)
              : null,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(session: s),
        if (s.asideOf != null) _AsideBanner(session: s),
        if (agy)
          SessionArtifactsStrip(
            key: ValueKey('artifacts-${s.id}'),
            sessionId: s.id,
            version: events.whereType<SessionResult>().length,
          ),
        Expanded(
          child: _Feed(
            nearEnd: nearEnd,
            version: (detail?.lastSeq, events.length, partialText.length, partialThinking.length, s.status),
            children: [
              if (s.isOrgSession) ...[
                _Directories(key: const ValueKey('directories'), session: s),
                const SizedBox(key: ValueKey('directories-gap'), height: 16),
              ],
              for (final (i, block) in blocks.indexed)
                if (block.work) ...[
                  Padding(
                    key: ValueKey('work-$i'),
                    padding: EdgeInsets.only(bottom: isOpen(i) ? 0 : 12),
                    child: _WorkHeader(
                      index: i,
                      block: block,
                      open: isOpen(i),
                      onToggle: (v) => setState(() => _open[i] = v),
                    ),
                  ),
                  if (isOpen(i))
                    for (final (j, e) in block.events.indexed)
                      Padding(
                        key: eventKey(e),
                        padding: EdgeInsets.only(top: 8, bottom: j == block.events.length - 1 ? 12 : 0),
                        child: eventView(e),
                      ),
                ] else
                  Padding(
                    key: eventKey(block.events.single),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: eventView(block.events.single),
                  ),
              if (partialThinking.isNotEmpty)
                Padding(
                  key: const ValueKey('partial-thinking'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Muted('pensando… $partialThinking'),
                ),
              if (partialText.isNotEmpty)
                Padding(
                  key: const ValueKey('partial-text'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SessionEventView(AssistantText('', partialText), onAnswer: answer),
                ),
              if (s.status == SessionStatus.running && partialText.isEmpty) const _Typing(key: ValueKey('typing')),
            ],
          ),
        ),
        // Above the composer, not atop the feed: the feed opens scrolled to the end and would hide it.
        if (s.status == SessionStatus.detached)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _DetachedBanner(
              resumable: s.resumable,
              imported: isFreshImport(events),
              onResume: () => sessionAction(context, () => sessions.resume(s.id)),
            ),
          ),
        _Composer(
          enabled: isLive(s.status) && s.status != SessionStatus.waitingPermission,
          waiting: s.status == SessionStatus.waitingPermission,
          blockedReason: (text) => skillBlockedReason(s, text),
          onSend: (text, images) => sessionAction(context, () => sessions.send(s.id, text, images: images)),
        ),
      ],
    );
  }
}

/// Header line of a run of tool calls and thinking; [open] is owned by the feed, which lays the block's events out
/// as its own lazy children.
class _WorkHeader extends StatelessWidget {
  const _WorkHeader({required this.index, required this.block, required this.open, required this.onToggle});

  final int index;
  final FeedBlock block;
  final bool open;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = block.errors > 0 ? c.fail : c.textSecondary;
    return InkWell(
      key: ValueKey('session-work-$index'),
      onTap: () => onToggle(!open),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                workLine(block.steps, block.seconds, errors: block.errors),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: color),
              ),
            ),
          ],
        ),
      ),
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
      if (s.provider == AgentProvider.antigravity) ...[
        Pill(
          key: const ValueKey('session-provider'),
          tooltip: 'Agente das conversas livres desta org (Configurações)',
          label: 'Antigravity · ${s.account ?? kDefaultAgentAccount}',
          color: c.accent,
          dot: false,
        ),
        const SizedBox(width: 8),
      ],
      // Natural width up to a cap: the command text is what shrinks in a narrow header.
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: ModelMenu(
          key: ValueKey('session-model-${s.id}'),
          provider: s.provider,
          account: s.account,
          model: s.model,
          allowDefault: false,
          tooltip: 'Trocar o modelo desta sessão',
          color: s.model == null ? null : _modelColor(c, s.model!),
          onSelected: (m) {
            if (m != null && m != s.model) sessionAction(context, () => sessions.setModel(s.id, m));
          },
        ),
      ),
      const SizedBox(width: 8),
      _PermissionModeSelector(key: ValueKey('mode-${s.id}'), session: s),
    ];
    final title = Text(
      s.title,
      key: const ValueKey('session-title'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.textPrimary),
    );
    final meta = Text(
      [
        ?shortModel(s.model),
        permissionModeLabel(s.permissionMode),
        if (s.cost > 0) '\$${s.cost.toStringAsFixed(2)}',
      ].join(' · '),
      key: const ValueKey('session-meta'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: c.textSecondary),
    );
    final aside = s.canAskAside
        ? IconButton(
            key: const ValueKey('session-aside'),
            tooltip: 'Perguntar à parte: vê tudo desta sessão, só lê e não entra no contexto dela',
            onPressed: () => unawaited(showAsideQuestion(context, s)),
            icon: Icon(Icons.forum_outlined, size: 18, color: c.textSecondary),
          )
        : null;
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
            ? Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    title,
                    const SizedBox(height: 2),
                    meta,
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Flexible(child: status),
                        const SizedBox(width: 12),
                        command,
                        const SizedBox(width: 12),
                        ...details,
                        const Spacer(),
                        ?aside,
                        const SizedBox(width: 8),
                        ?interrupt,
                      ],
                    ),
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    title,
                    const SizedBox(height: 2),
                    meta,
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 36,
                      child: Row(
                        children: [
                          Expanded(
                            child: Align(alignment: Alignment.centerLeft, child: status),
                          ),
                          ?aside,
                          ?interrupt,
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [command]),
                    const SizedBox(height: 6),
                    // Own line: provider, model and mode chips do not fit next to the command in a side panel.
                    Wrap(spacing: 0, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: details),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Asks for the text of a side question about [s], forks it and opens the new session.
Future<void> showAsideQuestion(BuildContext context, SessionSummary s) async {
  final text = await showDialog<String>(context: context, builder: (_) => const _AsideDialog());
  if (text == null || text.isEmpty || !context.mounted) return;
  final router = GoRouter.of(context);
  await sessionAction(context, () async {
    final aside = await SessionsScope.of(context).askAside(s.id, text);
    router.go(sessionLocation(aside));
  });
}

class _AsideDialog extends StatefulWidget {
  const _AsideDialog();

  @override
  State<_AsideDialog> createState() => _AsideDialogState();
}

class _AsideDialogState extends State<_AsideDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Perguntar à parte'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Muted(
            'Abre uma conversa que vê tudo o que esta sessão fez, só lê, e não entra no contexto dela.',
            size: 12.5,
          ),
          const SizedBox(height: 12),
          CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send},
            child: TextField(
              key: const ValueKey('aside-text'),
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(hintText: 'Por que essa abordagem? O que falta na task T3?  (⌘↵)'),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
      FilledButton(key: const ValueKey('aside-send'), onPressed: _send, child: const Text('Perguntar')),
    ],
  );
}

/// A side question: where it came from, and the way back.
class _AsideBanner extends StatelessWidget {
  const _AsideBanner({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final all = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    final parent = all.where((p) => p.id == session.asideOf).firstOrNull;
    return Container(
      key: const ValueKey('aside-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: c.elevated,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.forum_outlined, size: 14, color: c.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parent == null
                  ? 'Pergunta à parte de uma sessão que não existe mais. Não entra no contexto de ninguém.'
                  : 'Pergunta à parte de “${parent.title}”: vê o que ela fez e não entra no contexto dela.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
          if (parent != null)
            TextButton(
              key: const ValueKey('aside-back'),
              onPressed: () => GoRouter.of(context).go(sessionLocation(parent)),
              child: const Text('Ver a original', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

/// Opens at the end, follows new content only while the user is within [_followSlack] of it, and otherwise offers
/// a button back to the end.
class _Feed extends StatefulWidget {
  const _Feed({required this.nearEnd, required this.version, required this.children});

  final ValueNotifier<bool> nearEnd;

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
    final near = _nearEnd;
    widget.nearEnd.value = near;
    if (_newBelow && near) setState(() => _newBelow = false);
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
      widget.nearEnd.value = true;
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
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
    modes: PermissionMode.values,
    onSelected: _busy ? null : _change,
  );
}

/// Where an org session runs: its `cwd` (the org's first root) and the other roots it can reach.
class _Directories extends StatelessWidget {
  const _Directories({super.key, required this.session});

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
  const _DetachedBanner({required this.resumable, required this.imported, required this.onResume});

  final bool resumable;

  /// Just brought from the terminal: no process of the app ever ran it.
  final bool imported;
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
          Icon(imported ? Icons.terminal : Icons.link_off, size: 16, color: c.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              imported
                  ? 'Sessão trazida do terminal. Retomar continua a conversa aqui; se o terminal ainda estiver com '
                        'ela aberta, o app segue num ramo novo e o terminal não vê o que for feito aqui.'
                  : 'O processo desta sessão terminou com o app. Retomar reanexa com o histórico completo; '
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
  const _Typing({super.key});

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
  const _Composer({required this.enabled, required this.waiting, required this.blockedReason, required this.onSend});

  final bool enabled;
  final bool waiting;
  final String? Function(String text) blockedReason;
  final Future<void> Function(String text, List<ImageAttachment> images) onSend;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> with ImageAttachments<_Composer> {
  final _controller = TextEditingController();
  String? _blocked;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (!widget.enabled || (text.isEmpty && images.isEmpty)) return;
    final blocked = widget.blockedReason(text);
    if (blocked != null) {
      setState(() => _blocked = blocked);
      return;
    }
    _controller.clear();
    widget.onSend(text.isEmpty ? kImagesOnlyText : text, takeImages());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.enabled;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: c.border),
    );
    return imageDropTarget(
      context,
      enabled: enabled,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            imagesPreview(context),
            Row(
              children: [
                IconButton(
                  key: const ValueKey('composer-attach'),
                  tooltip: 'Anexar imagem (ou cole com ⌘V)',
                  onPressed: enabled ? pickImages : null,
                  icon: Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 20,
                    color: enabled ? c.textSecondary : c.textMuted,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send},
                    child: Focus(
                      onKeyEvent: onPasteKey,
                      child: TextField(
                        key: const ValueKey('composer-input'),
                        controller: _controller,
                        enabled: enabled,
                        onChanged: (_) {
                          if (_blocked != null) setState(() => _blocked = null);
                        },
                        minLines: 1,
                        maxLines: 5,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: widget.waiting
                              ? 'Decida a permissão acima para continuar'
                              : enabled
                              ? 'Responder à sessão…  (⌘↵ envia · ⌘V cola imagem)'
                              : 'Sessão encerrada',
                          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                          errorText: _blocked,
                          errorMaxLines: 3,
                          errorStyle: TextStyle(color: c.fail, fontSize: 12),
                          filled: true,
                          fillColor: c.surface,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          border: border,
                          enabledBorder: border,
                          disabledBorder: border,
                          focusedBorder: border.copyWith(borderSide: BorderSide(color: c.accent)),
                          errorBorder: border.copyWith(borderSide: BorderSide(color: c.fail)),
                          focusedErrorBorder: border.copyWith(borderSide: BorderSide(color: c.fail)),
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
          ],
        ),
      ),
    );
  }
}

Color _modelColor(AppColors c, String model) {
  final tier = Tier.values.where((t) => model.contains(t.name)).firstOrNull;
  return tier == null ? c.idle : c.tier(tier);
}

/// Way out of a failed turn: ask the agent to pick up where it stopped, or move the session to another model first.
class _FailureActions extends StatelessWidget {
  const _FailureActions({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sessions = SessionsScope.of(context);
    final s = session;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('failure-retry'),
          style: OutlinedButton.styleFrom(
            foregroundColor: c.textPrimary,
            side: BorderSide(color: c.borderStrong),
          ),
          onPressed: () => sessionAction(context, () => sessions.send(s.id, 'Continue de onde parou.')),
          icon: const Icon(Icons.refresh, size: 15),
          label: const Text('Tentar de novo', style: TextStyle(fontSize: 12)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: ModelMenu(
            key: ValueKey('failure-model-${s.id}'),
            provider: s.provider,
            account: s.account,
            model: s.model,
            allowDefault: false,
            tooltip: 'Trocar modelo',
            onSelected: (m) {
              if (m != null && m != s.model) sessionAction(context, () => sessions.setModel(s.id, m));
            },
          ),
        ),
      ],
    );
  }
}
