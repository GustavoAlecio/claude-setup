import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../data/docs_repository.dart';
import '../../data/session_failure.dart';
import '../../data/session_models.dart';
import '../../data/session_reducer.dart';

/// Sends the user's decision to the engine; the card's resolved state comes back through the session stream.
typedef AnswerRequest =
    Future<void> Function(String requestId, PermissionDecision decision, {Map<String, String>? answers});

class SessionEventView extends StatelessWidget {
  const SessionEventView(
    this.event, {
    super.key,
    required this.onAnswer,
    this.onLink,
    this.attachmentUri,
    this.failureActions,
  });

  final SessionEvent event;
  final AnswerRequest onAnswer;

  /// Links in assistant turns; `null` opens them externally.
  final ValueChanged<Uri>? onLink;

  /// Where an image the user attached loads from; `null` (or a `null` result) shows a placeholder.
  final Uri? Function(String name)? attachmentUri;

  /// Buttons of a failure card ("Tentar de novo", model); only the session's last event gets them.
  final Widget? failureActions;

  @override
  Widget build(BuildContext context) => switch (event) {
    final UserText e => _UserBubble(e, attachmentUri: attachmentUri),
    final AssistantText e => _AssistantBlock(e, onLink: onLink),
    final Thinking e => _ThinkingRow(e),
    final ToolCall e => _ToolRow(e),
    final PermissionRequest e => PermissionCard(e, onAnswer: onAnswer),
    final QuestionRequest e => QuestionCard(e, onAnswer: onAnswer),
    final SessionResult e when e.isError => FailureCard(describeFailure(e.message), actions: failureActions),
    final SessionResult e => _ResultFooter(e),
    final SessionError e => FailureCard(describeFailure(e.message), actions: failureActions),
    final SessionNote e => _NoteLine(e),
  };
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.e, {this.attachmentUri});

  final UserText e;
  final Uri? Function(String name)? attachmentUri;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: c.elevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (e.images.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [for (final name in e.images) _Attachment(attachmentUri?.call(name))],
              ),
              const SizedBox(height: 8),
            ],
            Text(e.text, style: TextStyle(fontSize: 13, color: c.textPrimary)),
          ],
        ),
      ),
    );
  }
}

/// Thumbnail of an image the user sent; a tap opens it at full size.
class _Attachment extends StatelessWidget {
  const _Attachment(this.uri);

  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final placeholder = Container(
      width: 96,
      height: 72,
      alignment: Alignment.center,
      color: c.surface,
      child: Icon(Icons.image_outlined, size: 20, color: c.textMuted),
    );
    final uri = this.uri;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: uri == null
          ? placeholder
          : InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => Dialog(
                  backgroundColor: c.canvas,
                  child: InteractiveViewer(child: Image.network(uri.toString())),
                ),
              ),
              child: Image.network(
                uri.toString(),
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
            ),
    );
  }
}

class _AssistantBlock extends StatelessWidget {
  const _AssistantBlock(this.e, {this.onLink});

  final AssistantText e;
  final ValueChanged<Uri>? onLink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.auto_awesome, size: 15, color: c.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: MarkdownView(
            e.text,
            onLink: onLink ?? (uri) => DocsScope.openExternal(context, uri, logName: 'SessionFeed'),
          ),
        ),
      ],
    );
  }
}

class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow(this.e);

  final Thinking e;

  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 16, color: c.textMuted),
              const SizedBox(width: 4),
              Muted(widget.e.seconds == null ? 'pensou' : 'pensou por ${widget.e.seconds}s'),
            ],
          ),
        ),
        if (_open)
          Container(
            margin: const EdgeInsets.only(left: 20, top: 6),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: c.borderStrong, width: 2)),
            ),
            child: Text(
              widget.e.text,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: c.textSecondary, fontStyle: FontStyle.italic),
            ),
          ),
      ],
    );
  }
}

class _ToolRow extends StatefulWidget {
  const _ToolRow(this.e);

  final ToolCall e;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _open = false;

  static IconData _icon(String name) => switch (name) {
    'Read' => Icons.description_outlined,
    'Grep' || 'Glob' => Icons.search,
    'Bash' => Icons.terminal,
    'Edit' || 'Write' => Icons.edit_outlined,
    'Agent' => Icons.hub_outlined,
    _ => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = widget.e;
    final lines = e.summary.trim().split('\n');
    final multiline = lines.length > 1;
    final expandable = e.result != null || multiline;
    final status = e.running
        ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.running))
        : e.interrupted
        ? Icon(Icons.block, size: 14, color: c.idle)
        : Icon(e.isError ? Icons.close : Icons.check, size: 14, color: e.isError ? c.fail : c.pass);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: expandable ? () => setState(() => _open = !_open) : null,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(_icon(e.name), size: 14, color: c.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    e.name,
                    style: TextStyle(
                      fontFamily: monoFamily,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      // A multi-line command (`python3 -c "…"`) shows its first line; the rest opens below.
                      multiline ? '${lines.first.trim()}  (+${lines.length - 1} linhas)' : e.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.textSecondary),
                    ),
                  ),
                  if (e.result != null && !_open) ...[
                    Flexible(
                      child: Text(
                        e.result!.split('\n').first,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: c.textMuted),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  status,
                ],
              ),
            ),
          ),
          if (_open && multiline)
            Container(
              key: const ValueKey('tool-command'),
              padding: const EdgeInsets.fromLTRB(34, 8, 12, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Mono(e.summary.trim(), size: 11.5, color: c.textPrimary),
            ),
          if (_open && e.result != null)
            Container(
              padding: const EdgeInsets.fromLTRB(34, 8, 12, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Mono(e.result!, size: 11.5),
            ),
        ],
      ),
    );
  }
}

class PermissionCard extends StatefulWidget {
  const PermissionCard(this.e, {super.key, required this.onAnswer});

  final PermissionRequest e;
  final AnswerRequest onAnswer;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  bool _sending = false;

  Future<void> _decide(PermissionDecision decision) async {
    setState(() => _sending = true);
    try {
      await widget.onAnswer(widget.e.requestId, decision);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = widget.e;
    final decision = e.decision;
    final pending = e.pending;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pending ? c.warn.withValues(alpha: 0.7) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 16, color: pending ? c.warn : c.textMuted),
                const SizedBox(width: 8),
                Text(
                  'Permissão',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
                const SizedBox(width: 8),
                Mono(e.toolName, color: c.textPrimary),
                const SizedBox(width: 10),
                Expanded(child: Mono(e.target, size: 11.5)),
                if (e.diff.isNotEmpty) _DiffStat(e.diff),
              ],
            ),
          ),
          if (e.diff.isNotEmpty) DiffView(e.diff),
          if (e.command != null)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Mono(e.command!, color: c.textPrimary),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: pending
                ? LayoutBuilder(
                    builder: (context, constraints) {
                      final allow = FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: c.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        onPressed: _sending ? null : () => _decide(PermissionDecision.allow),
                        child: const Text('Permitir', style: TextStyle(fontSize: 12)),
                      );
                      final always = OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.textSecondary,
                          side: BorderSide(color: c.borderStrong),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        onPressed: _sending ? null : () => _decide(PermissionDecision.always),
                        child: Text('Sempre permitir ${e.toolName} nesta sessão', style: const TextStyle(fontSize: 12)),
                      );
                      final deny = TextButton(
                        onPressed: _sending ? null : () => _decide(PermissionDecision.deny),
                        child: Text('Negar', style: TextStyle(fontSize: 12, color: c.fail)),
                      );
                      // The Fluxo side panel is too narrow for one row.
                      if (constraints.maxWidth < 560) {
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [allow, always, deny],
                        );
                      }
                      return Row(children: [allow, const SizedBox(width: 8), always, const Spacer(), deny]);
                    },
                  )
                : Row(
                    children: [
                      Icon(
                        decision == null || decision == PermissionDecision.deny
                            ? Icons.block
                            : Icons.check_circle_outline,
                        size: 14,
                        color: switch (decision) {
                          null || PermissionDecision.aborted => c.idle,
                          PermissionDecision.deny => c.fail,
                          _ => c.pass,
                        },
                      ),
                      const SizedBox(width: 8),
                      Muted(switch (decision) {
                        null => 'expirada',
                        PermissionDecision.allow || PermissionDecision.answer => 'permitido',
                        PermissionDecision.always => 'permitido · ${e.toolName} liberado para esta sessão',
                        PermissionDecision.deny => 'negado',
                        PermissionDecision.aborted => 'cancelada',
                      }),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _DiffStat extends StatelessWidget {
  const _DiffStat(this.diff);

  final List<DiffLine> diff;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final add = diff.where((d) => d.kind == '+').length;
    final del = diff.where((d) => d.kind == '-').length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Mono('+$add', color: c.pass, size: 11.5),
        const SizedBox(width: 6),
        Mono('−$del', color: c.fail, size: 11.5),
      ],
    );
  }
}

class DiffView extends StatelessWidget {
  const DiffView(this.lines, {super.key});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.canvas,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines)
            Container(
              color: switch (l.kind) {
                '+' => c.pass.withValues(alpha: 0.10),
                '-' => c.fail.withValues(alpha: 0.10),
                _ => null,
              },
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
              child: Row(
                children: [
                  SizedBox(width: 36, child: Mono(l.number?.toString() ?? '', size: 11, color: c.textMuted)),
                  SizedBox(
                    width: 16,
                    child: Mono(
                      l.kind,
                      size: 12,
                      color: switch (l.kind) {
                        '+' => c.pass,
                        '-' => c.fail,
                        _ => c.textMuted,
                      },
                    ),
                  ),
                  Expanded(child: Mono(l.text, size: 12, color: c.textPrimary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class QuestionCard extends StatefulWidget {
  const QuestionCard(this.e, {super.key, required this.onAnswer});

  final QuestionRequest e;
  final AnswerRequest onAnswer;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final _picked = <String, Set<String>>{};
  late final _other = {for (final q in widget.e.questions) q.question: TextEditingController()};
  bool _sending = false;

  /// `permission_resolved` from the engine may omit the answers; what this client sent fills the gap.
  Map<String, String>? _sent;

  @override
  void dispose() {
    for (final c in _other.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _toggle(Question q, String label) => setState(() {
    final picked = _picked.putIfAbsent(q.question, () => <String>{});
    if (!q.multiSelect) picked.retainAll({label});
    picked.contains(label) ? picked.remove(label) : picked.add(label);
  });

  Map<String, String> get _draft => answersFor(
    widget.e.questions,
    _picked,
    free: {for (final MapEntry(:key, :value) in _other.entries) key: value.text},
  );

  Future<void> _respond() async {
    final answers = _draft;
    setState(() => _sending = true);
    try {
      await widget.onAnswer(widget.e.requestId, PermissionDecision.answer, answers: answers);
      _sent = answers;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = widget.e;
    final answers = e.answers ?? _sent;
    final pending = e.pending;
    final complete = _draft.length == e.questions.length;
    return LayoutBuilder(
      builder: (context, box) => _card(c, e, answers, pending, complete, narrow: box.maxWidth < 440),
    );
  }

  Widget _card(
    AppColors c,
    QuestionRequest e,
    Map<String, String>? answers,
    bool pending,
    bool complete, {
    required bool narrow,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: pending ? c.accent.withValues(alpha: 0.7) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A long card scrolls its bottom button out of a short panel; the progress bar keeps one in reach.
          if (pending && e.questions.fold(0, (n, q) => n + q.options.length) > 3) ...[
            Row(
              key: const ValueKey('question-progress'),
              children: [
                Expanded(
                  child: Muted(
                    '${_draft.length} de ${countLabel(e.questions.length, 'pergunta')} respondida'
                    '${_draft.length == 1 ? '' : 's'}',
                    size: 11.5,
                  ),
                ),
                _respondButton(c, complete),
              ],
            ),
            const SizedBox(height: 10),
          ],
          for (final q in e.questions) ...[
            Row(
              children: [
                Pill(label: q.header, color: c.accent, dot: false),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    q.question,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textPrimary),
                  ),
                ),
                if (q.multiSelect) const Muted('várias', size: 11),
              ],
            ),
            const SizedBox(height: 10),
            if (pending) ..._options(c, q, narrow: narrow),
          ],
          if (!pending)
            Row(
              children: [
                Icon(
                  e.expired ? Icons.block : Icons.check_circle_outline,
                  size: 14,
                  color: e.expired ? c.idle : c.pass,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.expired
                        ? 'expirada'
                        : answers == null || answers.isEmpty
                        ? 'respondido'
                        : 'respondido: ${answers.values.join(' · ')}',
                    style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                  ),
                ),
              ],
            )
          else
            Align(alignment: Alignment.centerRight, child: _respondButton(c, complete)),
        ],
      ),
    );
  }

  Widget _respondButton(AppColors c, bool complete) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: c.accent,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    onPressed: complete && !_sending ? _respond : null,
    child: const Text('Responder', style: TextStyle(fontSize: 12)),
  );

  List<Widget> _options(AppColors c, Question q, {required bool narrow}) {
    final picked = _picked[q.question] ?? const <String>{};
    return [
      for (final o in q.options)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _toggle(q, o.label),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: picked.contains(o.label) ? c.accent.withValues(alpha: 0.10) : c.elevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: picked.contains(o.label) ? c.accent : c.border),
              ),
              child: Row(
                children: [
                  Icon(
                    q.multiSelect
                        ? (picked.contains(o.label) ? Icons.check_box : Icons.check_box_outline_blank)
                        : (picked.contains(o.label) ? Icons.radio_button_checked : Icons.radio_button_off),
                    size: 16,
                    color: picked.contains(o.label) ? c.accent : c.textMuted,
                  ),
                  const SizedBox(width: 10),
                  if (narrow)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Mono(o.label, color: c.textPrimary, size: 12.5),
                          if (o.description.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(o.description, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                          ],
                        ],
                      ),
                    )
                  else ...[
                    Flexible(child: Mono(o.label, color: c.textPrimary, size: 12.5)),
                    if (o.description.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(o.description, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10),
        child: TextField(
          controller: _other[q.question],
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 12.5),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Outro… (resposta livre substitui a seleção)',
            hintStyle: TextStyle(color: c.textMuted, fontSize: 12.5),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: c.border)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: c.accent)),
          ),
        ),
      ),
    ];
  }
}

class _ResultFooter extends StatelessWidget {
  const _ResultFooter(this.e);

  final SessionResult e;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = e.seconds ~/ 60;
    final s = (e.seconds % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        Expanded(child: Divider(color: c.border)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(e.isError ? Icons.error_outline : Icons.flag_outlined, size: 14, color: e.isError ? c.fail : c.pass),
              const SizedBox(width: 6),
              Muted(
                '${e.isError ? 'erro' : 'concluído'} · ${m}m${s}s · ${e.turns} turns · \$${e.cost.toStringAsFixed(2)}',
              ),
            ],
          ),
        ),
        Expanded(child: Divider(color: c.border)),
      ],
    );
  }
}

class _NoteLine extends StatelessWidget {
  const _NoteLine(this.e);

  final SessionNote e;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, text) = switch (e.kind) {
      SessionNoteKind.imported => (
        Icons.terminal,
        e.dropped > 0 ? 'trazida do terminal · ${e.dropped} eventos mais antigos ficaram de fora' : 'trazida do terminal',
      ),
      SessionNoteKind.forked => (
        Icons.call_split,
        'continua num ramo novo · a sessão segue aberta no terminal e não vê o que for feito aqui',
      ),
    };
    return Row(
      children: [
        Expanded(child: Divider(color: c.border)),
        Flexible(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: c.textMuted),
                const SizedBox(width: 6),
                Flexible(child: Muted(text)),
              ],
            ),
          ),
        ),
        Expanded(child: Divider(color: c.border)),
      ],
    );
  }
}

/// A failed turn: what happened in plain words, when the limit resets, the provider's text, and (on the last event)
/// the way out.
class FailureCard extends StatelessWidget {
  const FailureCard(this.failure, {super.key, this.actions});

  final SessionFailure failure;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final resets = failure.resets;
    final hint = failure.hint;
    final actions = this.actions;
    return Container(
      key: const ValueKey('failure-card'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.fail.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.fail.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: c.fail),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  failure.title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
              ),
              if (resets != null) Pill(label: 'renova $resets', color: c.warn, dot: false),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(hint, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: SelectableText(
              failure.detail,
              style: TextStyle(fontFamily: monoFamily, fontSize: 11.5, color: c.textMuted),
            ),
          ),
          if (actions != null) ...[
            const SizedBox(height: 10),
            Padding(padding: const EdgeInsets.only(left: 24), child: actions),
          ],
        ],
      ),
    );
  }
}
