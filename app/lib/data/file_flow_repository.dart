import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import '../engine/engine_config.dart';
import 'config_mutations.dart';
import 'dashboard_config_repository.dart';
import 'flow_repository.dart';
import 'models.dart';
import 'orgs.dart';
import 'project_scan.dart' as scan;
import 'workflow_parser.dart';

typedef ScanRoots = Future<Map<String, List<ScanCandidate>>> Function(Iterable<String> roots);

/// [source] is the file content, `null` when `.dashboard.json` does not exist.
typedef _ConfigRead = ({DashboardConfig config, String? source});

class FileFlowRepository implements FlowRepository {
  FileFlowRepository(this._requestedRoot, {String? stacksDir, String? checkpointScript, ScanRoots? scanRoots})
    : _stacksDir = stacksDir ?? '$_claudeHome/stacks',
      _checkpointScript = checkpointScript ?? '$_claudeHome/bin/wf-checkpoint.sh',
      _scanRoots = scanRoots ?? scan.scanRoots,
      _configRepository = FileDashboardConfigRepository('$_requestedRoot/.dashboard.json');

  static String get defaultRoot => '$_claudeHome/workflow';

  static String get _home => Platform.environment['HOME'] ?? '';

  static String get _claudeHome => '$_home/.claude';

  static const _debounce = Duration(milliseconds: 300);

  final String _requestedRoot;
  final String _stacksDir;
  final String _checkpointScript;
  final ScanRoots _scanRoots;
  final FileDashboardConfigRepository _configRepository;
  final _updates = StreamController<List<Project>>.broadcast();
  final _configUpdates = StreamController<DashboardConfig>.broadcast();

  String? _root;
  bool _started = false;
  int _generation = 0;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _timer;
  bool _pendingRoot = false;
  bool _pendingConfig = false;
  final _pendingProjects = <String>{};

  List<Project>? _snapshot;

  /// Raw projects as read from the workflow dirs: `path` is `current.json.project_path`.
  final _projects = <String, Project>{};
  DashboardConfig? _config;

  /// Content [_config] was parsed from; a watcher echo of an already applied write is a no-op.
  String? _configSource;
  Map<String, List<ScanCandidate>> _scanIndex = const {};

  /// Root reloads and config changes replace [_config]/[_scanIndex] across awaits; one chain keeps an
  /// older, slower pass from overwriting a newer one.
  Future<void> _configChain = Future<void>.value();

  /// Cleared on every root reload so a symlink re-pointed on disk is picked up.
  final _canonical = <String, String>{};
  final _mtimes = <String, DateTime?>{};
  final _lastValidRuns = <String, Map<String, Run>>{};
  final _chains = <String, Future<void>>{};

  @override
  Stream<List<Project>> watchProjects() {
    _ensureStarted();
    return _replay(() => _snapshot, _updates.stream);
  }

  @override
  Stream<DashboardConfig> watchConfig() {
    _ensureStarted();
    return _replay(() => _config, _configUpdates.stream);
  }

  @override
  Future<void> updateConfig(ConfigMutation mutation) async {
    await _configRepository.update(mutation);
    if (!_started) return;
    // The write may have created the workflow root: start watching it.
    if (_watch == null) return reload();
    // Applied here rather than on the FSEvents echo, which may never arrive.
    await _serialized(_onConfigChanged);
  }

  @override
  Future<scan.ProjectDir> inspectDirectory(String dir) =>
      scan.inspectDirectory(dir, workflowExists: (name) => Directory('$_requestedRoot/$name').existsSync());

  @override
  Future<List<String>> suggestedRoots() => scan.listSubdirectories('$_home/development');

  void _ensureStarted() {
    if (_started) return;
    _started = true;
    unawaited(reload());
  }

  Stream<T> _replay<T>(T? Function() current, Stream<T> updates) => Stream.multi((controller) {
    final value = current();
    if (value != null) controller.add(value);
    final sub = updates.listen(controller.add, onError: controller.addError, onDone: controller.close);
    controller.onCancel = sub.cancel;
  });

  @override
  Stream<Project?> watchProject(String name) =>
      watchProjects().map((list) => list.where((p) => p.name == name).firstOrNull).distinct();

  @override
  Stream<Run?> watchRun(String project, String runId) =>
      watchProject(project).map((p) => p?.cycle?.runs.where((r) => r.id == runId).firstOrNull).distinct();

  /// Re-reads everything; restarts the watcher when the root did not exist before.
  @override
  Future<void> reload() async {
    if (_watch == null) _startWatch();
    await _serialized(_reloadRoot);
  }

  Future<void> _serialized(Future<void> Function() task) {
    final next = _configChain.then((_) => task());
    _configChain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<List<FileStat>> numstat(String project, String checkpoint) async {
    final path = _snapshot?.where((p) => p.name == project).firstOrNull?.path;
    if (path == null) return const [];
    try {
      final result = await Process.run('bash', [_checkpointScript, 'numstat', path, checkpoint]);
      if (result.exitCode != 0) {
        log('numstat failed for $path: ${result.stderr}', name: 'FileFlowRepository');
        return const [];
      }
      return parseNumstat(result.stdout as String);
    } on ProcessException catch (e, st) {
      log('cannot run $_checkpointScript', name: 'FileFlowRepository', error: e, stackTrace: st);
      return const [];
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _watch?.cancel();
    _watch = null;
    await _updates.close();
    await _configUpdates.close();
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
      _generation++;
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
    _generation++;
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
      case ConfigScope():
        _pendingConfig = true;
      case ProjectScope(:final project) || RunScope(:final project):
        _pendingProjects.add(project);
    }
    _timer?.cancel();
    _timer = Timer(_debounce, _flush);
  }

  void _flush() {
    if (_pendingRoot) {
      _pendingRoot = false;
      _pendingConfig = false;
      _pendingProjects.clear();
      unawaited(_serialized(_reloadRoot));
      return;
    }
    final config = _pendingConfig;
    _pendingConfig = false;
    final projects = _pendingProjects.toList();
    _pendingProjects.clear();
    unawaited(_flushChanges(config, projects));
  }

  Future<void> _flushChanges(bool config, List<String> projects) async {
    if (config) await _serialized(_onConfigChanged);
    for (final name in projects) {
      unawaited(_enqueue(name).then((_) => _emit()));
    }
  }

  /// `.dashboard.json` events never reload the root directly: [diffConfig] decides how much to redo.
  /// Runs only inside [_serialized].
  Future<void> _onConfigChanged() async {
    final root = _root;
    if (root == null) return;
    final read = await _readConfig(root);
    if (read == null || _root != root) return;
    if (_config != null && read.source == _configSource) return;
    final next = read.config;
    final before = _config ?? DashboardConfig.empty;
    switch (diffConfig(before, next)) {
      case ConfigChange.reemit:
        _configSource = read.source;
        _setConfig(next);
        _emitIfLoaded();
      case ConfigChange.rescan:
        final index = await _scanRoots(_rootsOf(next));
        if (_root != root) return;
        // Projects first: a listener reacting to the new org already finds them annotated with it.
        _config = next;
        _configSource = read.source;
        _scanIndex = index;
        _emitIfLoaded();
        _setConfig(next);
      case ConfigChange.reload:
        await _reloadRoot(read: read);
    }
  }

  /// `null` when the file is invalid or unreadable: the caller keeps the last valid config.
  Future<_ConfigRead?> _readConfig(String root) async {
    final file = File('$root/.dashboard.json');
    try {
      if (!await file.exists()) return (config: DashboardConfig.empty, source: null);
      final source = await file.readAsString();
      return (config: DashboardConfig.parse(source), source: source);
    } on FormatException catch (e, st) {
      log('invalid ${file.path}; keeping last valid config', name: 'FileFlowRepository', error: e, stackTrace: st);
      return null;
    } on FileSystemException catch (e, st) {
      log('cannot read ${file.path}', name: 'FileFlowRepository', error: e, stackTrace: st);
      return null;
    }
  }

  /// Before the first root load finishes the project list is partial; that load emits instead.
  void _emitIfLoaded() {
    if (_snapshot != null) _emit();
  }

  void _setConfig(DashboardConfig config) {
    _config = config;
    if (!_configUpdates.isClosed) _configUpdates.add(config);
  }

  static List<String> _rootsOf(DashboardConfig config) => [for (final o in config.orgs) ...o.roots];

  String _canonicalOf(String path) => _canonical.putIfAbsent(path, () {
    try {
      return normalizePath(Directory(path).resolveSymbolicLinksSync());
    } on FileSystemException {
      return normalizePath(path);
    }
  });

  List<Project> _annotate(List<Project> raw) =>
      annotateProjects(raw, _config ?? DashboardConfig.empty, canonical: _canonicalOf, scanIndex: _scanIndex);

  /// [read] is the already-read `.dashboard.json` when the reload comes from [_onConfigChanged].
  /// Runs only inside [_serialized].
  Future<void> _reloadRoot({_ConfigRead? read}) async {
    final root = _root;
    if (root == null) {
      _projects.clear();
      _mtimes.clear();
      if (_config == null) _setConfig(DashboardConfig.empty);
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
      log('cannot list $root; keeping current snapshot', name: 'FileFlowRepository', error: e, stackTrace: st);
      return;
    }
    if (_root != root) return;
    _canonical.clear();
    final next = read ?? await _readConfig(root);
    if (next != null) {
      _configSource = next.source;
      _setConfig(next.config);
    } else if (_config == null) {
      _setConfig(DashboardConfig.empty);
    }
    final index = await _scanRoots(_rootsOf(_config!));
    if (_root != root) return;
    _scanIndex = index;
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
    final generation = _generation;
    bool stale() => generation != _generation;
    try {
      final dir = Directory('$root/$name');
      if (!await dir.exists()) {
        if (stale()) return;
        _projects.remove(name);
        _mtimes.remove(name);
        _lastValidRuns.remove(name);
        return;
      }
      final currentFile = File('${dir.path}/current.json');
      if (!await currentFile.exists()) {
        if (stale()) return;
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
        if (stale()) return;
        _projects.putIfAbsent(name, () => Project(name: name));
        _mtimes[name] = mtime;
        return;
      }

      final fromCurrent = current['project_path'];
      final projectPath = fromCurrent is String && fromCurrent.isNotEmpty ? fromCurrent : null;
      // annotateProjects appends registered-only entries after the raw ones, so the first is this project.
      final path = _annotate([Project(name: name, path: projectPath)]).first.path;
      final titles = taskTitles(current);
      final metas = taskMetas(current);
      final runs = await _loadRuns(name, '${dir.path}/runs', titles, metas);
      final stack = path == null ? null : await _detectStack(path);
      final branch = path == null ? null : await _branch(path);
      final autoMode = await _autoMode(root);
      if (stale()) return;
      _projects[name] = Project(
        name: name,
        path: projectPath,
        stack: stack,
        cycle: parseCycle(current, projectName: name, branch: branch, autoMode: autoMode, runs: runs, plan: metas),
      );
      _mtimes[name] = mtime;
    } catch (e, st) {
      // External, partially legacy schema: a bad project must not take the watcher down.
      log('cannot load project $name', name: 'FileFlowRepository', error: e, stackTrace: st);
    }
  }

  Future<List<Run>> _loadRuns(String project, String runsPath, Map<String, String> titles, List<TaskMeta> metas) async {
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
      final run = await _loadRun('$runsPath/$id', id, titles, metas, cache[id]);
      if (run == null) continue;
      cache[id] = run;
      runs.add(run);
    }
    return runs;
  }

  Future<Run?> _loadRun(String dir, String id, Map<String, String> titles, List<TaskMeta> metas, Run? lastValid) async {
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
    return parseEventsRun(id, lines, tasks: metas);
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
    final list = List<Project>.unmodifiable(_annotate([for (final n in names) _projects[n]!]));
    _snapshot = list;
    _updates.add(list);
  }
}
