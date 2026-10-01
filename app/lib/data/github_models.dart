enum PrChecks { failing, pending, passing }

class ReviewThread {
  const ReviewThread({this.path, this.line, this.author = '', this.body = ''});

  final String? path;
  final int? line;
  final String author;
  final String body;
}

class PullRequest {
  const PullRequest({
    this.number,
    this.adoId,
    this.branch,
    this.target,
    this.title = '',
    this.url,
    this.stage = '',
    this.openedAt,
    this.repo,
    this.nameWithOwner,
    this.cwd,
    this.cwdCandidates = const [],
    this.cwdReason,
    this.live = false,
    this.liveError,
    this.checks,
    this.unresolved = const [],
    this.updatedAt,
    this.mergedAt,
  });

  final int? number;
  final String? adoId;
  final String? branch;
  final String? target;
  final String title;
  final String? url;

  /// Raw stage: the engine's live one, or the `prs.json` one when [live] is `false`. May be unknown.
  final String stage;
  final DateTime? openedAt;
  final String? repo;
  final String? nameWithOwner;

  /// Checkout whose `origin` matches [nameWithOwner]; `null` with the reason in [cwdReason].
  final String? cwd;
  final List<String> cwdCandidates;
  final String? cwdReason;

  /// `false` when the engine could not query GitHub and fell back to `prs.json`.
  final bool live;
  final String? liveError;
  final PrChecks? checks;
  final List<ReviewThread> unresolved;
  final DateTime? updatedAt;
  final DateTime? mergedAt;
}

class InboxItem {
  const InboxItem({
    required this.number,
    this.title = '',
    this.url,
    this.repo = '',
    this.nameWithOwner = '',
    this.author = '',
    this.updatedAt,
    this.isDraft = false,
    this.cwd,
    this.cwdCandidates = const [],
    this.cwdReason,
  });

  final int number;
  final String title;
  final String? url;
  final String repo;
  final String nameWithOwner;
  final String author;
  final DateTime? updatedAt;
  final bool isDraft;
  final String? cwd;
  final List<String> cwdCandidates;
  final String? cwdReason;
}

class Inbox {
  const Inbox({required this.items, this.login});

  final List<InboxItem> items;

  /// Account the engine's `gh` is logged in as.
  final String? login;
}
