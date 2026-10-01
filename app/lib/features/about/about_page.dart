import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../core/claude_home.dart';
import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/inventory_repository.dart';
import '../../data/inventory_models.dart';
import '../../data/orgs.dart';
import 'about_config.dart';
import 'about_flow.dart';
import 'about_inventory.dart';
import 'about_project.dart';

/// Loads the inventory once and keeps it across tabs; only "Recarregar" reads `~/.claude` again.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, required this.backTo, required this.paths});

  /// Location of "Voltar": the last project route visited, or the landing.
  final String Function() backTo;
  final EffectivePaths paths;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _tabs = ['Fluxo', 'Inventário', 'Projeto', 'Config'];

  Future<Inventory>? _inventory;
  int _generation = 0;
  int _tab = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inventory ??= InventoryScope.of(context).loadInventory();
  }

  void _reload() => setState(() {
    _generation++;
    _inventory = InventoryScope.of(context).loadInventory();
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final config = context.watch<ConfigCubit>().state.data;
    final projects = context.watch<ProjectsCubit>().state.data;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, kTitleBarInset, 20, 0),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                      onPressed: () => context.go(backTarget(widget.backTo(), config, projects)),
                      icon: const Icon(Icons.arrow_back, size: 16),
                      label: const Text('Voltar', style: TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                    Text('Sobre o app', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    TextButton.icon(
                      style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Recarregar', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (final (i, label) in _tabs.indexed)
                      _TabButton(label: label, selected: i == _tab, onTap: () => setState(() => _tab = i)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<Inventory>(
              future: _inventory,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Muted('não foi possível ler o inventário: ${snapshot.error}'));
                }
                // While "Recarregar" runs the previous inventory stays up, so tab state (search, project) survives.
                final inventory = snapshot.data;
                if (inventory == null) return const SizedBox.shrink();
                return IndexedStack(
                  index: _tab,
                  children: [
                    AboutFlow(inventory: inventory),
                    AboutInventory(inventory: inventory, paletteSkills: config?.paletteSkills),
                    AboutProject(routeProject: routeProject(widget.backTo()), generation: _generation),
                    AboutConfig(claudeHome: inventory.claudeHome, paths: widget.paths),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? c.accent : Colors.transparent, width: 2)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? c.textPrimary : c.textSecondary,
          ),
        ),
      ),
    );
  }
}
