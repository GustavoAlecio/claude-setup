import 'package:claude_flow/app/app.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  Future<void> openSessions(WidgetTester tester) async {
    await tester.pumpWidget(const ClaudeFlowApp(repository: MockFlowRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 aguardando você'));
    await tester.pumpAndSettle();
  }

  testWidgets('pending badge opens the session waiting for permission and allowing resolves it', (tester) async {
    await openSessions(tester);

    expect(find.text('aguardando permissão'), findsOneWidget);
    expect(find.text('lib/features/favorites/data/favorites_sync.dart'), findsOneWidget);

    await tester.ensureVisible(find.text('Permitir'));
    await tester.tap(find.text('Permitir'));
    await tester.pumpAndSettle();
    expect(find.text('permitido'), findsOneWidget);
    expect(find.text('Permitir'), findsNothing);
  });

  testWidgets('question card answers with the selected options', (tester) async {
    await openSessions(tester);
    await tester.tap(find.text('Desafio da spec Favoritos offline'));
    await tester.pumpAndSettle();

    final respond = find.widgetWithText(FilledButton, 'Responder');
    expect(tester.widget<FilledButton>(respond).onPressed, isNull);

    await tester.tap(find.text('B1'));
    await tester.tap(find.text('A2'));
    await tester.pumpAndSettle();
    await tester.tap(respond);
    await tester.pumpAndSettle();
    expect(find.text('respondido: B1, A2'), findsOneWidget);
  });

  testWidgets('detached session offers resume', (tester) async {
    await openSessions(tester);
    await tester.tap(find.text('Status do fluxo'));
    await tester.pumpAndSettle();
    expect(find.text('desanexada'), findsOneWidget);
    expect(find.text('Retomar'), findsOneWidget);
  });

  testWidgets('opening a session from another project moves the sidebar selection', (tester) async {
    await openSessions(tester);
    await tester.tap(find.text('Review PR #412 retry com backoff'));
    await tester.pumpAndSettle();
    expect(find.text('Retry com backoff'), findsWidgets);
    expect(find.text('concluída'), findsOneWidget);
  });

  testWidgets('switching sessions swaps the panel without a page transition', (tester) async {
    await openSessions(tester);
    expect(find.text('aguardando permissão'), findsOneWidget);

    await tester.tap(find.text('Desafio da spec Favoritos offline'));
    await tester.pump();
    expect(find.text('aguardando resposta'), findsOneWidget);
    expect(find.text('aguardando permissão'), findsNothing);
  });
}
