import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/refresh_loop.dart';
import '../../data/docs_parser.dart';
import '../../data/docs_repository.dart';
import '../../data/docs_models.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';

final _lastListings = <String, DocsListing>{};

/// Última listagem lida por projeto: a nav remonta a cada troca de aba e começaria vazia.
DocsListing? cachedReferenceListing(String project) => _lastListings[project];

void cacheReferenceListing(String project, DocsListing listing) => _lastListings[project] = listing;

void forgetReferenceListing(String project) => _lastListings.remove(project);

@visibleForTesting
void clearReferenceListingCache() => _lastListings.clear();

/// The single navigation of the Referência group, left of Documentos, ADRs and Números.
class ReferenceNav extends StatefulWidget {
  const ReferenceNav({super.key, required this.project, required this.selected, this.listing});

  final String project;

  /// The `rel` of the open document, `adrs` or `metrics`.
  final String selected;

  /// When given, the nav shows it and reads nothing; `null` makes the nav read the list itself.
  final DocsListing? listing;

  @override
  State<ReferenceNav> createState() => _ReferenceNavState();
}

class _ReferenceNavState extends State<ReferenceNav> with RefreshLoop<ReferenceNav> {
  late DocsListing? _listing = cachedReferenceListing(widget.project);
  bool _started = false;

  @override
  String get logName => 'ReferenceNav';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _refreshOwned();
  }

  void _refreshOwned() {
    if (widget.listing == null) refresh();
  }

  @override
  Future<void> sync() async {
    final DocsListing listing;
    try {
      listing = await DocsScope.of(context).list(widget.project);
    } catch (_) {
      forgetReferenceListing(widget.project);
      rethrow;
    }
    cacheReferenceListing(widget.project, listing);
    if (!mounted) return;
    setState(() => _listing = listing);
  }

  String _docLocation(String rel) => artifactsLocation(widget.project, rel);

  String _tabLocation(String tab) => Uri(pathSegments: ['', 'p', widget.project, tab]).toString();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final listing = widget.listing ?? (refreshFailed ? null : _listing) ?? DocsListing.empty;
    final docs = referenceDocs(listing);
    Widget item(String id, String title, String location) => _RefItem(
      key: ValueKey('ref-item-$id'),
      title: title,
      selected: id == widget.selected,
      onTap: () => context.go(location),
    );
    return BlocListener<ProjectsCubit, AsyncSnapshot<List<Project>>>(
      listenWhen: (_, s) => s.hasData,
      listener: (_, _) => _refreshOwned(),
      child: Container(
        width: 200,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: c.border)),
        ),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            if (docs.cycle.isNotEmpty) ...[
              const _Section('Deste ciclo'),
              for (final d in docs.cycle) item(d.rel, docTitle(d.rel), _docLocation(d.rel)),
            ],
            if (docs.details.isNotEmpty) ...[
              const _Section('Detalhamentos'),
              for (final d in docs.details) item(d.rel, docTitle(d.rel), _docLocation(d.rel)),
            ],
            const _Section('Do projeto'),
            item('adrs', 'Decisões de arquitetura', _tabLocation('adrs')),
            item('metrics', 'Números', _tabLocation('metrics')),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 6), child: Muted(label, size: 11));
}

class _RefItem extends StatelessWidget {
  const _RefItem({super.key, required this.title, required this.selected, required this.onTap});

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: selected ? c.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          hoverColor: c.hover,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Tooltip(
              message: title,
              waitDuration: const Duration(milliseconds: 500),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? c.textPrimary : c.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
