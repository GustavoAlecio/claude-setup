/// What the shell is showing: a project's tabs (`/p/<name>/…`) or the org's own activities (`/o/<org>/…`).
sealed class ShellScope {
  const ShellScope();
}

class ShellProjectScope extends ShellScope {
  const ShellProjectScope(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is ShellProjectScope && other.name == name;

  @override
  int get hashCode => Object.hash(ShellProjectScope, name);
}

class ShellOrgScope extends ShellScope {
  const ShellOrgScope(this.org);

  final String org;

  @override
  bool operator ==(Object other) => other is ShellOrgScope && other.org == org;

  @override
  int get hashCode => Object.hash(ShellOrgScope, org);
}

enum AppTab {
  flow('Fluxo'),
  runs('Execuções'),
  sessions('Conversas'),
  artifacts('Artefatos'),
  reviews('Reviews'),
  prs('PRs'),
  inbox('Para revisar'),
  metrics('Métricas'),
  adrs('ADRs'),

  /// Org scope only: every project of the org at once.
  queue('Caixa de entrada');

  const AppTab(this.label);
  final String label;

  static AppTab parse(String? s) => AppTab.values.where((t) => t.name == s).firstOrNull ?? AppTab.flow;
}

enum ProjectGroup {
  cycle('Ciclo'),
  talks('Conversas'),
  prs('PRs'),
  reference('Referência');

  const ProjectGroup(this.label);
  final String label;
}

ProjectGroup groupOf(AppTab tab) => switch (tab) {
  AppTab.flow || AppTab.runs || AppTab.queue || AppTab.inbox => ProjectGroup.cycle,
  AppTab.sessions => ProjectGroup.talks,
  AppTab.prs || AppTab.reviews => ProjectGroup.prs,
  AppTab.artifacts || AppTab.adrs || AppTab.metrics => ProjectGroup.reference,
};

List<AppTab> groupTabs(ProjectGroup group) => switch (group) {
  ProjectGroup.cycle => const [AppTab.flow, AppTab.runs],
  ProjectGroup.talks => const [AppTab.sessions],
  ProjectGroup.prs => const [AppTab.prs],
  ProjectGroup.reference => const [AppTab.artifacts],
};

String subTabLabel(AppTab tab) => switch (tab) {
  AppTab.flow => 'Fluxo',
  AppTab.runs => 'Execuções',
  AppTab.prs => 'PRs',
  AppTab.reviews => 'Reviews',
  AppTab.artifacts => 'Documentos',
  AppTab.adrs => 'ADRs',
  AppTab.metrics => 'Números',
  AppTab.sessions || AppTab.inbox || AppTab.queue => tab.label,
};

AppTab? activeSubTab(AppTab tab) => switch (tab) {
  AppTab.flow ||
  AppTab.runs ||
  AppTab.sessions ||
  AppTab.prs ||
  AppTab.reviews ||
  AppTab.artifacts ||
  AppTab.adrs ||
  AppTab.metrics => tab,
  AppTab.queue => AppTab.flow,
  AppTab.inbox => null,
};
