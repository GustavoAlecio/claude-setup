import 'github_models.dart';
import 'github_repository.dart';

/// [prsCalls] holds the project of each `prs` call; [inboxCalls] counts `inbox` calls.
/// [prsError] and [inboxError] make the next calls throw until cleared.
class MockGitHubRepository implements GitHubRepository {
  MockGitHubRepository({this.pullRequests = const [], this.inboxData = const Inbox(items: [])});

  MockGitHubRepository.empty() : this();

  MockGitHubRepository.sample()
    : this(
        pullRequests: [
          PullRequest(
            number: 12,
            adoId: '4821',
            branch: 'feat/x',
            target: 'main',
            title: 'Adiciona filtro de partidas',
            url: 'https://github.com/acme/demo/pull/12',
            stage: 'changes_requested',
            repo: 'demo',
            nameWithOwner: 'acme/demo',
            cwd: '/tmp/demo',
            live: true,
            checks: PrChecks.failing,
            unresolved: [const ReviewThread(path: 'lib/a.dart', line: 10, author: 'rev', body: 'Extraia **isto**.')],
            updatedAt: DateTime.utc(2026, 3, 10, 12),
          ),
        ],
        inboxData: Inbox(
          login: 'me',
          items: [
            InboxItem(
              number: 7,
              title: 'Corrige cache',
              url: 'https://github.com/acme/my_repo/pull/7',
              repo: 'my_repo',
              nameWithOwner: 'acme/my_repo',
              author: 'dev',
              updatedAt: DateTime.utc(2026, 3, 10, 12),
              cwd: '/tmp/my_repo',
            ),
          ],
        ),
      );

  List<PullRequest> pullRequests;
  Inbox inboxData;
  GitHubException? prsError;
  GitHubException? inboxError;
  final prsCalls = <String>[];
  int inboxCalls = 0;

  @override
  Future<List<PullRequest>> prs(String project) async {
    prsCalls.add(project);
    final error = prsError;
    if (error != null) throw error;
    return pullRequests;
  }

  @override
  Future<Inbox> inbox() async {
    inboxCalls++;
    final error = inboxError;
    if (error != null) throw error;
    return inboxData;
  }
}
