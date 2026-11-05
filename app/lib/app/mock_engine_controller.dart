import '../engine/engine_supervisor.dart';

/// `REPO=mock` and widget tests: no process, the engine is always up.
class MockEngineController implements EngineController {
  const MockEngineController();

  @override
  Stream<EngineState> watch() => Stream.value(EngineState.ok(Uri.parse('http://127.0.0.1:0')));

  @override
  Future<void> restart() async {}

  @override
  Future<void> shutdown() async {}
}
