import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/projects_cubit.dart';
import '../../core/bloc/stream_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/inline_markdown.dart';
import '../../core/widgets/primitives.dart';
import '../../data/flow_aggregates.dart';
import '../../data/flow_repository.dart';
import '../../data/models.dart';
import 'diagnosis_panel.dart';

class TaskDetailPage extends StatelessWidget {
  const TaskDetailPage({
    super.key,
    required this.projectName,
    required this.runId,
    required this.taskId,
    this.fromRuns = false,
    this.showOthers = false,
  });

  final String projectName;
  final String runId;
  final String taskId;

  /// Opened from a row of the Execuções: "Voltar" returns there instead of the cycle.
  final bool fromRuns;

  /// `?others=1`: the diagnosis opens with the hypotheses below the top one showing.
  final bool showOthers;

  @override
  Widget build(BuildContext context) {
    final repository = RepositoryScope.of(context);
    return BlocProvider(
      // The shell reuses this page across runs (same route pattern); a new run needs a new cubit.
      key: ValueKey('$projectName/$runId'),
      create: (_) => StreamCubit<Run?>(repository.watchRun(projectName, runId)),
      child: BlocBuilder<StreamCubit<Run?>, AsyncSnapshot<Run?>>(
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const SizedBox.shrink();
          final run = snapshot.data;
          final task = run?.tasks.where((t) => t.id == taskId).firstOrNull;
          if (run == null || task == null) return const Center(child: Muted('Task não encontrada.'));
          return _TaskView(
            // The page is also reused across tasks of one run: open sections must not leak into the next task.
            key: ValueKey('$runId/$taskId'),
            projectName: projectName,
            run: run,
            task: task,
            fromRuns: fromRuns,
            showOthers: showOthers,
          );
        },
      ),
    );
  }
}

class _TaskView extends StatelessWidget {
  const _TaskView({
    super.key,
    required this.projectName,
    required this.run,
    required this.task,
    required this.fromRuns,
    required this.showOthers,
  });

  final String projectName;
  final Run run;
  final TaskRun task;
  final bool fromRuns;
  final bool showOthers;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final project = context.select<ProjectsCubit, Project?>(
      (cubit) => cubit.state.data?.where((p) => p.name == projectName).firstOrNull,
    );
    final cycle = project?.cycle;
    final table = cycle == null ? const <TaskRow>[] : taskTable(cycle);
    final index = table.indexWhere((row) => row.id == task.id);
    final description = task.description ?? cycle?.plan.where((t) => t.id == task.id).firstOrNull?.description;
    final lines = taskAttemptLines(task, root: project?.path);
    final tokens = task.tokensOut;
    final runs = '/p/$projectName/runs';

    // Not a ListView: it would drop the state of a section scrolled off screen, the diagnosis mid-creation included.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('task-back'),
                  onPressed: () => context.go(fromRuns ? runs : '/p/$projectName/flow'),
                  style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: Text(fromRuns ? 'Execuções' : 'Ciclo', style: const TextStyle(fontSize: 12.5)),
                ),
              ),
              const SizedBox(height: 12),
              Mono(task.id, color: c.textMuted, size: 13),
              const SizedBox(height: 4),
              Text(
                task.title,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                taskHeadline(task, position: index < 0 ? null : index + 1, total: index < 0 ? null : table.length),
                key: const ValueKey('task-headline'),
                style: TextStyle(fontSize: 13, color: c.textSecondary),
              ),
              const SizedBox(height: 20),
              if (task.status == Verdict.running) ...[
                _LiveSection(key: const ValueKey('task-live'), projectName: projectName, task: task),
                const SizedBox(height: 20),
              ],
              if (task.status == Verdict.blocked) ...[
                DiagnosisPanel(
                  key: const ValueKey('task-diagnosis'),
                  task: task,
                  run: run,
                  project: project,
                  initialShowOthers: showOthers,
                ),
                const SizedBox(height: 20),
              ],
              Column(
                key: const ValueKey('task-attempts'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('O que aconteceu', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  if (lines.isEmpty) const Muted('Ainda não houve tentativa.', size: 13),
                  for (final line in lines) _AttemptLine(key: ValueKey('task-attempt-${line.ordinal}'), line: line),
                ],
              ),
              const SizedBox(height: 12),
              if (description != null && description.trim().isNotEmpty)
                _Collapsed(
                  key: const ValueKey('task-description'),
                  toggleKey: const ValueKey('task-description-toggle'),
                  label: 'Descrição da task',
                  child: SelectionArea(
                    child: InlineMarkdown(
                      description,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: c.textSecondary),
                    ),
                  ),
                ),
              if (task.files.isNotEmpty)
                _Collapsed(
                  key: const ValueKey('task-files'),
                  toggleKey: const ValueKey('task-files-toggle'),
                  label: 'Arquivos tocados (${task.files.length})',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final f in task.files)
                        Padding(padding: const EdgeInsets.only(bottom: 4), child: Mono(f, size: 11.5)),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                key: const ValueKey('task-footer'),
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (tokens != null) Muted('${formatTokens(tokens)} tokens out'),
                  TextButton(
                    key: const ValueKey('task-open-run'),
                    onPressed: () => context.go(runs),
                    child: Text('ver nas Execuções', style: TextStyle(fontSize: 12, color: c.textSecondary)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttemptLine extends StatefulWidget {
  const _AttemptLine({super.key, required this.line});

  final TaskAttemptLine line;

  @override
  State<_AttemptLine> createState() => _AttemptLineState();
}

class _AttemptLineState extends State<_AttemptLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final line = widget.line;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            line.title,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(line.subtitle, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
          if (line.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              line.message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, height: 1.45, color: c.textPrimary),
            ),
          ],
          if (line.location.isNotEmpty) ...[const SizedBox(height: 6), Mono(line.location, size: 11)],
          if (line.rule.isNotEmpty) ...[const SizedBox(height: 2), Mono(line.rule, size: 11, color: c.accent)],
          if (line.others.isNotEmpty)
            DisclosureToggle(
              key: ValueKey('task-attempt-${line.ordinal}-more'),
              open: _open,
              onTap: () => setState(() => _open = !_open),
              children: [
                Flexible(
                  child: Text('e mais ${line.others.length}', style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                ),
              ],
            ),
          if (_open)
            for (final other in line.others)
              Padding(
                padding: const EdgeInsets.only(left: 22, bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(other.message, style: TextStyle(fontSize: 13, height: 1.45, color: c.textPrimary)),
                    if (other.location.isNotEmpty) ...[const SizedBox(height: 4), Mono(other.location, size: 11)],
                    if (other.rule.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Mono(other.rule, size: 11, color: c.accent),
                    ],
                  ],
                ),
              ),
          if (line.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(line.note, style: TextStyle(fontSize: 12.5, height: 1.45, color: c.textSecondary)),
          ],
        ],
      ),
    );
  }
}

/// A section that starts closed; the content is only built while open.
class _Collapsed extends StatefulWidget {
  const _Collapsed({super.key, required this.toggleKey, required this.label, required this.child});

  final Key toggleKey;
  final String label;
  final Widget child;

  @override
  State<_Collapsed> createState() => _CollapsedState();
}

class _CollapsedState extends State<_Collapsed> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DisclosureToggle(
            key: widget.toggleKey,
            open: _open,
            onTap: () => setState(() => _open = !_open),
            children: [
              Flexible(
                child: Text(
                  widget.label,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
              ),
            ],
          ),
          if (_open) Padding(padding: const EdgeInsets.only(left: 22, bottom: 12), child: widget.child),
        ],
      ),
    );
  }
}

const _refreshEvery = Duration(seconds: 3);

String formatElapsed(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}min ${(s % 60).toString().padLeft(2, '0')}s';
  return '${s ~/ 3600}h ${((s % 3600) ~/ 60).toString().padLeft(2, '0')}min';
}

class _LiveSection extends StatefulWidget {
  const _LiveSection({super.key, required this.projectName, required this.task});

  final String projectName;
  final TaskRun task;

  @override
  State<_LiveSection> createState() => _LiveSectionState();
}

class _LiveSectionState extends State<_LiveSection> {
  Timer? _timer;
  late FlowRepository _repository;
  bool _started = false;
  List<FileStat>? _files;
  bool _fetching = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _ticks++;
      if (_ticks % _refreshEvery.inSeconds == 0) _fetch();
      setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _repository = RepositoryScope.of(context);
    if (!_started) {
      _started = true;
      _fetch();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final checkpoint = widget.task.checkpoint;
    if (checkpoint == null || _fetching) return;
    _fetching = true;
    final files = await _repository.numstat(widget.projectName, checkpoint);
    _fetching = false;
    if (mounted) setState(() => _files = files);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stage = widget.task.stage;
    final files = _files;
    return Panel(
      title: 'Em andamento',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stage == null)
            const Muted('aguardando eventos da tentativa', size: 12)
          else
            Row(
              children: [
                Text(stage.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
                Muted('há ${formatElapsed(DateTime.now().difference(stage.since))}', size: 12),
              ],
            ),
          const SizedBox(height: 14),
          Text('Arquivos tocados até agora', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (widget.task.checkpoint == null)
            const Muted('checkpoint indisponível para esta tentativa', size: 12)
          else if (files == null)
            const Muted('lendo…', size: 12)
          else if (files.isEmpty)
            const Muted('nenhuma mudança ainda', size: 12)
          else
            for (final f in files)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Mono(f.path, size: 11.5, color: c.textPrimary)),
                    const SizedBox(width: 12),
                    Mono(f.added == null ? '+?' : '+${f.added}', size: 11.5, color: c.pass),
                    const SizedBox(width: 8),
                    Mono(f.deleted == null ? '−?' : '−${f.deleted}', size: 11.5, color: c.fail),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
