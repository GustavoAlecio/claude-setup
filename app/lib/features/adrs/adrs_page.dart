import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' as md;

import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/markdown_view.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/refresh_loop.dart';
import '../../core/widgets/wiki_link_syntax.dart';
import '../../data/docs_repository.dart';
import '../../data/inventory_models.dart';
import '../../data/inventory_parser.dart';
import '../../data/inventory_repository.dart';
import '../../data/models.dart';

enum AdrFilter {
  all('todos', AdrStatusGroup.all),
  accepted('aceitos', AdrStatusGroup.accepted),
  proposed('propostos', AdrStatusGroup.proposed),
  superseded('substituídos', AdrStatusGroup.superseded);

  const AdrFilter(this.label, this.group);
  final String label;
  final AdrStatusGroup group;

  bool matches(String status) => adrStatusMatches(group, status);
}

class AdrsPage extends StatefulWidget {
  /// Built with `ValueKey(projectName)`: a project switch disposes this state, so a late answer for the
  /// previous project lands on an unmounted state and is dropped.
  const AdrsPage({super.key, required this.projectName, this.adr});

  final String projectName;

  /// `?adr=` da rota; ausente ou inexistente → [defaultAdrId], trocando a URL.
  final String? adr;

  @override
  State<AdrsPage> createState() => _AdrsPageState();
}

class _AdrsPageState extends State<AdrsPage> with RefreshLoop<AdrsPage> {
  List<AdrEntry>? _adrs;
  GitSubmodule? _submodule;
  ({AdrEntry entry, String body})? _open;
  List<md.InlineSyntax> _syntaxes = const [];
  AdrFilter _filter = AdrFilter.all;
  String _query = '';
  bool _started = false;

  @override
  String get logName => 'AdrsPage';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    refresh();
  }

  @override
  void didUpdateWidget(AdrsPage old) {
    super.didUpdateWidget(old);
    if (old.adr != widget.adr) refresh();
  }

  String _location(String id) =>
      Uri(pathSegments: ['', 'p', widget.projectName, 'adrs'], queryParameters: {'adr': id}).toString();

  @override
  Future<void> sync() async {
    final repository = InventoryScope.of(context);
    final project = context.projectNamed(widget.projectName);
    final inventory = await repository.loadProject(project);
    if (!mounted) return;
    final adrs = inventory.adrs;
    setState(() {
      _adrs = adrs;
      _submodule = inventory.adrSubmodule;
      // A new list instance makes MarkdownView re-parse, so wikilinks resolve against the fresh listing.
      _syntaxes = [WikiLinkSyntax((target) => resolveAdrTarget(target, adrs))];
    });
    final id = widget.adr;
    if (id == null || !adrs.any((a) => a.id == id)) {
      final fallback = defaultAdrId(adrs);
      if (fallback != null) context.go(_location(fallback));
      return;
    }
    final loaded = await repository.loadAdr(project, id);
    if (!mounted) return;
    setState(() => _open = loaded);
  }

  void _select(String id) => context.go(_location(id));

  void _onLink(Uri uri) {
    if (uri.scheme == 'adr') {
      final id = uri.path;
      if (_adrs?.any((a) => a.id == id) ?? false) {
        _select(id);
      } else {
        log('unknown adr link: $uri', name: logName);
      }
      return;
    }
    if (opensExternally(uri)) {
      unawaited(DocsScope.openerOf(context)(uri));
      return;
    }
    log('link ignored: $uri', name: logName);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(
      listenWhen: (_, s) => s.hasData,
      listener: (_, _) => refresh(),
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final adrs = _adrs;
    if (adrs == null) {
      return refreshFailed
          ? const Center(child: Muted('não foi possível ler os ADRs', size: 13))
          : const SizedBox.shrink();
    }
    if (adrs.isEmpty) return const Center(child: Muted('este projeto não tem ADRs', size: 13));
    final query = _query;
    final visible = [
      for (final a in adrs)
        if (_filter.matches(a.status) &&
            (query.isEmpty ||
                a.title.toLowerCase().contains(query) ||
                a.tags.any((t) => t.toLowerCase().contains(query))))
          a,
    ];
    final open = _open;
    final selected = open != null && open.entry.id == widget.adr ? open : null;
    final submodule = _submodule;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AdrList(
          adrs: visible,
          selected: widget.adr,
          filter: _filter,
          refreshFailed: refreshFailed,
          onFilter: (f) => setState(() => _filter = f),
          onQuery: (q) => setState(() => _query = q.trim().toLowerCase()),
          onSelect: _select,
          onRefresh: refresh,
        ),
        Expanded(
          child: selected == null
              ? const SizedBox.shrink()
              : _AdrDetail(
                  key: ValueKey('adr-detail-${selected.entry.id}'),
                  entry: selected.entry,
                  body: selected.body,
                  adrs: adrs,
                  syntaxes: _syntaxes,
                  onSelect: _select,
                  onLink: _onLink,
                ),
        ),
      ],
    );
    if (submodule == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SubmoduleBanner(submodule),
        Expanded(child: row),
      ],
    );
  }
}

class _SubmoduleBanner extends StatelessWidget {
  const _SubmoduleBanner(this.submodule);

  final GitSubmodule submodule;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: const ValueKey('adrs-submodule-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: c.elevated,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Muted(adrSubmoduleLabel(submodule), size: 12),
    );
  }
}

class _AdrList extends StatelessWidget {
  const _AdrList({
    required this.adrs,
    required this.selected,
    required this.filter,
    required this.refreshFailed,
    required this.onFilter,
    required this.onQuery,
    required this.onSelect,
    required this.onRefresh,
  });

  final List<AdrEntry> adrs;
  final String? selected;
  final AdrFilter filter;
  final bool refreshFailed;
  final void Function(AdrFilter) onFilter;
  final void Function(String) onQuery;
  final void Function(String id) onSelect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 300,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('adrs-search'),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 16),
                      hintText: 'buscar em título e tags',
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: onQuery,
                  ),
                ),
                IconButton(
                  tooltip: 'Recarregar',
                  onPressed: onRefresh,
                  icon: Icon(Icons.refresh, size: 16, color: c.textSecondary),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in AdrFilter.values)
                  ChoiceChip(
                    key: ValueKey('adrs-filter-${f.name}'),
                    label: Text(f.label, style: const TextStyle(fontSize: 11)),
                    selected: f == filter,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => onFilter(f),
                  ),
              ],
            ),
          ),
          if (refreshFailed)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Muted('não foi possível atualizar; mostrando a leitura anterior', size: 11),
            ),
          Expanded(
            child: adrs.isEmpty
                ? const Padding(padding: EdgeInsets.all(16), child: Muted('nenhum ADR com esse filtro'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                    itemCount: adrs.length,
                    itemBuilder: (context, i) {
                      final a = adrs[i];
                      return _AdrTile(
                        key: ValueKey('adr-item-${a.path}'),
                        entry: a,
                        selected: a.id == selected,
                        onSelect: onSelect,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _AdrTile extends StatelessWidget {
  const _AdrTile({super.key, required this.entry, required this.selected, required this.onSelect});

  final AdrEntry entry;
  final bool selected;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final error = entry.error;
    return Material(
      color: selected ? c.hover : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        hoverColor: c.hover,
        onTap: adrSelectable(entry) ? () => onSelect(entry.id) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Mono(entry.id, color: c.textPrimary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.title.isEmpty ? '(sem título)' : entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected ? c.textPrimary : c.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Pill(label: entry.status, color: adrStatusColor(c, entry.status), dot: false),
                ],
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.fail),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdrDetail extends StatelessWidget {
  const _AdrDetail({
    super.key,
    required this.entry,
    required this.body,
    required this.adrs,
    required this.syntaxes,
    required this.onSelect,
    required this.onLink,
  });

  final AdrEntry entry;
  final String body;
  final List<AdrEntry> adrs;
  final List<md.InlineSyntax> syntaxes;
  final void Function(String id) onSelect;
  final void Function(Uri) onLink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final known = {for (final a in adrs) a.id};
    final chain = adrChain(entry.id, adrs);
    final error = entry.error;
    final warning = entry.warning;
    return SingleChildScrollView(
      key: PageStorageKey('adr-${entry.id}'),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Mono(entry.id, color: c.textMuted, size: 14),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.title.isEmpty ? '(sem título)' : entry.title,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
              ),
              const SizedBox(width: 10),
              Pill(label: entry.status, color: adrStatusColor(c, entry.status), dot: false),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (entry.date != null) Muted(entry.date!),
              for (final t in entry.tags) Pill(label: t, color: c.accent, dot: false),
            ],
          ),
          if (entry.affects.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [const Muted('affects'), for (final a in entry.affects) Mono(a)],
            ),
          ],
          if (entry.supersedes.isNotEmpty || entry.supersededBy.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (entry.supersedes.isNotEmpty) ...[
                  const Muted('substitui'),
                  for (final id in entry.supersedes)
                    _AdrLink(keyPrefix: 'adr-supersedes', id: id, enabled: known.contains(id), onSelect: onSelect),
                ],
                if (entry.supersededBy.isNotEmpty) ...[
                  const Muted('substituído por'),
                  for (final id in entry.supersededBy)
                    _AdrLink(keyPrefix: 'adr-superseded-by', id: id, enabled: known.contains(id), onSelect: onSelect),
                ],
              ],
            ),
          ],
          if (warning != null) ...[const SizedBox(height: 8), Muted(warning, size: 11)],
          if (chain.length > 1) ...[
            const SizedBox(height: 14),
            _Chain(chain: chain, selected: entry.id, onSelect: onSelect),
          ],
          const SizedBox(height: 18),
          if (error != null) ...[
            Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
            const SizedBox(height: 12),
            if (body.isNotEmpty) SelectableText(body, style: TextStyle(fontSize: 12, color: c.textSecondary)),
          ] else
            MarkdownView(body, onLink: onLink, inlineSyntaxes: syntaxes),
        ],
      ),
    );
  }
}

class _AdrLink extends StatelessWidget {
  const _AdrLink({required this.keyPrefix, required this.id, required this.enabled, required this.onSelect});

  final String keyPrefix;
  final String id;
  final bool enabled;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) => ActionChip(
    key: ValueKey('$keyPrefix-$id'),
    label: Mono(id, color: enabled ? context.colors.accent : context.colors.textMuted),
    visualDensity: VisualDensity.compact,
    onPressed: enabled ? () => onSelect(id) : null,
  );
}

class _Chain extends StatelessWidget {
  const _Chain({required this.chain, required this.selected, required this.onSelect});

  final List<AdrChainItem> chain;
  final String selected;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: const ValueKey('adr-chain'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Muted('cadeia'),
          for (final (i, item) in chain.indexed) ...[
            if (i > 0) Icon(Icons.arrow_forward, size: 12, color: c.textMuted),
            _ChainItem(item: item, selected: item.id == selected, onSelect: onSelect),
          ],
        ],
      ),
    );
  }
}

class _ChainItem extends StatelessWidget {
  const _ChainItem({required this.item, required this.selected, required this.onSelect});

  final AdrChainItem item;
  final bool selected;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final exists = item.entry != null;
    final color = selected ? c.textPrimary : (exists ? c.accent : c.textMuted);
    final label = Container(
      key: ValueKey('adr-chain-${item.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? c.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: selected ? c.borderStrong : Colors.transparent),
      ),
      child: Text(
        item.id,
        style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w400, color: color),
      ),
    );
    if (selected || !exists) return label;
    return InkWell(borderRadius: BorderRadius.circular(6), onTap: () => onSelect(item.id), child: label);
  }
}
