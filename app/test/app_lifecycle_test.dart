import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReloadSpy extends MockFlowRepository {
  _ReloadSpy();

  int reloads = 0;

  @override
  Future<void> reload() async => reloads++;
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('resuming the app asks the repository to reload', (tester) async {
    final repo = _ReloadSpy();
    await tester.pumpWidget(ClaudeFlowApp(repository: repo));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    expect(repo.reloads, 1);
  });
}
