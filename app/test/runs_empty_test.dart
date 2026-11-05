import 'package:claude_flow/core/theme/app_theme.dart';
import 'package:claude_flow/data/flow_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/features/runs/runs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo extends Fake implements FlowRepository {
  _Repo(this.project);

  final Project project;

  @override
  Stream<Project?> watchProject(String name) => Stream.value(project);
}

Future<void> _pump(WidgetTester tester, Project project) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: RepositoryScope(
          repository: _Repo(project),
          child: const RunsPage(projectName: 'p'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('without a cycle the empty state only points to /implement', (tester) async {
    await _pump(tester, const Project(name: 'p'));

    expect(find.text('As execuções aparecem a partir do /implement.'), findsOneWidget);
    expect(find.textContaining('Etapa atual'), findsNothing);
  });

  testWidgets('with a cycle and no runs it also shows the current stage', (tester) async {
    await _pump(
      tester,
      const Project(
        name: 'p',
        cycle: Cycle(stage: Stage.tasks, runs: [], autoMode: false, stageMinutes: {}),
      ),
    );

    expect(find.text('As execuções aparecem a partir do /implement.\nEtapa atual: tasks'), findsOneWidget);
  });
}
