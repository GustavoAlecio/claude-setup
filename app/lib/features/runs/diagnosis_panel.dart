import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';

const _actions = {
  'fix_spec': ('Corrigir spec', '/challenge-spec'),
  'replan': ('Replanejar', '/plan'),
  'fix_environment': ('Corrigir ambiente', '/implement'),
  'split_task': ('Quebrar task', '/tasks'),
  'human_takeover': ('Assumir a task', null),
};

const _reasons = {
  'same_failure_across_tiers':
      'A mesma falha sobreviveu a dois modelos diferentes — não é capacidade, é spec ou plano.',
  'ladder_exhausted': 'A escada chegou ao topo (fable) sem passar nos gates.',
  'max_attempts': 'Limite de 5 tentativas atingido.',
};

class DiagnosisPanel extends StatelessWidget {
  const DiagnosisPanel({super.key, required this.task, this.onExpand});

  final TaskRun task;

  /// Set when the panel is shown outside the task detail: only the top hypothesis is rendered.
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ranked = [...task.diagnosis]..sort((a, b) => b.confidence.compareTo(a.confidence));
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.fail.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.account_tree_outlined, size: 18, color: c.fail),
              const SizedBox(width: 8),
              Text('${task.id} bloqueada · diagnóstico ToT', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 10),
              Mono(task.blockedReason ?? '', color: c.fail, size: 11),
            ],
          ),
          const SizedBox(height: 6),
          Muted(_reasons[task.blockedReason] ?? '', size: 12),
          const SizedBox(height: 14),
          if (onExpand != null && ranked.isNotEmpty)
            _CompactTop(h: ranked.first, others: ranked.length - 1, onExpand: onExpand!)
          else
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, h) in ranked.indexed) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: _HypothesisCard(h: h, top: i == 0),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HypothesisCard extends StatelessWidget {
  const _HypothesisCard({required this.h, required this.top});

  final Hypothesis h;
  final bool top;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: top ? c.accent.withValues(alpha: 0.6) : c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(label: 'lente: ${h.lens}', color: top ? c.accent : c.idle, dot: false),
              const Spacer(),
              Mono('${(h.confidence * 100).round()}%', color: c.textPrimary),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: h.confidence,
              minHeight: 3,
              backgroundColor: c.border,
              color: top ? c.accent : c.idle,
            ),
          ),
          const SizedBox(height: 12),
          Text(h.hypothesis, style: TextStyle(fontSize: 12.5, height: 1.45, color: c.textPrimary)),
          const SizedBox(height: 10),
          for (final e in h.evidence)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Muted('↳ ', size: 11),
                  Expanded(child: Mono(e, size: 11)),
                ],
              ),
            ),
          const Spacer(),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: _ActionButton(action: h.action, primary: top),
          ),
        ],
      ),
    );
  }
}

class _CompactTop extends StatelessWidget {
  const _CompactTop({required this.h, required this.others, required this.onExpand});

  final Hypothesis h;
  final int others;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Pill(label: 'lente: ${h.lens}', color: c.accent, dot: false),
              const SizedBox(height: 6),
              Mono('${(h.confidence * 100).round()}% confiança', color: c.textPrimary, size: 11),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              h.hypothesis,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: c.textPrimary),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(width: 200, child: _ActionButton(action: h.action, primary: true)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onExpand,
            child: Text('ver as ${others + 1} hipóteses', style: TextStyle(fontSize: 12, color: c.textSecondary)),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action, required this.primary});

  final String action;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (label, command) = _actions[action] ?? (action, null);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: primary ? c.accent : c.textSecondary,
        side: BorderSide(color: primary ? c.accent : c.borderStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      onPressed: () {},
      child: Text(command == null ? label : '$label  $command', style: const TextStyle(fontSize: 12)),
    );
  }
}
