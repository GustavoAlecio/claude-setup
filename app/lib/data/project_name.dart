/// Result of the single naming rule shared with `bin/get-project.sh`.
class ProjectName {
  const ProjectName(this.name, {this.divergence});

  final String name;

  /// Set when an older workflow dir exists under the raw basename and wins over the remote name.
  final String? divergence;
}

/// Remote name wins (`git@host:org/My_Repo.git` → `My-Repo`), else the git root basename; `_` → `-`.
/// Divergence: no workflow dir for that name but one for the raw basename → the raw basename is used.
ProjectName projectNameFor({
  required String rootBasename,
  String? remoteUrl,
  required bool Function(String name) workflowExists,
}) {
  final fromRemote = remoteUrl == null ? null : _remoteName(remoteUrl);
  final name = (fromRemote == null || fromRemote.isEmpty ? rootBasename : fromRemote).replaceAll('_', '-');
  if (name != rootBasename && !workflowExists(name) && workflowExists(rootBasename)) {
    return ProjectName(
      rootBasename,
      divergence: 'workflow existente em $rootBasename; usando $rootBasename (remote: $name)',
    );
  }
  return ProjectName(name);
}

String _remoteName(String url) {
  final last = url.substring(url.lastIndexOf(RegExp('[:/]')) + 1);
  return last.endsWith('.git') ? last.substring(0, last.length - 4) : last;
}
