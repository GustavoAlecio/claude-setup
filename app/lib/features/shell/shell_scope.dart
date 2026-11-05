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
