import 'package:claude_flow/core/theme/app_theme.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/features/sessions/session_events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _label = 'Aprovar a proposta inteira';
const _description = 'segue para o próximo passo do pipeline';

Future<void> _pump(WidgetTester tester, double width, {String description = _description}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: QuestionCard(
              QuestionRequest(
                't',
                requestId: 'q',
                seq: 1,
                questions: [
                  Question(question: 'Como seguir?', header: 'spec', options: [QuestionOption(_label, description)]),
                ],
              ),
              onAnswer: (_, _, {answers}) async {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('380 px: description below the label, no overflow', (tester) async {
    await _pump(tester, 380);

    expect(tester.getTopLeft(find.text(_description)).dy, greaterThan(tester.getTopLeft(find.text(_label)).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('600 px: label and description on the same line, no overflow', (tester) async {
    await _pump(tester, 600);

    expect(tester.getCenter(find.text(_description)).dy, closeTo(tester.getCenter(find.text(_label)).dy, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty description renders nothing extra in both layouts', (tester) async {
    for (final width in [380.0, 600.0]) {
      await _pump(tester, width, description: '');
      expect(find.text(_label), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
