import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primitives.dart';
import '../../data/session_models.dart';

class SessionEventView extends StatelessWidget {
  const SessionEventView(this.event, {super.key});

  final SessionEvent event;

  @override
  Widget build(BuildContext context) => switch (event) {
    final UserText e => _UserBubble(e),
    final AssistantText e => _AssistantBlock(e),
    final Thinking e => _ThinkingRow(e),
    final ToolCall e => _ToolRow(e),
    final PermissionRequest e => PermissionCard(e),
    final QuestionRequest e => QuestionCard(e),
    final SessionResult e => _ResultFooter(e),
  };
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.e);

  final UserText e;

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
        child: Text(e.text, style: TextStyle(fontSize: 13, color: c.textPrimary)),
      ),
    );
  }
}

class _AssistantBlock extends StatelessWidget {
  const _AssistantBlock(this.e);

  final AssistantText e;

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
        Expanded(child: InlineMarkdown(e.text)),
      ],
    );
  }
}

/// Enough markdown for assistant turns: paragraphs, `- ` bullets, **bold** and `code`.
class InlineMarkdown extends StatelessWidget {
  const InlineMarkdown(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = TextStyle(fontSize: 13, height: 1.5, color: c.textPrimary);
    final lines = source.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          if (line.trim().isEmpty)
            const SizedBox(height: 6)
          else if (line.startsWith('- '))
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: base.copyWith(color: c.textMuted)),
                  Expanded(child: Text.rich(TextSpan(children: _spans(line.substring(2), base, c)))),
                ],
              ),
            )
          else
            Text.rich(TextSpan(children: _spans(line, base, c))),
      ],
    );
  }

  static final _token = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`)');

  List<InlineSpan> _spans(String text, TextStyle base, AppColors c) {
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start), style: base));
      final t = m.group(0)!;
      out.add(
        t.startsWith('**')
            ? TextSpan(
                text: t.substring(2, t.length - 2),
                style: base.copyWith(fontWeight: FontWeight.w600),
              )
            : WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: c.elevated, borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    t.substring(1, t.length - 1),
                    style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.accent),
                  ),
                ),
              ),
      );
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last), style: base));
    return out;
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
              Muted('pensou por ${widget.e.seconds}s'),
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
    final status = e.running
        ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.running))
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
            onTap: e.result == null ? null : () => setState(() => _open = !_open),
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
                      e.summary,
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
          if (_open)
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
  const PermissionCard(this.e, {super.key});

  final PermissionRequest e;

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
  late PermissionDecision? _decision = widget.e.decision;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = widget.e;
    final pending = _decision == null;
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
                ? Row(
                    children: [
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: c.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        onPressed: () => setState(() => _decision = PermissionDecision.allow),
                        child: const Text('Permitir', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.textSecondary,
                          side: BorderSide(color: c.borderStrong),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        onPressed: () => setState(() => _decision = PermissionDecision.always),
                        child: Text('Sempre permitir ${e.toolName} nesta sessão', style: const TextStyle(fontSize: 12)),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _decision = PermissionDecision.deny),
                        child: Text('Negar', style: TextStyle(fontSize: 12, color: c.fail)),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Icon(
                        _decision == PermissionDecision.deny ? Icons.block : Icons.check_circle_outline,
                        size: 14,
                        color: _decision == PermissionDecision.deny ? c.fail : c.pass,
                      ),
                      const SizedBox(width: 8),
                      Muted(switch (_decision!) {
                        PermissionDecision.allow => 'permitido',
                        PermissionDecision.always => 'permitido · ${e.toolName} liberado para esta sessão',
                        PermissionDecision.deny => 'negado',
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
  const QuestionCard(this.e, {super.key});

  final QuestionRequest e;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final _picked = <String>{};
  final _other = TextEditingController();
  late String? _answer = widget.e.answer;

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  void _toggle(String label) => setState(() {
    if (!widget.e.multiSelect) _picked.clear();
    _picked.contains(label) ? _picked.remove(label) : _picked.add(label);
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final e = widget.e;
    final pending = _answer == null;
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
          Row(
            children: [
              Pill(label: e.header, color: c.accent, dot: false),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  e.question,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
              ),
              if (e.multiSelect) const Muted('várias', size: 11),
            ],
          ),
          const SizedBox(height: 10),
          if (!pending)
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 14, color: c.pass),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('respondido: $_answer', style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                ),
              ],
            )
          else ...[
            for (final o in e.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _toggle(o.label),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _picked.contains(o.label) ? c.accent.withValues(alpha: 0.10) : c.elevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _picked.contains(o.label) ? c.accent : c.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          e.multiSelect
                              ? (_picked.contains(o.label) ? Icons.check_box : Icons.check_box_outline_blank)
                              : (_picked.contains(o.label) ? Icons.radio_button_checked : Icons.radio_button_off),
                          size: 16,
                          color: _picked.contains(o.label) ? c.accent : c.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Mono(o.label, color: c.textPrimary, size: 12.5),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(o.description, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _other,
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
                const SizedBox(width: 10),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: _picked.isEmpty && _other.text.trim().isEmpty
                      ? null
                      : () => setState(
                          () => _answer = _other.text.trim().isNotEmpty ? _other.text.trim() : _picked.join(', '),
                        ),
                  child: const Text('Responder', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
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
