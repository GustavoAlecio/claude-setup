import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/inline_markdown.dart';
import '../../core/widgets/primitives.dart';
import '../../data/inventory_models.dart';
import 'about_widgets.dart';

const kOtherAgents = 'outros';

/// Agents grouped by the prefix before the first `-` when 2 or more share it; the rest go to
/// [kOtherAgents]. Groups are alphabetical with [kOtherAgents] last.
List<(String, List<InventoryItem>)> groupAgents(List<InventoryItem> agents) {
  String? prefix(InventoryItem a) {
    final i = a.name.indexOf('-');
    return i > 0 ? a.name.substring(0, i) : null;
  }

  final counts = <String, int>{};
  for (final a in agents) {
    if (prefix(a) case final p?) counts[p] = (counts[p] ?? 0) + 1;
  }
  final groups = <String, List<InventoryItem>>{};
  final others = <InventoryItem>[];
  for (final a in agents) {
    final p = prefix(a);
    if (p != null && counts[p]! >= 2) {
      (groups[p] ??= []).add(a);
    } else {
      others.add(a);
    }
  }
  return [
    for (final name in groups.keys.toList()..sort()) (name, groups[name]!),
    if (others.isNotEmpty) (kOtherAgents, others),
  ];
}

class AboutInventory extends StatefulWidget {
  const AboutInventory({super.key, required this.inventory, required this.paletteSkills});

  final Inventory inventory;

  /// `null` when the palette lists every skill: then no ⌘K mark is shown.
  final List<String>? paletteSkills;

  @override
  State<AboutInventory> createState() => _AboutInventoryState();
}

class _AboutInventoryState extends State<AboutInventory> {
  String _query = '';

  bool _matches(String name, String description) {
    if (_query.isEmpty) return true;
    return name.toLowerCase().contains(_query) || description.toLowerCase().contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    final inventory = widget.inventory;
    final skills = [
      for (final s in inventory.skills)
        if (_matches(s.name, s.description)) s,
    ];
    final groups = [
      for (final (name, agents) in groupAgents(inventory.agents))
        if (agents.where((a) => _matches(a.name, a.description)).toList() case final shown when shown.isNotEmpty)
          (name, shown),
    ];
    final workflows = [
      for (final w in inventory.workflows)
        if (_matches(w.meta.name, w.meta.description)) w,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      children: [
        TextField(
          key: const ValueKey('about-search'),
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 16),
            hintText: 'buscar em nome e descrição',
          ),
          style: const TextStyle(fontSize: 13),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
        SectionTitle('SKILLS (${inventory.skills.length})'),
        _Section(
          key: const ValueKey('about-skills'),
          children: [
            for (final s in skills)
              _ItemTile(
                key: ValueKey(s.path),
                item: s,
                marks: [
                  if (kPipelineSkills.contains(skillDir(s))) 'pipeline',
                  if (widget.paletteSkills?.contains(skillDir(s)) ?? false) '⌘K',
                ],
              ),
          ],
        ),
        SectionTitle('AGENTES (${inventory.agents.length})'),
        _Section(
          key: const ValueKey('about-agents'),
          children: [
            for (final (name, agents) in groups) ...[
              Padding(
                key: ValueKey('about-agent-group-$name'),
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Mono('$name (${agents.length})', size: 11),
              ),
              for (final a in agents) _ItemTile(key: ValueKey(a.path), item: a, showTools: true),
            ],
          ],
        ),
        SectionTitle('WORKFLOWS (${inventory.workflows.length})'),
        _Section(
          key: const ValueKey('about-workflows'),
          children: [
            for (final w in workflows)
              _ItemTile(
                key: ValueKey(w.path),
                item: InventoryItem(
                  name: w.meta.name,
                  path: w.path,
                  description: w.meta.description,
                  error: w.meta.error,
                ),
                marks: ['${w.meta.phases.length} phases'],
              ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => children.isEmpty
      ? const Muted('nenhum')
      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
}

class _ItemTile extends StatefulWidget {
  const _ItemTile({super.key, required this.item, this.marks = const [], this.showTools = false});

  final InventoryItem item;
  final List<String> marks;
  final bool showTools;

  @override
  State<_ItemTile> createState() => _ItemTileState();
}

class _ItemTileState extends State<_ItemTile> {
  static const _descriptionSize = 12.0;
  static const _lineHeight = 1.5;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final item = widget.item;
    final style = TextStyle(fontSize: _descriptionSize, height: _lineHeight, color: c.textSecondary);
    final description = InlineMarkdown(item.description, style: style);
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(item.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (item.error == null) ModelPill(item.model),
                for (final mark in widget.marks) ...[
                  const SizedBox(width: 6),
                  Pill(label: mark, color: c.accent, dot: false),
                ],
                const Spacer(),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: c.textMuted),
              ],
            ),
            const SizedBox(height: 4),
            if (item.error != null)
              ErrorText(item.error!)
            else if (_expanded)
              description
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _descriptionSize * _lineHeight * 2),
                child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: description),
              ),
            if (widget.showTools && item.tools.isNotEmpty) ...[
              const SizedBox(height: 4),
              Mono('tools: ${item.tools.join(', ')}', color: c.textMuted, size: 11),
            ],
            if (_expanded) ...[
              const SizedBox(height: 4),
              SelectableText(item.path, style: TextStyle(fontSize: 11, color: c.textMuted)),
            ],
          ],
        ),
      ),
    );
  }
}
