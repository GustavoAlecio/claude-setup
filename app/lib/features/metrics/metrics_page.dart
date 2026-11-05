import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/refresh_loop.dart';
import '../../data/inventory_models.dart';
import '../../data/inventory_repository.dart';
import '../../data/metrics_models.dart';
import '../../data/metrics_repository.dart';
import '../../data/models.dart';

class MetricsPage extends StatefulWidget {
  /// Built with `ValueKey(projectName)`: a project switch disposes this state, so a late answer for the
  /// previous project lands on an unmounted state and is dropped.
  const MetricsPage({super.key, required this.projectName});

  final String projectName;

  @override
  State<MetricsPage> createState() => _MetricsPageState();
}

class _MetricsPageState extends State<MetricsPage> with RefreshLoop<MetricsPage> {
  ProjectMetrics? _metrics;
  Routing? _routing;
  bool _started = false;
  final _expanded = <String>{};

  @override
  String get logName => 'MetricsPage';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    refresh();
  }

  @override
  Future<void> sync() async {
    final metricsRepository = MetricsScope.of(context);
    final inventoryRepository = InventoryScope.of(context);
    final project = context.projectNamed(widget.projectName);
    final metrics = await metricsRepository.loadProject(project);
    final inventory = await inventoryRepository.loadProject(project);
    if (!mounted) return;
    setState(() {
      _metrics = metrics;
      _routing = inventory.routing;
    });
  }

  void _toggle(String dir) => setState(() {
    if (!_expanded.remove(dir)) _expanded.add(dir);
  });

  @override
  Widget build(BuildContext context) {
    return BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(
      listenWhen: (_, s) => s.hasData,
      listener: (_, _) => refresh(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(context),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          const Spacer(),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.textSecondary),
            onPressed: refresh,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Recarregar', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final metrics = _metrics;
    if (metrics == null) {
      return refreshFailed
          ? const Center(child: Muted('não foi possível ler as métricas', size: 13))
          : const SizedBox.shrink();
    }
    final cycles = metrics.cycles;
    return CustomScrollView(
      slivers: [
        if (refreshFailed)
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            sliver: SliverToBoxAdapter(child: Muted('não foi possível atualizar; mostrando a leitura anterior')),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          sliver: SliverToBoxAdapter(child: _Cards(metrics: metrics)),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Ciclos', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                if (cycles.isEmpty)
                  const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Muted('nenhum ciclo registrado'))
                else
                  const TableHeaderRow(_cycleColumns),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: cycles.length,
            itemBuilder: (context, i) {
              final cycle = cycles[i];
              return _CycleRow(
                key: ValueKey('metrics-cycle-${cycle.dir}'),
                cycle: cycle,
                expanded: _expanded.contains(cycle.dir),
                onToggle: () => _toggle(cycle.dir),
              );
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          sliver: SliverToBoxAdapter(child: _Bands(routing: _routing ?? const Routing())),
        ),
      ],
    );
  }
}

const _cycleColumns = <(String, double?)>[
  ('', 20),
  ('Feature', null),
  ('Data', 90),
  ('Tasks', 56),
  ('Tentativas', 80),
  ('Escaladas', 76),
  ('Verify', 56),
  ('Rounds', 56),
  ('Tokens', 64),
  ('Status', 110),
];

class _Cards extends StatelessWidget {
  const _Cards({required this.metrics});

  final ProjectMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final percent = metrics.passTier0Percent;
    String tokens(String role) => metrics.hasTokens ? formatTokens(metrics.tokensByRole[role] ?? 0) : '—';
    final otherTokens = metrics.tokensByRole['outros'] ?? 0;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _StatCard(id: 'completed', label: 'Ciclos concluídos', value: '${metrics.completedCycles}'),
        _StatCard(id: 'tasks', label: 'Tasks', value: '${metrics.tasks}'),
        _StatCard(
          id: 'pass-tier0',
          label: 'Passaram no tier0',
          value: percent == null ? '—' : '${percent.round()}%',
          detail: '${metrics.passedTier0}/${metrics.tasks}',
        ),
        _StatCard(id: 'escalations', label: 'Escaladas', value: '${metrics.escalations}'),
        _StatCard(id: 'tokens-dev', label: 'Tokens dev', value: tokens('dev')),
        _StatCard(id: 'tokens-g0', label: 'Tokens g0', value: tokens('g0')),
        _StatCard(id: 'tokens-g1', label: 'Tokens g1', value: tokens('g1')),
        _StatCard(id: 'tokens-g2', label: 'Tokens g2', value: tokens('g2')),
        if (metrics.hasTokens && otherTokens > 0)
          _StatCard(id: 'tokens-outros', label: 'Tokens outros', value: formatTokens(otherTokens)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.id, required this.label, required this.value, this.detail});

  final String id;
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: ValueKey('metrics-card-$id'),
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Muted(label, size: 11),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: c.textPrimary),
          ),
          if (detail != null) Muted(detail!, size: 11),
        ],
      ),
    );
  }
}

class _CycleRow extends StatelessWidget {
  const _CycleRow({super.key, required this.cycle, required this.expanded, required this.onToggle});

  final CycleMetrics cycle;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final traced = cycle.hasTrace;
    String dash(Object v) => traced ? '$v' : '—';
    Widget cell(Widget child, double width) => SizedBox(width: width, child: child);
    Widget text(String s) => Text(s, style: TextStyle(fontSize: 12, color: c.textSecondary));
    final notes = [
      if (!traced) 'sem trace',
      if (cycle.ignoredLines > 0) '${cycle.ignoredLines} linha(s) ignorada(s)',
      if (cycle.runsWithoutTrace > 0) '${cycle.runsWithoutTrace} run(s) sem trace',
      ...cycle.warnings,
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  cell(Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: c.textMuted), 20),
                  Expanded(
                    child: Text(
                      cycle.feature,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: c.textPrimary),
                    ),
                  ),
                  cell(text(cycle.date ?? '—'), 90),
                  cell(text(cycle.tasksLabel ?? '—'), 56),
                  cell(text(dash(cycle.attempts)), 80),
                  cell(text(dash(cycle.escalations)), 76),
                  cell(text(dash(cycle.verifyRuns)), 56),
                  cell(text(dash(cycle.rounds)), 56),
                  cell(text(cycle.hasTokens ? formatTokens(cycle.tokensTotal) : '—'), 64),
                  cell(
                    Text(
                      cycle.status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: cycle.status == 'completed' ? c.pass : c.textSecondary),
                    ),
                    110,
                  ),
                ],
              ),
            ),
          ),
          if (notes.isNotEmpty)
            Padding(padding: const EdgeInsets.only(left: 20, bottom: 6), child: Muted(notes.join(' · '), size: 11)),
          if (expanded) _TaskRows(cycle: cycle),
        ],
      ),
    );
  }
}

class _TaskRows extends StatelessWidget {
  const _TaskRows({required this.cycle});

  final CycleMetrics cycle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (cycle.tasks.isEmpty) {
      return const Padding(padding: EdgeInsets.fromLTRB(20, 0, 0, 10), child: Muted('sem tasks no trace'));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 0, 10),
      child: Column(
        children: [
          for (final t in cycle.tasks)
            Padding(
              key: ValueKey('metrics-task-${cycle.dir}-${t.key}'),
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(width: 200, child: Mono(t.key, color: c.textPrimary, size: 12)),
                  _TierPill(t.tier0),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.arrow_forward, size: 12, color: c.textMuted),
                  ),
                  _TierPill(t.tierFinal),
                  const SizedBox(width: 16),
                  Muted('${t.attempts} tentativa(s)'),
                  const SizedBox(width: 16),
                  Muted('${formatTokens(t.tokens)} tokens'),
                  if (t.blocked) ...[const SizedBox(width: 16), Pill(label: 'bloqueada', color: c.fail, dot: false)],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TierPill extends StatelessWidget {
  const _TierPill(this.tier);

  final String? tier;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final known = Tier.values.where((t) => t.name == tier).firstOrNull;
    return Pill(label: tier ?? '—', color: known == null ? c.idle : c.tier(known), mono: true, dot: false);
  }
}

class _Bands extends StatelessWidget {
  const _Bands({required this.routing});

  final Routing routing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final error = routing.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Faixas', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
          )
        else if (routing.bands.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Muted('rode /complete para gerar as faixas'))
        else ...[
          const TableHeaderRow([
            ('Faixa', 80),
            ('Pass no tier0', 130),
            ('Escaladas', 80),
            ('Bloqueios', 80),
            ('Tentativas/task', 110),
            ('Tier final', null),
          ]),
          for (final b in routing.bands) _BandRow(band: b),
        ],
        if (routing.overrides.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            key: const ValueKey('metrics-overrides'),
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Muted('overrides ativos'),
              for (final o in routing.overrides.entries)
                Pill(label: '${o.key} → ${o.value}', color: c.accent, mono: true, dot: false),
            ],
          ),
        ],
      ],
    );
  }
}

class _BandRow extends StatelessWidget {
  const _BandRow({required this.band});

  final RoutingBand band;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget cell(String s, double width) => SizedBox(
      width: width,
      child: Text(s, style: TextStyle(fontSize: 12, color: c.textSecondary)),
    );
    final pct = band.n == 0 ? 0 : (band.passTier0 * 100 / band.n).round();
    final tiers = band.finalTiers.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    return Container(
      key: ValueKey('metrics-band-${band.complexity}:${band.risk}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          SizedBox(width: 80, child: Mono('${band.complexity}:${band.risk}', color: c.textPrimary)),
          cell('${band.passTier0}/${band.n} ($pct%)', 130),
          cell('${band.escalated}', 80),
          cell('${band.blocked}', 80),
          cell(band.attemptsPerTask.toStringAsFixed(2), 110),
          Expanded(
            child: Text(tiers.isEmpty ? '—' : tiers, style: TextStyle(fontSize: 12, color: c.textSecondary)),
          ),
        ],
      ),
    );
  }
}
