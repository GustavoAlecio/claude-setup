import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/engine_cubit.dart';
import '../../app/inbox_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/session_launcher.dart';
import '../../data/docs_repository.dart';
import '../../data/github_models.dart';
import '../../data/github_parser.dart';
import '../../data/models.dart';

const _logName = 'InboxPage';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> with SessionLauncher {
  @override
  String get logName => _logName;

  static String _keyOf(InboxItem item) => item.url ?? '${item.nameWithOwner}#${item.number}';

  void _review(InboxItem item, List<Project> projects, String cwd) =>
      unawaited(launchSession(_keyOf(item), reviewProjectName(item, projects), '/review ${item.number}', cwd: cwd));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<InboxCubit>().state;
    final hasEndpoint = context.select<EngineCubit, bool>((c) => c.state.data?.endpoint != null);
    final projects = context.select<ProjectsCubit, List<Project>>((c) => c.state.data ?? const []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context, state, hasEndpoint),
        Expanded(child: _body(context, state, hasEndpoint, projects)),
      ],
    );
  }

  Widget _toolbar(BuildContext context, InboxState state, bool hasEndpoint) {
    final c = context.colors;
    final cubit = context.read<InboxCubit>();
    final login = state.inbox?.login;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: login == null ? const SizedBox.shrink() : Muted('conta do gh: @$login', size: 12)),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                onPressed: hasEndpoint ? () => unawaited(cubit.refresh()) : null,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Recarregar', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (state.error case final error?)
            ErrorRetryRow(error, onRetry: hasEndpoint ? () => unawaited(cubit.refresh()) : null),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, InboxState state, bool hasEndpoint, List<Project> projects) {
    final inbox = state.inbox;
    if (inbox == null) {
      if (!hasEndpoint) return const Center(child: Muted('engine iniciando', size: 13));
      return const SizedBox.shrink();
    }
    if (inbox.items.isEmpty) return const Center(child: Muted('nenhum PR esperando sua revisão', size: 13));
    final now = DateTime.now();
    final footer = inboxFooter(inbox.items, projects);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        const TableHeaderRow([
          ('#PR', _wNumber),
          ('Título', null),
          ('Repo', _wRepo),
          ('Autor', _wAuthor),
          ('Atualizado', _wUpdated),
          ('', _wAction),
        ]),
        for (final item in inbox.items)
          _ItemRow(
            item: item,
            repoLabel: repoLabel(item.repo, item.nameWithOwner, [
              for (final o in inbox.items) (o.repo, o.nameWithOwner),
            ]),
            cwd: inboxCwd(item, projects),
            now: now,
            creating: isCreating(_keyOf(item)),
            createError: createError(_keyOf(item)),
            onReview: (cwd) => _review(item, projects, cwd),
            onLink: openLink,
          ),
        if (footer.missing.isNotEmpty || footer.ambiguous.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              key: const ValueKey('inbox-footer'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (footer.missing.isNotEmpty) Muted('sem checkout local: ${footer.missing.join(', ')}', size: 12),
                for (final (name, n) in footer.ambiguous)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Muted('checkout ambíguo: $name ($n cópias); defina cwds.$name', size: 12),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

const _wNumber = 64.0;
const _wRepo = 190.0;
const _wAuthor = 140.0;
const _wUpdated = 100.0;
const _wAction = 110.0;

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.repoLabel,
    required this.cwd,
    required this.now,
    required this.creating,
    required this.createError,
    required this.onReview,
    required this.onLink,
  });

  final InboxItem item;
  final String repoLabel;
  final String? cwd;
  final DateTime now;
  final bool creating;
  final String? createError;
  final void Function(String cwd) onReview;
  final void Function(Uri) onLink;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: _wNumber, child: _number(c)),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.title.isEmpty ? '—' : item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (item.isDraft) ...[const SizedBox(width: 8), Pill(label: 'rascunho', color: c.idle, dot: false)],
                  ],
                ),
              ),
              SizedBox(width: _wRepo, child: Mono(repoLabel)),
              SizedBox(width: _wAuthor, child: Mono(item.author.isEmpty ? '—' : '@${item.author}')),
              SizedBox(width: _wUpdated, child: Muted(relativeAge(item.updatedAt, now))),
              SizedBox(width: _wAction, child: _action()),
            ],
          ),
          if (createError case final error?)
            Padding(
              padding: const EdgeInsets.only(left: _wNumber, top: 6),
              child: Text(error, style: TextStyle(fontSize: 12, color: c.fail)),
            ),
        ],
      ),
    );
  }

  Widget _number(AppColors c) {
    final uri = item.url == null ? null : Uri.tryParse(item.url!);
    const style = TextStyle(fontFamily: monoFamily, fontSize: 12.5, fontWeight: FontWeight.w600);
    final label = '#${item.number}';
    if (uri == null || !opensExternally(uri)) return Text(label, style: style.copyWith(color: c.textSecondary));
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        key: ValueKey('inbox-link-${item.number}'),
        onTap: () => onLink(uri),
        child: Text(label, style: style.copyWith(color: c.accent)),
      ),
    );
  }

  Widget _action() {
    final cwd = this.cwd;
    final button = OutlinedButton(
      key: ValueKey('inbox-review-${item.number}'),
      onPressed: cwd == null || creating ? null : () => onReview(cwd),
      child: const Text('Revisar', style: TextStyle(fontSize: 12)),
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: cwd != null
          ? button
          : Tooltip(
              message: 'sem checkout local de ${item.repo.isEmpty ? item.nameWithOwner : item.repo}',
              child: button,
            ),
    );
  }
}
