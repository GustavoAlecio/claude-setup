import 'github_models.dart';
import 'github_repository.dart';

/// [prsCalls] and [inboxCalls] record each call's arguments, in order. [prsError], [inboxError], [orgsError] and
/// [sshError] make the next calls throw until cleared.
class MockGitHubRepository implements GitHubRepository {
  MockGitHubRepository({
    this.pullRequests = const [],
    this.inboxData = const Inbox(items: []),
    this.accountList = const [],
    this.orgSuggestions = const {},
    this.sshIdentities = const {},
    this.gitProtocol,
  });

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
  List<GithubAccount> accountList;

  /// Suggestions by account; the `null` key answers the active account.
  Map<String?, List<String>> orgSuggestions;

  /// Identity by owner; an owner without one gets `SshIdentity(owner: o, host: 'github.com')` with no login.
  Map<String, SshIdentity> sshIdentities;
  String? gitProtocol;
  GitHubException? prsError;
  GitHubException? inboxError;
  GitHubException? orgsError;

  /// Accounts for which `orgs` throws, like the engine does for a login that is no longer in `gh`.
  Set<String?> orgsFailFor = {};
  GitHubException? sshError;
  final prsCalls = <(String project, String? account)>[];
  final inboxCalls = <(String? account, List<String> owners)>[];
  final orgsCalls = <String?>[];
  final sshCalls = <({String? owner, String? cwd, bool fresh})>[];

  @override
  Future<List<PullRequest>> prs(String project, {String? account}) async {
    prsCalls.add((project, account));
    final error = prsError;
    if (error != null) throw error;
    return pullRequests;
  }

  @override
  Future<Inbox> inbox({String? account, List<String> owners = const []}) async {
    inboxCalls.add((account, List.unmodifiable(owners)));
    final error = inboxError;
    if (error != null) throw error;
    return inboxData;
  }

  @override
  Future<List<GithubAccount>> accounts() async => accountList;

  @override
  Future<List<String>> orgs(String? account) async {
    orgsCalls.add(account);
    final error = orgsError;
    if (error != null) throw error;
    if (orgsFailFor.contains(account)) throw const GitHubException('conta não está logada no gh');
    return orgSuggestions[account] ?? const [];
  }

  @override
  Future<SshIdentity> sshIdentity({String? owner, String? cwd, bool fresh = false}) async {
    sshCalls.add((owner: owner, cwd: cwd, fresh: fresh));
    final error = sshError;
    if (error != null) throw error;
    final key = owner ?? '';
    return sshIdentities[key] ?? SshIdentity(owner: key, host: 'github.com');
  }

  @override
  Future<String?> protocol() async => gitProtocol;
}
