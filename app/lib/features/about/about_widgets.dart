import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/inventory_models.dart';
import '../../data/models.dart';

/// Stage → skill links use the skill's directory, not its frontmatter `name`.
String skillDir(InventoryItem skill) {
  final parts = skill.path.split('/');
  return parts.length >= 2 ? parts[parts.length - 2] : skill.name;
}

String workflowFile(WorkflowEntry workflow) => workflow.path.split('/').last.replaceFirst(RegExp(r'\.js$'), '');

/// Pipeline skills are the stages themselves: the skill directory is the stage label.
final kPipelineSkills = {for (final s in Stage.values) s.label};

class ModelPill extends StatelessWidget {
  const ModelPill(this.model, {super.key});

  final String? model;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tier = Tier.values.where((t) => t.name == model).firstOrNull;
    return Pill(label: model ?? 'padrão', color: tier == null ? c.textMuted : c.tier(tier), mono: true);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(top: 20, bottom: 8), child: Muted(text, size: 11));
}

class ErrorText extends StatelessWidget {
  const ErrorText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: 12, color: context.colors.fail));
}
