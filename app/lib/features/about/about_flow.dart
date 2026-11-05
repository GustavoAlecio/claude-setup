import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/inline_markdown.dart';
import '../../core/widgets/primitives.dart';
import '../../data/inventory_models.dart';
import '../../data/inventory_parser.dart';
import '../../data/models.dart';
import 'about_widgets.dart';

enum _AuxKind { workflow, alternative, agent }

/// The only stage → helper links kept in code; everything shown about them is read from disk.
const _aux = {
  Stage.implement: (_AuxKind.workflow, 'smart-implement'),
  Stage.verify: (_AuxKind.workflow, 'smart-verify'),
  Stage.plan: (_AuxKind.alternative, 'tot-plan'),
  Stage.challenge: (_AuxKind.agent, 'spec-challenger'),
};

const kRiskRule = 'risk high: +1 degrau (máx. opus); override de routing.json vence';
const kRiskRulePath = 'skills/tasks/SKILL.md';

class _Node {
  _Node(this.stage, Inventory inventory)
    : skill = inventory.skills.where((s) => skillDir(s) == stage.label).firstOrNull,
      aux = _aux[stage],
      workflow = switch (_aux[stage]) {
        (_AuxKind.workflow || _AuxKind.alternative, final name) =>
          inventory.workflows.where((w) => workflowFile(w) == name).firstOrNull,
        _ => null,
      },
      agent = switch (_aux[stage]) {
        (_AuxKind.agent, final name) => inventory.agents.where((a) => a.path.endsWith('/$name.md')).firstOrNull,
        _ => null,
      };

  final Stage stage;
  final InventoryItem? skill;
  final (_AuxKind, String)? aux;
  final WorkflowEntry? workflow;
  final InventoryItem? agent;
}

class AboutFlow extends StatefulWidget {
  const AboutFlow({super.key, required this.inventory});

  final Inventory inventory;

  @override
  State<AboutFlow> createState() => _AboutFlowState();
}

class _AboutFlowState extends State<AboutFlow> {
  Stage? _selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final nodes = [for (final s in Stage.values) _Node(s, widget.inventory)];
    final selected = nodes.where((n) => n.stage == _selected).firstOrNull;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final (i, node) in nodes.indexed) ...[
              if (i > 0) Icon(Icons.arrow_forward, size: 16, color: c.textMuted),
              _StageNode(
                node: node,
                selected: node.stage == _selected,
                onTap: () => setState(() => _selected = _selected == node.stage ? null : node.stage),
              ),
            ],
          ],
        ),
        if (selected != null) ...[
          const SizedBox(height: 16),
          _NodeDetail(node: selected, onClose: () => setState(() => _selected = null)),
        ],
        const SizedBox(height: 20),
        _LadderPanel(ladder: widget.inventory.ladder, stacks: widget.inventory.stacks),
      ],
    );
  }
}

class _StageNode extends StatelessWidget {
  const _StageNode({required this.node, required this.selected, required this.onTap});

  final _Node node;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final skill = node.skill;
    return InkWell(
      key: ValueKey('about-node-${node.stage.label}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 210,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? c.accent : c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Mono(node.stage.label, color: c.textMuted, size: 11),
            const SizedBox(height: 6),
            if (skill == null)
              Text('não instalado', style: TextStyle(fontSize: 13, color: c.warn))
            else if (skill.error != null)
              ErrorText(skill.error!)
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      skill.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  ModelPill(skill.model),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                firstSentence(skill.description),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
            ],
            if (node.aux case (final kind, final name)) ...[
              const SizedBox(height: 6),
              _AuxSummary(node: node, kind: kind, name: name),
            ],
          ],
        ),
      ),
    );
  }
}

class _AuxSummary extends StatelessWidget {
  const _AuxSummary({required this.node, required this.kind, required this.name});

  final _Node node;
  final _AuxKind kind;
  final String name;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = switch (kind) {
      _AuxKind.workflow => 'workflow',
      _AuxKind.alternative => 'alternativa',
      _AuxKind.agent => 'agente',
    };
    final installed = kind == _AuxKind.agent ? node.agent != null : node.workflow != null;
    if (!installed) return Muted('$label $name: não instalado', size: 11);
    final meta = node.workflow?.meta;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(child: Muted('$label: $name', size: 11)),
            if (node.agent case final agent?) ...[const SizedBox(width: 6), ModelPill(agent.model)],
          ],
        ),
        if (kind == _AuxKind.workflow && meta != null)
          if (meta.error != null)
            ErrorText(meta.error!)
          else
            for (final phase in meta.phases) Mono('· ${phase.title}', color: c.textSecondary, size: 11),
      ],
    );
  }
}

class _NodeDetail extends StatelessWidget {
  const _NodeDetail({required this.node, required this.onClose});

  final _Node node;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final skill = node.skill;
    final meta = node.workflow?.meta;
    return Panel(
      key: const ValueKey('about-node-detail'),
      title: node.stage.label,
      trailing: IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 16), tooltip: 'Fechar'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (skill == null)
            Muted('não instalado: ${node.stage.label}/SKILL.md')
          else ...[
            if (skill.error != null) ErrorText(skill.error!) else InlineMarkdown(skill.description),
            const SizedBox(height: 6),
            SelectableText(skill.path, style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
          if (node.agent case final agent?) ...[
            const SectionTitle('AGENTE'),
            Text(agent.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if (agent.error != null) ErrorText(agent.error!) else InlineMarkdown(agent.description),
            SelectableText(agent.path, style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
          if (node.workflow case final workflow?) ...[
            SectionTitle('WORKFLOW ${workflowFile(workflow)}'),
            if (meta!.error != null) ErrorText(meta.error!) else InlineMarkdown(meta.description),
            for (final phase in meta.phases)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: phase.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (phase.detail.isNotEmpty) TextSpan(text: ' — ${phase.detail}'),
                    ],
                  ),
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
              ),
            const SizedBox(height: 6),
            SelectableText(workflow.path, style: TextStyle(fontSize: 11, color: c.textMuted)),
          ],
        ],
      ),
    );
  }
}

class _LadderPanel extends StatelessWidget {
  const _LadderPanel({required this.ladder, required this.stacks});

  final Ladder ladder;
  final List<StackInfo> stacks;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Panel(
      key: const ValueKey('about-ladder'),
      title: 'Escada de modelos',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ladder.error != null) ErrorText(ladder.error!),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (i, tier) in ladder.tiers.indexed) ...[
                if (i > 0) Icon(Icons.arrow_forward, size: 14, color: c.textMuted),
                ModelPill(tier),
              ],
            ],
          ),
          const SectionTitle('TIER INICIAL POR COMPLEXIDADE'),
          Wrap(
            spacing: 16,
            children: [for (final MapEntry(:key, :value) in ladder.tier0.entries) Mono('$key → $value')],
          ),
          const SizedBox(height: 10),
          Text(kRiskRule, style: TextStyle(fontSize: 12, color: c.textSecondary)),
          Mono(kRiskRulePath, color: c.textMuted, size: 11),
          const SectionTitle('SEVERIDADES QUE REPROVAM'),
          Mono(ladder.blocking.isEmpty ? 'nenhuma' : ladder.blocking.join(', ')),
          const SectionTitle('REVIEWERS POR STACK'),
          if (stacks.isEmpty) const Muted('nenhuma stack'),
          for (final stack in stacks)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${stack.name} — G1: ${stack.g1Reviewers.isEmpty ? '—' : stack.g1Reviewers.join(', ')}'
                ' · G2: ${stack.g2Agent ?? '—'}',
                style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
