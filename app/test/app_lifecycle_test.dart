import 'dart:ui';

import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReloadSpy extends MockFlowRepository {
  _ReloadSpy();

  int reloads = 0;

  @override
  Future<void> reload() async => reloads++;
}

class _ShutdownSpy extends MockEngineController {
  int shutdowns = 0;

  @override
  Future<void> shutdown() async => shutdowns++;
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('resuming the app asks the repository to reload', (tester) async {
    final repo = _ReloadSpy();
    await tester.pumpWidget(
      ClaudeFlowApp(repository: repo, sessions: MockSessionsRepository(), engine: const MockEngineController()),
    );
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(repo.reloads, 1);
  });

  testWidgets('quitting the app shuts the engine down before allowing the exit', (tester) async {
    final engine = _ShutdownSpy();
    await tester.pumpWidget(
      ClaudeFlowApp(repository: const MockFlowRepository(), sessions: MockSessionsRepository(), engine: engine),
    );
    await tester.pumpAndSettle();

    final response = await tester.binding.handleRequestAppExit();

    expect(engine.shutdowns, 1);
    expect(response, AppExitResponse.exit);
  });
}
