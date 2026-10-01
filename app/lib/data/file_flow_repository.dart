import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'flow_repository.dart';
import 'models.dart';
import 'session_models.dart';
import 'workflow_parser.dart';

class FileFlowRepository implements FlowRepository {
  FileFlowRepository(this._requestedRoot, {String? stacksDir}) : _stacksDir = stacksDir ?? '$_claudeHome/stacks';

  static String get defaultRoot => '$_claudeHome/workflow';

  static String get _claudeHome => '${Platform.environment['HOME'] ?? ''}/.claude';

  static const _debounce = Duration(milliseconds: 300);

  final String _requestedRoot;
  final String _stacksDir;
  final _updates = StreamController<List<Project>>.broadcast();

  String? _root;
  bool _started = false;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _timer;
  bool _pendingRoot = false;
  final _pendingProjects = <String>{};

  List<Project>? _snapshot;
  final _projects = <String, Project>{};
  final _mtimes = <String, DateTime?>{};
  final _lastValidRuns = <String, Map<String, Run>>{};
  final _chains = <String, Future<void>>{};

  @override
  Stream<List<Project>> watchProjects() {
    if (!_started) {
      _started = true;
      unawaited(reload());
    }
    return Stream.multi((controller) {
      final current = _snapshot;
      if (current != null) controller.add(current);
      final sub = _updates.stream.listen(controller.add, onError: controller.addError, onDone: controller.close);
      controller.onCancel = sub.cancel;
    });
  }

  @override
  Stream<Project?> watchProject(String name) =>
      watchProjects().map((list) => list.where((p) => p.name == name).firstOrNull).distinct();

  @override
  Stream<Run?> watchRun(String project, String runId) =>
      watchProject(project).map((p) => p?.cycle?.runs.where((r) => r.id == runId).firstOrNull).distinct();

  @override
  List<SessionSummary> sessions() => const [];

  @override
  SessionSummary? session(String id) => null;

  /// Re-reads everything; restarts the watcher when the root did not exist before.
  @override
  Future<void> reload() async {
    if (_watch == null) _startWatch();
    await _reloadRoot();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _watch?.cancel();
    _watch = null;
    await _updates.close();
  }

  void _startWatch() {
    try {
      final dir = Directory(_requestedRoot);
      if (!dir.existsSync()) {
        _root = null;
        return;
      }
      // FSEvents reports canonical paths (/private/var/...); classify must compare against the same form.
      final root = dir.resolveSymbolicLinksSync();
      _root = root;
      _watch = Directory(root)
          .watch(recursive: true)
          .listen(
            _onEvent,
            onError: (Object e, StackTrace st) {
              log('watch error', name: 'FileFlowRepository', error: e, stackTrace: st);
              _stopWatch();
            },
            onDone: _stopWatch,
          );
    } on FileSystemException catch (e, st) {
      log('cannot watch $_requestedRoot', name: 'FileFlowRepository', error: e, stackTrace: st);
      _root = null;
    }
  }

  void _stopWatch() {
    unawaited(_watch?.cancel());
    _watch = null;
    _root = null;
    _projects.clear();
    _mtimes.clear();
    _emit();
  }

  void _onEvent(FileSystemEvent event) {
    final root = _root;
    if (root == null) return;
    final scope = classify(root, event.path, destination: event is FileSystemMoveEvent ? event.destination : null);
    switch (scope) {
      case null:
        return;
      case RootScope():
        _pendingRoot = true;
      case ProjectScope(:final project) || RunScope(:final project):
        _pendingProjects.add(project);
    }
    _timer?.cancel();
    _timer = Timer(_debounce, _flush);
  }

  void _flush() {
    if (_pendingRoot) {
      _pendingRoot = false;
      _pendingProjects.clear();
      unawaited(_reloadRoot());
      return;
    }
    final projects = _pendingProjects.toList();
    _pendingProjects.clear();
    for (final name in projects) {
      unawaited(_enqueue(name).then((_) => _emit()));
    }
  }

  Future<void> _reloadRoot() async {
    final root = _root;
    if (root == null) {
      _projects.clear();
      _mtimes.clear();
      _emit();
      return;
    }
    final names = <String>{};
    try {
      await for (final entity in Directory(root).list(followLinks: false)) {
        final name = entity.path.split('/').last;
        if (entity is Directory && !name.startsWith('.')) names.add(name);
      }
    } on FileSystemException catch (e, st) {
      log('cannot list $root', name: 'FileFlowRepository', error: e, stackTrace: st);
    }
    for (final gone in _projects.keys.where((k) => !names.contains(k)).toList()) {
      _projects.remove(gone);
      _mtimes.remove(gone);
      _lastValidRuns.remove(gone);
    }
    await Future.wait(names.map(_enqueue));
    _emit();
  }

  Future<void> _enqueue(String name) {
    final next = (_chains[name] ?? Future<void>.value()).then((_) => _loadProject(name));
    _chains[name] = next;
    return next;
  }

  Future<void> _loadProject(String name) async {
    final root = _root;
    if (root == null) return;
    try {
      final dir = Directory('$root/$name');
      if (!await dir.exists()) {
        _projects.remove(name);
        _mtimes.remove(name);
        _lastValidRuns.remove(name);
        return;
      }
      final currentFile = File('${dir.path}/current.json');
      if (!await currentFile.exists()) {
        _projects[name] = Project(name: name);
        _mtimes[name] = null;
        return;
      }
      final mtime = await currentFile.lastModified();
      final Map<String, dynamic> current;
      try {
        final decoded = jsonDecode(await currentFile.readAsString());
        if (decoded is! Map<String, dynamic>) throw const FormatException('current.json is not an object');
        current = decoded;
      } on FormatException catch (e, st) {
        log('invalid ${currentFile.path}', name: 'FileFlowRepository', error: e, stackTrace: st);
        _projects.putIfAbsent(name, () => Project(name: name));
        _mtimes[name] = mtime;
        return;
      }

      final path = _projectPath(root, name, current);
      final titles = taskTitles(current);
      final runs = await _loadRuns(name, '${dir.path}/runs', titles);
      _projects[name] = Project(
        name: name,
        path: path,
        stack: path == null ? null : await _detectStack(path),
        cycle: parseCycle(
          current,
          projectName: name,
          branch: path == null ? null : await _branch(path),
          autoMode: await _autoMode(root),
          runs: runs,
        ),
      );
      _mtimes[name] = mtime;
    } catch (e, st) {
      // External, partially legacy schema: a bad project must not take the watcher down.
      log('cannot load project $name', name: 'FileFlowRepository', error: e, stackTrace: st);
    }
  }

  String? _projectPath(String root, String name, Map<String, dynamic> current) {
    final fromCurrent = current['project_path'];
    if (fromCurrent is String && fromCurrent.isNotEmpty) return fromCurrent;
    final file = File('$root/.dashboard.json');
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      final cwd = decoded is Map ? (decoded['cwds'] is Map ? decoded['cwds'][name] : null) : null;
      return cwd is String && cwd.isNotEmpty ? cwd : null;
    } on FormatException catch (e, st) {
      log('invalid ${file.path}', name: 'FileFlowRepository', error: e, stackTrace: st);
      return null;
    }
  }

  Future<List<Run>> _loadRuns(String project, String runsPath, Map<String, String> titles) async {
    final runsDir = Directory(runsPath);
    if (!await runsDir.exists()) {
      _lastValidRuns.remove(project);
      return const [];
    }
    final ids = <String>[];
    await for (final entity in runsDir.list(followLinks: false)) {
      final id = entity.path.split('/').last;
      if (entity is Directory && runIdPattern.hasMatch(id)) ids.add(id);
    }
    ids.sort((a, b) => runStart(b)!.compareTo(runStart(a)!));

    final cache = _lastValidRuns.putIfAbsent(project, () => {});
    cache.removeWhere((id, _) => !ids.contains(id));
    final runs = <Run>[];
    for (final id in ids) {
      final run = await _loadRun('$runsPath/$id', id, titles, cache[id]);
      if (run == null) continue;
      cache[id] = run;
      runs.add(run);
    }
    return runs;
  }

  Future<Run?> _loadRun(String dir, String id, Map<String, String> titles, Run? lastValid) async {
    final result = File('$dir/result.json');
    if (await result.exists()) {
      try {
        final decoded = jsonDecode(await result.readAsString());
        if (decoded is! Map<String, dynamic>) throw const FormatException('result.json is not an object');
        return parseResultRun(id, decoded, titles);
      } catch (e, st) {
        log('invalid ${result.path}; keeping last valid state', name: 'FileFlowRepository', error: e, stackTrace: st);
        if (lastValid != null) return lastValid;
      }
    }
    final events = File('$dir/events.jsonl');
    if (!await events.exists()) return null;
    final lines = decodeJsonl(
      await events.readAsString(),
      onInvalid: (line, e) => log('invalid line in ${events.path}: $line', name: 'FileFlowRepository', error: e),
    );
    return parseEventsRun(id, lines, titles: titles);
  }

  Future<String?> _detectStack(String path) async {
    final dir = Directory(_stacksDir);
    if (!await dir.exists()) return null;
    final profiles = await dir.list().where((e) => e is File && e.path.endsWith('.json')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in profiles.cast<File>()) {
      try {
        final profile = jsonDecode(await f.readAsString());
        if (profile is! Map) continue;
        final detect = profile['detect'];
        if (detect is! List) continue;
        for (final marker in detect.whereType<String>()) {
          for (final base in [path, '$path/app']) {
            if (await FileSystemEntity.type('$base/$marker') != FileSystemEntityType.notFound) {
              final name = profile['name'];
              return name is String ? name : f.uri.pathSegments.last.replaceAll('.json', '');
            }
          }
        }
      } on FormatException catch (e, st) {
        log('invalid stack profile ${f.path}', name: 'FileFlowRepository', error: e, stackTrace: st);
      }
    }
    return null;
  }

  Future<String?> _branch(String path) async {
    if (!await Directory(path).exists()) return null;
    try {
      final result = await Process.run('git', ['-C', path, 'branch', '--show-current']);
      if (result.exitCode != 0) return null;
      final branch = (result.stdout as String).trim();
      return branch.isEmpty ? null : branch;
    } on ProcessException catch (e, st) {
      log('git unavailable for $path', name: 'FileFlowRepository', error: e, stackTrace: st);
      return null;
    }
  }

  Future<bool> _autoMode(String root) async {
    final flag = File('$root/auto_mode.flag');
    if (!await flag.exists()) return false;
    return (await flag.readAsString()).trim() == 'on';
  }

  void _emit() {
    if (_updates.isClosed) return;
    final names = _projects.keys.toList()
      ..sort((a, b) {
        final ma = _mtimes[a];
        final mb = _mtimes[b];
        if (ma == null || mb == null) {
          if (ma != mb) return ma == null ? 1 : -1;
          return a.compareTo(b);
        }
        final byTime = mb.compareTo(ma);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    final list = List<Project>.unmodifiable([for (final n in names) _projects[n]!]);
    _snapshot = list;
    _updates.add(list);
  }
}
