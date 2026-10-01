import 'package:flutter/widgets.dart';

import 'github_models.dart';

abstract interface class GitHubRepository {
  Future<List<PullRequest>> prs(String project);
  Future<Inbox> inbox();
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
