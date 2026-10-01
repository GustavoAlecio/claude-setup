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

  testWidgets('flow → runs → blocked task shows the ToT diagnosis', (tester) async {
    await tester.pumpWidget(const ClaudeFlowApp(repository: MockFlowRepository()));
    await tester.pumpAndSettle();

    expect(find.text('Favoritos offline'), findsWidgets);
    expect(find.textContaining('T4 bloqueou'), findsOneWidget);

    await tester.tap(find.text('Execuções'));
    await tester.pumpAndSettle();
    expect(find.text('Escada por task'), findsOneWidget);
    expect(find.text('lente: plan'), findsOneWidget);

    final t4 = find.text('Sincronização offline com fila de mutações');
    await tester.ensureVisible(t4);
    await tester.pumpAndSettle();
    await tester.tap(t4);
    await tester.pumpAndSettle();
    expect(find.text('Tentativas'), findsOneWidget);
    expect(find.text('repetido ×3'), findsNWidgets(3));
    expect(find.text('igual à #1'), findsNWidgets(2));
    expect(find.text('→ fable'), findsOneWidget);
  });

  testWidgets('pending task row is not navigable', (tester) async {
    await tester.pumpWidget(const ClaudeFlowApp(repository: MockFlowRepository()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Execuções'));
    await tester.pumpAndSettle();

    final t5 = find.text('Tela de favoritos com estado offline');
    await tester.ensureVisible(t5);
    await tester.pumpAndSettle();
    await tester.tap(t5);
    await tester.pumpAndSettle();
    expect(find.text('Escada por task'), findsOneWidget);
  });
}
