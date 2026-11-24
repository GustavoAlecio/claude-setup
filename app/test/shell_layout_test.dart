import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/app/mock_engine_controller.dart';
import 'package:claude_flow/data/mock_docs_repository.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/mock_github_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/mock_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Future<GoRouter> _open(WidgetTester tester, Size size, {MockFlowRepository? repository}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ClaudeFlowApp(
      repository: repository ?? MockFlowRepository(),
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

  group('project header', () {
    final tracker = find.byKey(const ValueKey('header-tracker'));
    final footerTracker = find.descendant(
      of: find.byKey(const ValueKey('cycle-footer')),
      matching: find.text('LIN-142'),
    );

    Future<void> openFlow(WidgetTester tester, Size size, {MockFlowRepository? repository}) async {
      final router = await _open(tester, size, repository: repository);
      router.go('/p/demo-app/flow');
      await tester.pumpAndSettle();
    }

    testWidgets('1100x700: tracker card leaves the header and stays in the footer', (tester) async {
      await openFlow(tester, const Size(1100, 700));
      expect(tester.takeException(), isNull);
      expect(tracker, findsNothing);
      expect(footerTracker, findsOneWidget);
    });

    testWidgets('1440 wide: tracker card is in the header and the name is not truncated', (tester) async {
      await openFlow(tester, const Size(1440, 900));
      expect(tracker, findsOneWidget);
      final name = tester.widget<Text>(find.byKey(const ValueKey('header-project-name')));
      final box = tester.renderObject<RenderBox>(find.byKey(const ValueKey('header-project-name')));
      final painter = TextPainter(
        text: TextSpan(
          text: 'demo-app',
          style: name.style ?? Theme.of(tester.element(find.byWidget(name))).textTheme.titleMedium,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(box.size.width, greaterThanOrEqualTo(painter.width));
      expect(tester.takeException(), isNull);
    });

    testWidgets('1440 wide: the feature keeps its intrinsic width', (tester) async {
      await openFlow(tester, const Size(1440, 900));
      final feature = find.byKey(const ValueKey('header-feature'));
      final text = tester.widget<Text>(feature);
      final painter = TextPainter(
        text: TextSpan(text: text.data, style: DefaultTextStyle.of(tester.element(feature)).style.merge(text.style)),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(tester.getSize(feature).width, closeTo(painter.width, 1));
    });

    testWidgets('80 character feature at 1100 does not overflow', (tester) async {
      final repository = MockFlowRepository(
        data: [
          Project(
            name: 'demo-app',
            path: '~/development/demo-app',
            cycle: Cycle(
              feature: 'f' * 80,
              tracker: 'LIN-142',
              stage: Stage.implement,
              stageMinutes: const {},
              runs: const [],
            ),
          ),
        ],
      );
      await openFlow(tester, const Size(1100, 700), repository: repository);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tracker card appears from a 1000 wide header: 1215 hides it, 1216 shows it', (tester) async {
      await openFlow(tester, const Size(1215, 700));
      expect(tracker, findsNothing);
      tester.view.physicalSize = const Size(1216, 700);
      await tester.pumpAndSettle();
      expect(tracker, findsOneWidget);
    });
  });
}
