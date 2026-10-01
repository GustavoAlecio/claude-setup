import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/data/file_flow_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:claude_flow/engine/engine_supervisor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

String _ready(int port) => "echo 'ENGINE_READY {\"port\":$port,\"pid\":'\$\$'}'";

class _Spawn {
  _Spawn(this.executable, this.arguments, this.workingDirectory, this.environment, this.includeParentEnvironment);

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;
  final bool includeParentEnvironment;
}

/// Stands in for node: runs [script] with `/bin/sh` and records how the supervisor asked to spawn it.
class _ShellEngine {
  _ShellEngine(this.script);

  String script;
  final spawns = <_Spawn>[];
  Process? process;

  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async {
    spawns.add(_Spawn(executable, arguments, workingDirectory, environment, includeParentEnvironment));
    return process = await Process.start('/bin/sh', ['-c', script]);
  }
}

const _fixtureNames = ['alpha', 'beta', 'broken', 'gamma', 'legacy'];

/// Real IO does not advance under FakeAsync, so the fixtures load in runAsync (same harness as file_flow_test).
Future<List<Project>> _loadFixtures(WidgetTester tester) async {
  final projects = await tester.runAsync(() async {
    final repo = FileFlowRepository(
      Directory('test/fixtures/workflow').absolute.path,
      stacksDir: Directory('test/fixtures/stacks').absolute.path,
    );
    try {
      return await repo
          .watchProjects()
          .firstWhere((list) => _fixtureNames.every((n) => list.any((p) => p.name == n)))
          .timeout(const Duration(seconds: 10));
    } finally {
      await repo.dispose();
    }
  });
  return projects!;
}

Future<void> _go(WidgetTester tester, String location) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
  await tester.pumpAndSettle();
}

class _EngineSpy implements EngineController {
  final states = StreamController<EngineState>.broadcast();
  int restarts = 0;

  @override
  Stream<EngineState> watch() => states.stream;

  @override
  Future<void> restart() async => restarts++;

  @override
  Future<void> shutdown() async {}
}

Future<EngineState> _until(Stream<EngineState> states, bool Function(EngineState) test) =>
    states.firstWhere(test).timeout(const Duration(seconds: 15));

void main() {
  group('parseEnv0', () {
    test('drops rc noise before the sentinel and keeps values with = and newlines', () {
      final env = parseEnv0('\x1b[?25lwelcome\n${kEnvSentinel}PATH=/a:/b\x00X=a=b\x00MULTI=1\n2\x00\x00');
      expect(env, {'PATH': '/a:/b', 'X': 'a=b', 'MULTI': '1\n2'});
    });

    test('is null without the sentinel', () {
      expect(parseEnv0('PATH=/usr/bin\x00HOME=/x\x00'), isNull);
    });
  });

  group('parseReadyLine', () {
    test('reads port and pid', () {
      expect(parseReadyLine('ENGINE_READY {"port":4317,"pid":99}'), (port: 4317, pid: 99));
    });

    test('rejects anything else', () {
      expect(parseReadyLine('engine listening on 4317'), isNull);
      expect(parseReadyLine('ENGINE_READY {"port":"x","pid":1}'), isNull);
      expect(parseReadyLine('ENGINE_READY {broken'), isNull);
      expect(parseReadyLine('  ENGINE_READY {"port":1,"pid":1}'), isNull);
    });
  });

  group('DashboardConfig.parse', () {
    test('reads the optional keys and ignores invalid entries', () {
      final config = DashboardConfig.parse(
        jsonEncode({
          'engineDir': '/repo/engine',
          'nodePath': '',
          'paletteSkills': ['plan', 3, 'verify'],
          'cwds': {'alpha': '/src/alpha', 'beta': 1},
        }),
      );
      expect(config.engineDir, '/repo/engine');
      expect(config.nodePath, isNull);
      expect(config.paletteSkills, ['plan', 'verify']);
      expect(config.cwds, {'alpha': '/src/alpha'});
      expect(DashboardConfig.parse('{}').paletteSkills, isNull);
      expect(() => DashboardConfig.parse('{'), throwsFormatException);
    });
  });

  group('resolveEngineLaunch', () {
    EngineLaunchResult resolve({
      String define = '',
      DashboardConfig config = DashboardConfig.empty,
      Map<String, String> env = const {'PATH': '/usr/bin:/opt/homebrew/bin', 'HOME': '/Users/me'},
      Set<String> files = const {},
    }) => resolveEngineLaunch(engineDirDefine: define, config: config, env: env, fileExists: files.contains);

    String? error(EngineLaunchResult r) => r is EngineLaunchError ? r.message : null;

    test('the three configuration errors use the exact texts', () {
      expect(error(resolve()), 'configure engineDir em ~/.claude/workflow/.dashboard.json');
      expect(
        error(resolve(config: const DashboardConfig(engineDir: '/repo/engine'))),
        'node não encontrado: defina nodePath em ~/.claude/workflow/.dashboard.json',
      );
      expect(
        error(
          resolve(
            config: const DashboardConfig(engineDir: '/repo/engine'),
            files: {'/opt/homebrew/bin/node'},
          ),
        ),
        'rode: cd /repo/engine && npm ci',
      );
    });

    test('ENGINE_DIR define wins over engineDir and node comes from the captured PATH', () {
      final launch = resolve(
        define: '/define/engine/',
        config: const DashboardConfig(engineDir: '/repo/engine'),
        files: {'/opt/homebrew/bin/node', '/define/engine/node_modules'},
      );
      expect(launch, isA<EngineLaunch>());
      launch as EngineLaunch;
      expect(launch.engineDir, '/define/engine');
      expect(launch.node, '/opt/homebrew/bin/node');
      expect(launch.script, '/define/engine/index.mjs');
    });

    test('nodePath wins over PATH, expands ~ and must exist', () {
      const config = DashboardConfig(engineDir: '~/engine', nodePath: '~/.nvm/node');
      final launch = resolve(
        config: config,
        files: {'/Users/me/.nvm/node', '/usr/bin/node', '/Users/me/engine/node_modules'},
      );
      expect((launch as EngineLaunch).node, '/Users/me/.nvm/node');
      expect(launch.engineDir, '/Users/me/engine');
      expect(error(resolve(config: config, files: {'/usr/bin/node', '/Users/me/engine/node_modules'})), kMissingNode);
    });
  });

  group('EngineSupervisor with fakes', () {
    late Directory root;
    late Directory engineDir;
    HttpOverrides? bindingOverrides;

    setUp(() async {
      // The testWidgets below install a binding whose HttpOverrides answer 400 to every request; the
      // health check here must reach the loopback server.
      bindingOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = bindingOverrides);
      root = await Directory.systemTemp.createTemp('engine_sup_');
      engineDir = await Directory('${root.path}/engine').create();
    });

    tearDown(() => root.delete(recursive: true));

    EngineSupervisor supervisor(_ShellEngine engine, {FileExists? fileExists, Duration? readyTimeout}) =>
        EngineSupervisor(
          workflowRoot: '${root.path}/workflow',
          captureEnv: () async => {'PATH': '/fake/bin', 'HOME': root.path},
          startProcess: engine.start,
          fileExists: fileExists ?? (_) => true,
          readConfig: () async => DashboardConfig(engineDir: engineDir.path),
          readyTimeout: readyTimeout ?? const Duration(seconds: 5),
        );

    test('iniciando -> ok -> parado, spawning node with the captured env and CLAUDE_HOME', () async {
      final health = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      health.listen(
        (r) => r.response
          ..write(jsonEncode({'ok': true, 'version': kEngineVersion}))
          ..close(),
      );
      addTearDown(health.close);
      final engine = _ShellEngine(
        'echo booting >&2; sleep 0.2; ${_ready(health.port)}; echo boom >&2; exec cat >/dev/null',
      );
      final sup = supervisor(engine);
      final states = <EngineState>[];
      final endpoints = <Uri?>[];
      final sub = sup.watch().listen(states.add);
      final endSub = sup.endpoint.listen(endpoints.add);
      addTearDown(sub.cancel);
      addTearDown(endSub.cancel);

      final ok = await _until(sup.watch(), (s) => s.status == EngineStatus.ok);
      expect(ok.endpoint, Uri.parse('http://127.0.0.1:${health.port}'));
      expect(states.first.status, EngineStatus.starting);

      final spawn = engine.spawns.single;
      expect(spawn.executable, '/fake/bin/node');
      expect(spawn.arguments, [
        '${engineDir.path}/index.mjs',
        '--port',
        '0',
        '--sessions-dir',
        '${root.path}/workflow/.dashboard/engine-sessions',
      ]);
      expect(spawn.workingDirectory, engineDir.path);
      expect(spawn.includeParentEnvironment, isFalse);
      expect(spawn.environment, {'PATH': '/fake/bin', 'HOME': root.path, 'CLAUDE_HOME': root.path});

      engine.process!.kill(ProcessSignal.sigkill);
      final stopped = await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      expect(stopped.error, contains('engine saiu'));
      expect(stopped.stderrTail, ['booting', 'boom']);
      expect(states.map((s) => s.status), [EngineStatus.starting, EngineStatus.ok, EngineStatus.stopped]);
      expect(states[1].versionWarning, isNull);
      expect(endpoints, [null, ok.endpoint, null]);

      final log = await File(sup.logPath).readAsString();
      expect(log, contains(' spawn '));
      expect(log, contains(' ready port=${health.port}'));
      expect(log, contains('[err] boom'));
    });

    test('restart spawns a new engine after a crash', () async {
      final engine = _ShellEngine('exit 3');
      final sup = supervisor(engine);
      final stopped = await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      expect(stopped.error, 'engine saiu (código 3)');

      engine.script = '${_ready(1)}; exec cat >/dev/null';
      unawaited(sup.restart());
      await _until(sup.watch(), (s) => s.status == EngineStatus.ok);
      expect(engine.spawns, hasLength(2));
      await sup.shutdown();
    });

    test('configuration errors stop without spawning', () async {
      final engine = _ShellEngine('true');
      final sup = supervisor(engine, fileExists: (p) => !p.endsWith('/node_modules'));
      final stopped = await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      expect(stopped.error, 'rode: cd ${engineDir.path} && npm ci');
      expect(engine.spawns, isEmpty);
    });

    test('a different engine version is a non-blocking warning', () async {
      final health = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      health.listen(
        (r) => r.response
          ..write(jsonEncode({'ok': true, 'version': '9.9.9'}))
          ..close(),
      );
      addTearDown(health.close);
      final engine = _ShellEngine('${_ready(health.port)}; exec cat >/dev/null');
      final sup = supervisor(engine);
      final warned = await _until(sup.watch(), (s) => s.versionWarning != null);
      expect(warned.status, EngineStatus.ok);
      expect(warned.versionWarning, contains('9.9.9'));
      await sup.shutdown();
    });

    test('detects when another instance took over the engine', () async {
      final engine = _ShellEngine('exit 1');
      late Directory sessionsDir;

      // First run exits normally (no concurrent instance)
      var sup = EngineSupervisor(
        workflowRoot: '${root.path}/workflow',
        captureEnv: () async => {'PATH': '/fake/bin', 'HOME': root.path},
        startProcess: engine.start,
        fileExists: (_) => true,
        readConfig: () async => DashboardConfig(engineDir: engineDir.path),
        isEngineProcess: (_) async => false, // No concurrent instance
      );
      var stopped = await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      expect(stopped.concurrentInstanceTook, isFalse);
      expect(stopped.error, isNotNull);

      // Second run: inject a fake isEngineProcess that returns true for a specific pid
      sessionsDir = Directory('${root.path}/workflow/.dashboard/engine-sessions');
      await sessionsDir.create(recursive: true);

      final fakePid = 12345; // Fake pid that our fake will recognize
      await File('${sessionsDir.path}/engine.pid').writeAsString('$fakePid\n');

      engine.script = 'exit 2';
      sup = EngineSupervisor(
        workflowRoot: '${root.path}/workflow',
        captureEnv: () async => {'PATH': '/fake/bin', 'HOME': root.path},
        startProcess: engine.start,
        fileExists: (_) => true,
        readConfig: () async => DashboardConfig(engineDir: engineDir.path),
        isEngineProcess: (pid) async => pid == fakePid, // Return true only for our fake pid
      );
      stopped = await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      expect(stopped.concurrentInstanceTook, isTrue);
      expect(stopped.error, isNull); // When concurrent instance took over, error is null

      // Negative case: dead pid (isEngineProcess returns false)
      engine.script = 'exit 3';
      sup = EngineSupervisor(
        workflowRoot: '${root.path}/workflow',
        captureEnv: () async => {'PATH': '/fake/bin', 'HOME': root.path},
        startProcess: engine.start,
        fileExists: (_) => true,
        readConfig: () async => DashboardConfig(engineDir: engineDir.path),
        isEngineProcess: (_) async => false, // Dead process, not an engine
      );
      stopped = await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      expect(stopped.concurrentInstanceTook, isFalse);
      expect(stopped.error, isNotNull); // Error should be set since no concurrent instance took over
    });
  });

  group('EngineSupervisor with real defaults', () {
    late Directory root;
    late String workflowRoot;
    late File node;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('engine_sup_real_');
      workflowRoot = '${root.path}/workflow';
      final engineDir = await Directory('${root.path}/engine/node_modules').create(recursive: true);
      node = File('${root.path}/fake-node');
      await File('$workflowRoot/.dashboard.json')
          .create(recursive: true)
          .then((f) => f.writeAsString(jsonEncode({'engineDir': engineDir.parent.path, 'nodePath': node.path})));
    });

    tearDown(() => root.delete(recursive: true));

    Future<void> fakeNode(String body) async {
      await node.writeAsString('#!/bin/sh\n$body\n');
      await Process.run('chmod', ['+x', node.path]);
    }

    test('captureLoginEnv returns the user env', () async {
      final env = await captureLoginEnv();
      expect(env['HOME'], isNotEmpty);
      expect(env['PATH'], isNotEmpty);
    });

    test('ready, then stdin EOF ends an engine that ignores SIGTERM without SIGKILL', () async {
      await fakeNode("trap '' TERM\n${_ready(1)}\ncat >/dev/null\necho bye >&2");
      final sup = EngineSupervisor(workflowRoot: workflowRoot);
      final ok = await _until(sup.watch(), (s) => s.status == EngineStatus.ok);
      expect(ok.endpoint!.port, 1);

      final clock = Stopwatch()..start();
      await sup.shutdown();
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      final log = await File(sup.logPath).readAsString();
      expect(log, contains('[err] bye'));
      expect(log, isNot(contains('sigkill')));
    });

    test('no ENGINE_READY in time stops with the last 20 stderr lines', () async {
      await fakeNode('for i in \$(seq 1 25); do echo "line \$i" >&2; done\nexec sleep 30');
      final sup = EngineSupervisor(workflowRoot: workflowRoot, readyTimeout: const Duration(seconds: 1));
      final stopped = await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      expect(stopped.error, 'sem ENGINE_READY em 1 s');
      expect(stopped.stderrTail, [for (var i = 6; i <= 25; i++) 'line $i']);
    });

    test('an engine that ignores SIGTERM and stdin is killed after the grace period', () async {
      await fakeNode("trap '' TERM\n${_ready(1)}\nexec sleep 30");
      final sup = EngineSupervisor(workflowRoot: workflowRoot);
      await _until(sup.watch(), (s) => s.status == EngineStatus.ok);

      final clock = Stopwatch()..start();
      await sup.shutdown();
      expect(clock.elapsed, greaterThanOrEqualTo(const Duration(seconds: 3)));
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await File(sup.logPath).readAsString(), contains('sigkill'));
      final last = await sup.watch().first;
      expect(last.status, EngineStatus.stopped);
      expect(last.error, isNull);
    });
  });

  group('EngineSupervisor in the app', () {
    setUp(() {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1440, 900);
      view.devicePixelRatio = 1;
    });

    const engineDir = '/repo/engine';
    for (final (name, files, text) in [
      ('engineDir', null, kMissingEngineDir),
      ('nodePath', <String>{}, kMissingNode),
      ('node_modules', {'/fake/bin/node'}, 'rode: cd /repo/engine && npm ci'),
    ]) {
      testWidgets('missing $name shows "$text" while Fluxo and Execuções render the fixture', (tester) async {
        final data = await _loadFixtures(tester);
        final sup = EngineSupervisor(
          workflowRoot: '/nonexistent/workflow',
          captureEnv: () async => {'PATH': '/fake/bin', 'HOME': '/Users/me'},
          startProcess: (_, _, {workingDirectory, environment, includeParentEnvironment = true}) =>
              throw StateError('must not spawn'),
          fileExists: (files ?? const <String>{}).contains,
          readConfig: () async => files == null ? DashboardConfig.empty : const DashboardConfig(engineDir: engineDir),
        );
        await tester.pumpWidget(
          ClaudeFlowApp(
            repository: MockFlowRepository(data: data),
            sessions: MockSessionsRepository(),
            engine: sup,
          ),
        );
        await tester.pumpAndSettle();
        await _go(tester, '/p/alpha/flow');

        expect(find.text('engine parado'), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(find.text('Reiniciar'), findsOneWidget);
        expect(find.text('Pagina alpha'), findsWidgets);

        await _go(tester, '/p/alpha/runs');
        expect(find.text('Bloc e repositorio do alpha'), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('footer goes engine iniciando -> engine ok -> engine parado', (tester) async {
      final data = await _loadFixtures(tester);
      final env = Completer<Map<String, String>>();
      late Directory root;
      late _ShellEngine engine;
      late EngineSupervisor sup;
      late StreamSubscription<EngineState> keepAlive;
      // The supervisor starts in the real zone so its process IO is not parked in FakeAsync.
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('engine_footer_');
        final dir = await Directory('${root.path}/engine').create();
        engine = _ShellEngine('${_ready(1)}; exec cat >/dev/null');
        sup = EngineSupervisor(
          workflowRoot: '${root.path}/workflow',
          captureEnv: () => env.future,
          startProcess: engine.start,
          fileExists: (_) => true,
          readConfig: () async => DashboardConfig(engineDir: dir.path),
        );
        keepAlive = sup.watch().listen((_) {});
      });
      addTearDown(
        () => tester.runAsync(() async {
          await keepAlive.cancel();
          await root.delete(recursive: true);
        }),
      );

      await tester.pumpWidget(
        ClaudeFlowApp(
          repository: MockFlowRepository(data: data),
          sessions: MockSessionsRepository(),
          engine: sup,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('engine iniciando'), findsOneWidget);
      expect(find.text('Reiniciar'), findsNothing);

      await tester.runAsync(() async {
        env.complete({'PATH': '/fake/bin', 'HOME': root.path});
        await _until(sup.watch(), (s) => s.status == EngineStatus.ok);
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('engine ok'), findsOneWidget);
      expect(find.text('Reiniciar'), findsNothing);

      await tester.runAsync(() async {
        engine.process!.kill(ProcessSignal.sigkill);
        await _until(sup.watch(), (s) => s.status == EngineStatus.stopped);
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('engine parado'), findsOneWidget);
      expect(find.text('Reiniciar'), findsOneWidget);
      expect(find.textContaining('engine saiu'), findsOneWidget);
    });

    testWidgets('Reiniciar restarts the engine and a version mismatch is shown as a warning', (tester) async {
      final engine = _EngineSpy();
      addTearDown(engine.states.close);
      await tester.pumpWidget(
        ClaudeFlowApp(repository: const MockFlowRepository(), sessions: MockSessionsRepository(), engine: engine),
      );
      await tester.pumpAndSettle();

      engine.states.add(const EngineState.stopped(error: 'engine saiu (código 1)', stderrTail: ['boom']));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reiniciar'));
      await tester.pump();
      expect(engine.restarts, 1);
      expect(find.text('stderr: boom'), findsOneWidget);

      engine.states.add(EngineState.ok(Uri.parse('http://127.0.0.1:1'), versionWarning: 'engine 9.9.9 difere'));
      await tester.pumpAndSettle();
      expect(find.text('engine ok'), findsOneWidget);
      expect(find.text('engine 9.9.9 difere'), findsOneWidget);
      expect(find.text('Reiniciar'), findsNothing);
    });

    testWidgets('footer with 20 long stderr lines does not overflow in narrow sidebar', (tester) async {
      final data = await _loadFixtures(tester);
      final engine = _EngineSpy();
      addTearDown(engine.states.close);

      final longLines = [
        for (var i = 1; i <= 20; i++)
          'Error line $i with a very long message that could potentially cause the footer to overflow if not properly constrained: ${'x' * 50}',
      ];

      await tester.pumpWidget(
        ClaudeFlowApp(
          repository: MockFlowRepository(data: data),
          sessions: MockSessionsRepository(),
          engine: engine,
        ),
      );
      await tester.pumpAndSettle();
      await _go(tester, '/p/alpha/flow');

      engine.states.add(EngineState.stopped(error: 'engine error', stderrTail: longLines));
      await tester.pumpAndSettle();

      expect(find.text('engine parado'), findsOneWidget);
      expect(find.text('Reiniciar'), findsOneWidget);
      expect(find.text('ver detalhes'), findsOneWidget);
      // Verify footer renders without overflow; SingleChildScrollView handles the height constraint
      expect(tester.takeException(), isNull);
    });

    testWidgets('footer shows concurrent instance message when another app took over', (tester) async {
      final data = await _loadFixtures(tester);
      final engine = _EngineSpy();
      addTearDown(engine.states.close);

      await tester.pumpWidget(
        ClaudeFlowApp(
          repository: MockFlowRepository(data: data),
          sessions: MockSessionsRepository(),
          engine: engine,
        ),
      );
      await tester.pumpAndSettle();
      await _go(tester, '/p/alpha/flow');

      engine.states.add(const EngineState.stopped(concurrentInstanceTook: true, stderrTail: []));
      await tester.pumpAndSettle();

      expect(find.text('engine parado'), findsOneWidget);
      expect(find.text('outra instância do app assumiu o engine'), findsOneWidget);
      expect(find.text('Reiniciar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
