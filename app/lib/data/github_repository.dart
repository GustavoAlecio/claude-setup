import 'package:flutter/widgets.dart';

import 'github_models.dart';

/// [account] `null` everywhere means the `gh` active account.
abstract interface class GitHubRepository {
  Future<List<PullRequest>> prs(String project, {String? account});

  /// [owners] empty: no `--owner` filter.
  Future<Inbox> inbox({String? account, List<String> owners = const []});
  Future<List<GithubAccount>> accounts();

  /// Owner suggestions for [account]: its login, then its organizations.
  Future<List<String>> orgs(String? account);

  /// Exactly one of [owner] and [cwd]; [fresh] skips the engine's cache.
  Future<SshIdentity> sshIdentity({String? owner, String? cwd, bool fresh = false});

  /// `gh config get git_protocol -h github.com`; `null` when unset.
  Future<String?> protocol();
}

class GitHubException implements Exception {
  const GitHubException(this.message);

  /// Engine error text, shown to the user as is.
  final String message;

  @override
  String toString() => message;
}

class GitHubScope extends InheritedWidget {
  const GitHubScope({super.key, required this.repository, required super.child});

  final GitHubRepository repository;

  static GitHubRepository of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GitHubScope>()!.repository;

  @override
  bool updateShouldNotify(GitHubScope oldWidget) => repository != oldWidget.repository;
}
