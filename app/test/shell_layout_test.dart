import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Future<GoRouter> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: MockFlowRepository(),
      sessions: MockSessionsRepository(),
      engine: const MockEngineController(),
      docs: MockDocsRepository(),
      github: MockGitHubRepository.sample(),
    ),
  );
  await tester.pumpAndSettle();
  return GoRouter.of(tester.element(find.byType(Scaffold).first));
}

void main() {
  for (final tab in ['flow', 'artifacts', 'runs']) {
    testWidgets('/p/web-console/$tab fits the minimum window', (tester) async {
      final router = await _open(tester, const Size(1100, 700));
      router.go('/p/web-console/$tab');
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1100, 700);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('sidebar is 216 wide', (tester) async {
    await _open(tester, const Size(1100, 700));
    expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 216);
  });

  testWidgets('demo-app flow fits 1400x700', (tester) async {
    final router = await _open(tester, const Size(1400, 700));
    router.go('/p/demo-app/flow');
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1400, 700);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
