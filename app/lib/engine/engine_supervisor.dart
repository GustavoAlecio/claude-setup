import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'engine_config.dart';

enum EngineStatus { starting, ok, stopped }

class EngineState {
  const EngineState.starting()
    : status = EngineStatus.starting,
      endpoint = null,
      versionWarning = null,
      error = null,
      concurrentInstanceTook = false,
      stderrTail = const [];

  const EngineState.ok(Uri this.endpoint, {this.versionWarning})
    : status = EngineStatus.ok,
      error = null,
      concurrentInstanceTook = false,
      stderrTail = const [];

  const EngineState.stopped({this.error, this.concurrentInstanceTook = false, this.stderrTail = const []})
    : status = EngineStatus.stopped,
      endpoint = null,
      versionWarning = null;

  final EngineStatus status;
  final Uri? endpoint;

  /// Non-blocking: the engine answered but reports a version other than [kEngineVersion].
  final String? versionWarning;

  /// `null` when stopped on purpose (shutdown).
  final String? error;

  /// `true` when the engine terminated because another app instance took over.
  final bool concurrentInstanceTook;

  final List<String> stderrTail;
}

abstract interface class EngineController {
  Stream<EngineState> watch();
  Future<void> restart();
  Future<void> shutdown();
}

typedef CaptureEnv = Future<Map<String, String>> Function();
typedef StartProcess =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
    });
typedef FileExists = bool Function(String path);
typedef ReadConfig = Future<DashboardConfig> Function();
typedef IsEngineProcess = Future<bool> Function(int pid);

const _logName = 'EngineSupervisor';

/// Finder-launched apps get a minimal env; `-i` is required because nvm is loaded from `.zshrc`.
Future<Map<String, String>> captureLoginEnv({Duration timeout = const Duration(seconds: 5)}) async {
  Process? process;
  try {
    process = await Process.start('/bin/zsh', ['-ilc', r"printf '\0__ENV__\0'; env -0"]);
    unawaited(process.stdin.close().then((_) {}, onError: (_) {}));
    unawaited(process.stderr.drain<void>());
    final output = await Future.wait([
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join(),
      process.exitCode,
    ]).timeout(timeout);
    final env = parseEnv0(output[0] as String);
    if (env != null && env.isNotEmpty) return env;
    log('zsh env sem sentinela (exit ${output[1]}); usando o ambiente do app', name: _logName);
  } on TimeoutException {
    process?.kill(ProcessSignal.sigkill);
    log('zsh env excedeu ${timeout.inSeconds} s; usando o ambiente do app', name: _logName);
  } on ProcessException catch (e, st) {
    log('zsh indisponível; usando o ambiente do app', name: _logName, error: e, stackTrace: st);
  }
  return Map.of(Platform.environment);
}

Future<DashboardConfig> readDashboardConfig(String workflowRoot) async {
  final file = File('$workflowRoot/.dashboard.json');
  try {
    return DashboardConfig.parse(await file.readAsString());
  } on PathNotFoundException {
    return DashboardConfig.empty;
  } on FileSystemException catch (e, st) {
    log('cannot read ${file.path}', name: _logName, error: e, stackTrace: st);
    return DashboardConfig.empty;
  } on FormatException catch (e, st) {
    log('invalid ${file.path}', name: _logName, error: e, stackTrace: st);
    return DashboardConfig.empty;
  }
}

bool fileExistsOnDisk(String path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

Future<bool> isEngineProcessDefault(int pid) async {
  try {
    final result = await Process.run('ps', ['-o', 'command=', '-p', '$pid']);
    if (result.exitCode != 0) return false;
    final command = (result.stdout as String).trim();
    return command.contains('--sessions-dir');
  } on Exception {
    return false;
  }
}

class EngineSupervisor implements EngineController {
  EngineSupervisor({
    required String workflowRoot,
    String engineDirDefine = '',
    String? claudeHome,
    CaptureEnv captureEnv = captureLoginEnv,
    StartProcess startProcess = Process.start,
    FileExists fileExists = fileExistsOnDisk,
    IsEngineProcess? isEngineProcess,
    ReadConfig? readConfig,
    Duration readyTimeout = const Duration(seconds: 5),
    Duration killGrace = const Duration(seconds: 3),
  }) : _workflowRoot = workflowRoot,
       _claudeHome = claudeHome ?? Directory(workflowRoot).parent.path,
       _engineDirDefine = engineDirDefine,
       _captureEnv = captureEnv,
       _startProcess = startProcess,
       _fileExists = fileExists,
       _isEngineProcess = isEngineProcess ?? isEngineProcessDefault,
       _readConfig = readConfig ?? (() => readDashboardConfig(workflowRoot)),
       _readyTimeout = readyTimeout,
       _killGrace = killGrace;

  final String _workflowRoot;
  final String _claudeHome;
  final String _engineDirDefine;
  final CaptureEnv _captureEnv;
  final StartProcess _startProcess;
  final FileExists _fileExists;
  final IsEngineProcess _isEngineProcess;
  final ReadConfig _readConfig;
  final Duration _readyTimeout;
  final Duration _killGrace;

  final _updates = StreamController<EngineState>.broadcast();
  EngineState _state = const EngineState.starting();
  bool _started = false;
  int _generation = 0;
  _EngineRun? _run;

  String get logPath => '$_workflowRoot/.dashboard/engine.log';

  /// Starts the engine on the first subscription, like the file watcher.
  @override
  Stream<EngineState> watch() => Stream.multi((controller) {
    controller.add(_state);
    final sub = _updates.stream.listen(controller.add);
    controller.onCancel = sub.cancel;
    if (!_started) {
      _started = true;
      unawaited(_start());
    }
  });

  /// `null` while the engine is not serving.
  Stream<Uri?> get endpoint => watch().map((s) => s.endpoint).distinct();

  @override
  Future<void> restart() async {
    _started = true;
    await _stop();
    await _start();
  }

  @override
  Future<void> shutdown() async {
    _started = true;
    await _stop();
    _emit(const EngineState.stopped());
  }

  void _emit(EngineState state) {
    _state = state;
    _updates.add(state);
  }

  Future<void> _start() async {
    final generation = ++_generation;
    if (_state.status != EngineStatus.starting) _emit(const EngineState.starting());

    final env = await _captureEnv();
    final config = await _readConfig();
    if (generation != _generation) return;

    final EngineLaunch launch;
    switch (resolveEngineLaunch(engineDirDefine: _engineDirDefine, config: config, env: env, fileExists: _fileExists)) {
      case EngineLaunchError(:final message):
        log(message, name: _logName);
        _emit(EngineState.stopped(error: message));
        return;
      case final EngineLaunch resolved:
        launch = resolved;
    }

    final run = _EngineRun();
    await run.openLog(logPath);
    if (generation != _generation) return run.close();
    final sessionsDir = '$_workflowRoot/.dashboard/engine-sessions';
    run.mark('spawn ${launch.node} ${launch.script} --sessions-dir $sessionsDir');

    final Process process;
    try {
      process = await _startProcess(
        launch.node,
        [launch.script, '--port', '0', '--sessions-dir', sessionsDir],
        workingDirectory: launch.engineDir,
        environment: {...env, 'CLAUDE_HOME': _claudeHome},
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e, st) {
      log('spawn failed', name: _logName, error: e, stackTrace: st);
      run.mark('spawn falhou: ${e.message}');
      await run.close();
      if (generation == _generation) _emit(EngineState.stopped(error: 'falha ao iniciar o engine: ${e.message}'));
      return;
    }
    final clock = Stopwatch()..start();
    run.process = process;
    run.mark('pid ${process.pid}');

    final timer = Timer(_readyTimeout, () {
      if (run.ready || _run != run) return;
      run.failure = 'sem ENGINE_READY em ${_readyTimeout.inSeconds} s';
      run.mark(run.failure!);
      process.kill(ProcessSignal.sigkill);
    });

    final outDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          run.write('out', line);
          if (run.ready || run.failure != null) return;
          final ready = parseReadyLine(line);
          if (ready == null) return;
          run.ready = true;
          timer.cancel();
          run.mark('ready port=${ready.port} pid=${ready.pid} em ${clock.elapsedMilliseconds} ms');
          if (_run != run) return;
          final base = Uri(scheme: 'http', host: '127.0.0.1', port: ready.port);
          _emit(EngineState.ok(base));
          unawaited(_checkVersion(base));
        })
        .asFuture<void>();
    final errDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          run.write('err', line);
          run.tail.addLast(line);
          if (run.tail.length > 20) run.tail.removeFirst();
        })
        .asFuture<void>();

    unawaited(
      process.exitCode.then((code) async {
        timer.cancel();
        // A grandchild that inherited the pipes can keep them open after the engine is gone.
        await Future.wait([outDone, errDone]).timeout(const Duration(milliseconds: 500), onTimeout: () => const []);
        run.mark('exit $code');
        await run.close();
        run.exited.complete();
        if (_run != run) return;
        _run = null;

        bool concurrentTook = false;
        final error = run.failure ?? 'engine saiu (código $code)';
        if (run.failure == null) {
          // Check if another instance took over the engine
          concurrentTook = await _checkConcurrentInstance(sessionsDir);
        }

        log(error, name: _logName);
        _emit(
          EngineState.stopped(
            error: concurrentTook ? null : error,
            concurrentInstanceTook: concurrentTook,
            stderrTail: List.unmodifiable(run.tail),
          ),
        );
      }),
    );

    if (generation != _generation) return run.terminate(_killGrace);
    _run = run;
  }

  Future<void> _stop() async {
    _generation++;
    final run = _run;
    _run = null;
    if (run != null) await run.terminate(_killGrace);
  }

  Future<void> _checkVersion(Uri base) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(base.resolve('/api/health'));
      final response = await request.close().timeout(const Duration(seconds: 2));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 2));
      final decoded = jsonDecode(body);
      final version = decoded is Map ? decoded['version'] : null;
      if (version == kEngineVersion || _state.endpoint != base) return;
      _emit(EngineState.ok(base, versionWarning: 'engine ${version ?? '?'} difere da versão esperada $kEngineVersion'));
    } on Exception catch (e, st) {
      log('health check failed', name: _logName, error: e, stackTrace: st);
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _checkConcurrentInstance(String sessionsDir) async {
    try {
      final pidFile = File('$sessionsDir/engine.pid');
      if (!await pidFile.exists()) return false;

      final pidContent = await pidFile.readAsString();
      final newPid = int.tryParse(pidContent.trim());
      if (newPid == null) return false;

      // Check if the new pid is running and has --sessions-dir in its command
      return await _isEngineProcess(newPid);
    } on Exception catch (e, st) {
      log('cannot check concurrent instance', name: _logName, error: e, stackTrace: st);
      return false;
    }
  }
}

class _EngineRun {
  late final Process process;
  final tail = ListQueue<String>();
  final exited = Completer<void>();
  bool ready = false;
  String? failure;
  IOSink? _log;

  Future<void> openLog(String path) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      _log = file.openWrite(mode: FileMode.append);
    } on FileSystemException catch (e, st) {
      log('cannot open $path', name: _logName, error: e, stackTrace: st);
    }
  }

  void write(String stream, String line) => _log?.writeln('${DateTime.now().toIso8601String()} [$stream] $line');

  void mark(String event) {
    log(event, name: _logName);
    _log?.writeln('${DateTime.now().toIso8601String()} $event');
  }

  Future<void> close() async {
    final sink = _log;
    _log = null;
    try {
      await sink?.close();
    } on FileSystemException catch (e, st) {
      log('cannot write engine.log', name: _logName, error: e, stackTrace: st);
    }
  }

  /// stdin EOF is the engine's primary exit path; SIGTERM backs it up and SIGKILL ends it after [grace].
  Future<void> terminate(Duration grace) async {
    mark('sigterm');
    unawaited(process.stdin.close().then((_) {}, onError: (_) {}));
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(grace);
    } on TimeoutException {
      mark('sigkill');
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await exited.future;
  }
}
