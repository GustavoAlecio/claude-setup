import 'package:claude_flow/core/theme/app_theme.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/features/sessions/session_events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _question = 'Como seguir?';

Future<List<Map<String, String>?>> _pump(
  WidgetTester tester, {
  Map<String, String>? answers,
  bool pending = true,
}) async {
  final sent = <Map<String, String>?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: QuestionCard(
            QuestionRequest(
              't',
              requestId: 'q',
              seq: 1,
              questions: const [
                Question(
                  question: _question,
                  header: 'spec',
                  options: [
                    QuestionOption('Aprovar (Recomendado)', 'segue para o próximo passo'),
                    QuestionOption('Revisar', ''),
                  ],
                ),
              ],
              decision: pending ? null : PermissionDecision.answer,
              answers: answers,
            ),
            onAnswer: (_, _, {answers}) async => sent.add(answers),
          ),
        ),
      ),
    ),
  );
  return sent;
}

void main() {
  testWidgets('pendente mostra Precisa de você, rótulo limpo e pill recomendado; envia o rótulo original', (
    tester,
  ) async {
    final sent = await _pump(tester);

    expect(find.byKey(const ValueKey('question-needs-you')), findsOneWidget);
    expect(find.text('Aprovar'), findsOneWidget);
    expect(find.text('Aprovar (Recomendado)'), findsNothing);
    expect(find.byKey(const ValueKey('option-recommended')), findsOneWidget);
    expect(find.text('— segue para o próximo passo'), findsOneWidget);

    await tester.tap(find.text('Aprovar'));
    await tester.pump();
    await tester.tap(find.text('Responder'));
    await tester.pumpAndSettle();

    expect(sent.single, {_question: 'Aprovar (Recomendado)'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('respondida não mostra Precisa de você e tira o sufixo do rótulo', (tester) async {
    await _pump(tester, pending: false, answers: {_question: 'Aprovar (Recomendado)'});

    expect(find.byKey(const ValueKey('question-needs-you')), findsNothing);
    expect(find.text('respondido: Aprovar'), findsOneWidget);
  });

  testWidgets('multiSelect respondida tira o sufixo de cada opção', (tester) async {
    await _pump(tester, pending: false, answers: {_question: 'Aprovar (Recomendado), Revisar'});

    expect(find.text('respondido: Aprovar, Revisar'), findsOneWidget);
  });
}
