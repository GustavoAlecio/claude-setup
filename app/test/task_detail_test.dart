import 'package:claude_flow/core/theme/app_theme.dart';
import 'package:claude_flow/data/flow_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/features/runs/task_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo extends Fake implements FlowRepository {
  _Repo(this.run);

  final Run run;

  @override
  Stream<Run?> watchRun(String project, String runId) => Stream.value(run);
}

Future<void> _pump(WidgetTester tester, String description) async {
  final run = Run(
    id: 'r1',
    kind: 'implement',
    status: Verdict.pass,
    startedAt: '14:00',
    tasks: [
      TaskRun(
        id: 'T1',
        title: 'Titulo',
        complexity: Complexity.m,
        tier0: Tier.sonnet,
        status: Verdict.pass,
        description: description,
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: RepositoryScope(
          repository: _Repo(run),
          child: const TaskDetailPage(projectName: 'p', runId: 'r1', taskId: 'T1'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1440, 900);
    view.devicePixelRatio = 1;
  });

  testWidgets('description renders markdown without raw markers and is selectable', (tester) async {
    final desc = [
      '**Contexto:** Passo 2 do plano.',
      '',
      '**O que fazer:**',
      '- Criar `lib/x.dart`',
      '',
      '**Testes:**',
      '- `test/x_test.dart`',
      '',
      '**Concluído quando:**',
      '- `flutter analyze` limpo',
    ].join('\n');
    await _pump(tester, desc);

    expect(find.textContaining('**', findRichText: true), findsNothing);
    expect(find.textContaining('`', findRichText: true), findsNothing);
    expect(find.textContaining('•', findRichText: true), findsWidgets);
    final path = find.text('lib/x.dart', findRichText: true);
    expect(path, findsOneWidget);
    expect(find.ancestor(of: path, matching: find.byType(SelectionArea)), findsOneWidget);
  });

  testWidgets('long paragraph without markers is rendered whole', (tester) async {
    final desc = List.filled(40, 'palavra longa de teste').join(' ');
    expect(desc.length, greaterThan(600));
    await _pump(tester, desc);

    expect(find.text(desc, findRichText: true), findsOneWidget);
  });
}
