import 'package:flutter_test/flutter_test.dart';
import 'package:claude_flow/features/shell/shell_scope.dart';

void main() {
  const expectedGroup = {
    AppTab.flow: ProjectGroup.cycle,
    AppTab.runs: ProjectGroup.cycle,
    AppTab.sessions: ProjectGroup.talks,
    AppTab.prs: ProjectGroup.prs,
    AppTab.reviews: ProjectGroup.prs,
    AppTab.artifacts: ProjectGroup.reference,
    AppTab.adrs: ProjectGroup.reference,
    AppTab.metrics: ProjectGroup.reference,
    AppTab.queue: ProjectGroup.cycle,
    AppTab.inbox: ProjectGroup.cycle,
  };

  test('groupOf covers every tab per the table', () {
    expect(expectedGroup.keys.toSet(), AppTab.values.toSet());
    for (final t in AppTab.values) {
      expect(groupOf(t), expectedGroup[t], reason: t.name);
    }
  });

  test('groups are ordered and labelled', () {
    expect(ProjectGroup.values.map((g) => g.label), ['Ciclo', 'Conversas', 'PRs', 'Referência']);
  });

  test('groupTabs follows the table', () {
    expect(groupTabs(ProjectGroup.cycle), [AppTab.flow, AppTab.runs]);
    expect(groupTabs(ProjectGroup.talks), [AppTab.sessions]);
    expect(groupTabs(ProjectGroup.prs), [AppTab.prs, AppTab.reviews]);
    expect(groupTabs(ProjectGroup.reference), [AppTab.artifacts, AppTab.adrs, AppTab.metrics]);
  });

  test('groupOf round-trips groupTabs', () {
    for (final g in ProjectGroup.values) {
      for (final t in groupTabs(g)) {
        expect(groupOf(t), g, reason: t.name);
      }
    }
  });

  test('every project tab is in exactly one group', () {
    for (final t in AppTab.values.where((t) => t != AppTab.queue && t != AppTab.inbox)) {
      final count = ProjectGroup.values.where((g) => groupTabs(g).contains(t)).length;
      expect(count, 1, reason: t.name);
    }
  });

  test('subTabLabel uses the sub-tab names and falls back to label', () {
    expect(subTabLabel(AppTab.artifacts), 'Documentos');
    expect(subTabLabel(AppTab.metrics), 'Números');
    expect(subTabLabel(AppTab.flow), 'Fluxo');
    expect(subTabLabel(AppTab.runs), 'Execuções');
    expect(subTabLabel(AppTab.sessions), AppTab.sessions.label);
    expect(subTabLabel(AppTab.inbox), AppTab.inbox.label);
    expect(subTabLabel(AppTab.queue), AppTab.queue.label);
  });

  test('activeSubTab maps queue to flow and inbox to none', () {
    expect(activeSubTab(AppTab.queue), AppTab.flow);
    expect(activeSubTab(AppTab.inbox), isNull);
    expect(activeSubTab(AppTab.runs), AppTab.runs);
    expect(activeSubTab(AppTab.sessions), AppTab.sessions);
  });
}
