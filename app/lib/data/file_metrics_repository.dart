import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'metrics_models.dart';
import 'metrics_parser.dart';
import 'metrics_repository.dart';
import 'models.dart' show Project;
import 'orgs.dart';
import 'read_capped.dart';
import 'report_models.dart';
import 'report_parser.dart';

const _currentDir = 'ciclo-atual';

class FileMetricsRepository implements MetricsRepository {
  FileMetricsRepository(String claudeHome, String workflowRoot)
    : claudeHome = normalizePath(claudeHome),
      workflowRoot = normalizePath(workflowRoot);

  final String claudeHome;
  final String workflowRoot;

  @override
  Future<ProjectMetrics> loadProject(Project project) async {
    final cycles = <CycleMetrics>[];
    for (final dir in await _dirs('$claudeHome/projects/${project.name}/history')) {
      cycles.add(await _historyCycle(dir));
    }
    final current = await _currentCycle('$workflowRoot/${project.name}');
    if (current != null) cycles.add(current);
    return projectSummary(cycles);
  }

  Future<CycleMetrics> _historyCycle(String dir) async {
    final warnings = <String>[];
    final meta = await _json('$dir/metrics.json', warnings);
    final runs = await _runs(dir, warnings);
    final report = await _report('$dir/report.json', warnings);
    return aggregateCycle(
      _basename(dir),
      meta,
      runs.traces,
      runsWithoutTrace: runs.withoutTrace,
      extraWarnings: warnings,
      report: report,
    );
  }

  /// Only shows up once some run has a `trace.jsonl`, or a trace that could not be read (shown with its warning).
  Future<CycleMetrics?> _currentCycle(String dir) async {
    final warnings = <String>[];
    final runs = await _runs(dir, warnings);
    if (runs.traces.isEmpty && warnings.isEmpty) return null;
    final current = await _json('$dir/current.json', warnings);
    final tasks = current?['tasks'];
    return aggregateCycle(
      _currentDir,
      {
        'feature': current?['feature'],
        if (tasks is Map) 'tasks_total': tasks['total'],
        if (tasks is Map) 'tasks_completed': tasks['completed'],
      },
      runs.traces,
      current: true,
      runsWithoutTrace: runs.withoutTrace,
      extraWarnings: warnings,
    );
  }

  Future<({Map<String, List<String>> traces, int withoutTrace})> _runs(String cycleDir, List<String> warnings) async {
    final traces = <String, List<String>>{};
    var withoutTrace = 0;
    for (final run in await _dirs('$cycleDir/runs')) {
      final name = _basename(run);
      final read = await readCapped('$run/trace.jsonl', kMetricsFileLimit);
      final text = read.text;
      if (text != null) {
        traces[name] = const LineSplitter().convert(text);
      } else if (read.problem != null) {
        warnings.add('trace ${read.problem}: $name');
      } else {
        withoutTrace++;
      }
    }
    return (traces: traces, withoutTrace: withoutTrace);
  }

  Future<Map<String, Object?>?> _json(String path, List<String> warnings) async {
    final read = await readCapped(path, kMetricsFileLimit);
    final text = read.text;
    if (text == null) {
      if (read.problem != null) warnings.add('${_basename(path)} ${read.problem}');
      return null;
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException catch (e, st) {
      log('invalid json $path', name: 'FileMetricsRepository', error: e, stackTrace: st);
    }
    warnings.add('${_basename(path)} inválido');
    return null;
  }

  Future<ReportDoc?> _report(String path, List<String> warnings) async {
    final read = await readCapped(path, kReportFileLimit);
    final text = read.text;
    if (text == null) {
      if (read.problem != null) warnings.add('${_basename(path)} ${read.problem}');
      return null;
    }
    return parseReport(text);
  }

  /// Sorted subdirectories; empty when [dir] is missing or unreadable.
  Future<List<String>> _dirs(String dir) async {
    try {
      final out = <String>[];
      await for (final e in Directory(dir).list()) {
        if (await FileSystemEntity.isDirectory(e.path)) out.add(e.path);
      }
      return out..sort();
    } on FileSystemException {
      return const [];
    }
  }

  static String _basename(String path) => path.split('/').last;
}
