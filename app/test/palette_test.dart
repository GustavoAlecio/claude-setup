import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/orgs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('an artifact jump of a project with a space in the name opens the encoded location', (tester) async {
    await tester.pumpWidget(
      ClaudeFlowApp(
        repository: MockFlowRepository(
          data: [const Project(name: 'my app', path: '~/development/my-app')],
        ),
        sessions: MockSessionsRepository(),
        engine: const MockEngineController(),
        docs: MockDocsRepository({'spec.md': '# Spec'}),
      ),
    );
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    router.go(artifactsLocation('my app', 'spec.md'));
    await tester.pumpAndSettle();
    router.go(Uri(pathSegments: ['', 'p', 'my app', 'flow']).toString());
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'spec');
    await tester.pumpAndSettle();
    await tester.tap(find.text('spec.md').last);
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.uri.toString(), artifactsLocation('my app', 'spec.md'));
    expect(artifactsLocation('my app', 'spec.md'), '/p/my%20app/artifacts?doc=spec.md');
  });
}
