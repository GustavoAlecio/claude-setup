import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_parser.dart';
import 'package:claude_flow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

PullRequest _pr({
  String stage = 'awaiting_review',
  int threads = 0,
  String? repo,
  String? cwd,
  List<String> candidates = const [],
  String? reason,
}) => PullRequest(
  number: 1,
  stage: stage,
  repo: repo,
  cwd: cwd,
  cwdCandidates: candidates,
  cwdReason: reason,
  unresolved: [for (var i = 0; i < threads; i++) const ReviewThread(body: 'x')],
);

void main() {
  group('parsePullRequests', () {
    test('full entry', () {
      final prs = parsePullRequests({
        'prs': [
          {
            'pr_number': 12,
            'ado_id': 4821,
            'branch': 'feat/x',
            'target': 'main',
            'title': 'T',
            'url': 'https://github.com/o/r/pull/12',
            'stage': 'approved',
            'opened_at': '2026-03-01T10:00:00Z',
            'repo': 'r',
            'nameWithOwner': 'o/r',
            'cwd': '/tmp/r',
            'cwdCandidates': ['/tmp/r', 3],
            'cwdReason': null,
            'live': true,
            'checks': 'failing',
            'unresolved': [
              {'path': 'a.dart', 'line': 3, 'author': 'bob', 'body': 'fix'},
            ],
            'updatedAt': '2026-03-02T10:00:00Z',
            'mergedAt': null,
          },
        ],
      });
      final pr = prs.single;
      expect(pr.number, 12);
      expect(pr.adoId, '4821');
      expect(pr.checks, PrChecks.failing);
      expect(pr.cwdCandidates, ['/tmp/r']);
      expect(pr.live, isTrue);
      expect(pr.unresolved.single.path, 'a.dart');
      expect(pr.unresolved.single.line, 3);
      expect(pr.updatedAt, DateTime.utc(2026, 3, 2, 10));
      expect(pr.mergedAt, isNull);
    });

    test('missing and wrongly typed fields do not throw', () {
      final prs = parsePullRequests({
        'prs': [
          {
            'pr_number': '7',
            'ado_id': [],
            'title': 5,
            'stage': null,
            'checks': 'weird',
            'unresolved': 'no',
            'updatedAt': 'not a date',
            'live': 'yes',
            'cwdCandidates': 'x',
          },
          'junk',
          {},
        ],
      });
      expect(prs, hasLength(2));
      final pr = prs.first;
      expect(pr.number, isNull);
      expect(pr.adoId, isNull);
      expect(pr.title, '');
      expect(pr.stage, '');
      expect(pr.checks, isNull);
      expect(pr.unresolved, isEmpty);
      expect(pr.updatedAt, isNull);
      expect(pr.live, isFalse);
      expect(pr.cwdCandidates, isEmpty);
    });

    test('non-object bodies give an empty list', () {
      expect(parsePullRequests(null), isEmpty);
      expect(parsePullRequests([]), isEmpty);
      expect(parsePullRequests({'prs': 'x'}), isEmpty);
    });

    test('thread with wrong types', () {
      final t = parseReviewThread({'path': 1, 'line': '3', 'author': null, 'body': 2});
      expect(t.path, isNull);
      expect(t.line, isNull);
      expect(t.author, '');
      expect(t.body, '');
      expect(parseReviewThread('x').body, '');
    });
  });

  group('parseInbox', () {
    test('items and login', () {
      final inbox = parseInbox({
        'login': 'me',
        'items': [
          {
            'number': 7,
            'title': 'T',
            'url': 'https://github.com/o/my_repo/pull/7',
            'repo': 'my_repo',
            'nameWithOwner': 'o/my_repo',
            'author': 'dev',
            'updatedAt': '2026-03-02T10:00:00Z',
            'isDraft': true,
            'cwd': null,
            'cwdCandidates': ['/a', '/b'],
            'cwdReason': 'checkout ambíguo (2 cópias)',
          },
        ],
      });
      expect(inbox.login, 'me');
      final item = inbox.items.single;
      expect(item.isDraft, isTrue);
      expect(item.cwd, isNull);
      expect(item.cwdCandidates, ['/a', '/b']);
      expect(item.cwdReason, contains('ambíguo'));
    });

    test('drops items without integer number and tolerates wrong types', () {
      final inbox = parseInbox({
        'login': 3,
        'items': [
          {'number': '1'},
          {'number': 2, 'title': 9, 'repo': null, 'isDraft': 'true', 'updatedAt': 5},
          null,
        ],
      });
      expect(inbox.login, isNull);
      expect(inbox.items.map((i) => i.number), [2]);
      expect(inbox.items.single.title, '');
      expect(inbox.items.single.isDraft, isFalse);
      expect(parseInbox('x').items, isEmpty);
      expect(parseInbox({'items': 'x'}).items, isEmpty);
    });
  });

  group('relativeAge', () {
    final now = DateTime.utc(2026, 3, 10, 12);

    test('null is a dash', () => expect(relativeAge(null, now), '—'));

    test('boundaries', () {
      expect(relativeAge(now.subtract(const Duration(seconds: 59)), now), 'agora');
      expect(relativeAge(now.add(const Duration(minutes: 5)), now), 'agora');
      expect(relativeAge(now.subtract(const Duration(seconds: 60)), now), 'há 1 min');
      expect(relativeAge(now.subtract(const Duration(minutes: 59, seconds: 59)), now), 'há 59 min');
      expect(relativeAge(now.subtract(const Duration(minutes: 60)), now), 'há 1 h');
      expect(relativeAge(now.subtract(const Duration(hours: 23, minutes: 59)), now), 'há 23 h');
      expect(relativeAge(now.subtract(const Duration(hours: 24)), now), 'há 1 d');
      expect(relativeAge(now.subtract(const Duration(days: 29, hours: 23)), now), 'há 29 d');
    });

    test('30 days or more is a date', () {
      final then = DateTime(2026, 2, 8, 12);
      final text = relativeAge(then, DateTime(2026, 3, 10, 12));
      expect(text, '08/02/2026');
    });
  });

  group('stage', () {
    test('isClosedStage', () {
      for (final s in ['merged', 'closed', 'closed_abandoned', 'deployed_prod']) {
        expect(isClosedStage(s), isTrue, reason: s);
      }
      for (final s in ['draft', 'approved', 'awaiting_review', 'changes_requested', 'whatever', '']) {
        expect(isClosedStage(s), isFalse, reason: s);
      }
    });

    test('canResolve needs open threads and an open PR', () {
      expect(canResolve(_pr(stage: 'changes_requested', threads: 1)), isTrue);
      expect(canResolve(_pr(stage: 'approved', threads: 2)), isTrue);
      expect(canResolve(_pr(stage: 'draft', threads: 1)), isTrue);
      expect(canResolve(_pr(stage: 'mystery', threads: 1)), isTrue);
      expect(canResolve(_pr(stage: 'merged', threads: 1)), isFalse);
      expect(canResolve(_pr(stage: 'closed', threads: 1)), isFalse);
      expect(canResolve(_pr(stage: 'deployed_prod', threads: 1)), isFalse);
      expect(canResolve(_pr(stage: 'changes_requested')), isFalse);
    });

    test('labels and roles', () {
      expect(stageLabel('awaiting_review'), 'aguardando review');
      expect(stageLabel('changes_requested'), 'mudanças pedidas');
      expect(stageLabel('approved'), 'aprovado');
      expect(stageLabel('merged'), 'mergeado');
      expect(stageLabel('draft'), 'rascunho');
      expect(stageLabel('closed'), 'fechado');
      expect(stageLabel('deployed_prod'), 'deployed_prod');
      expect(stageColorRole('awaiting_review'), StageColorRole.accent);
      expect(stageColorRole('changes_requested'), StageColorRole.warn);
      expect(stageColorRole('approved'), StageColorRole.pass);
      expect(stageColorRole('merged'), StageColorRole.pass);
      expect(stageColorRole('draft'), StageColorRole.idle);
      expect(stageColorRole('closed'), StageColorRole.idle);
      expect(stageColorRole('deployed_prod'), StageColorRole.idle);
    });
  });

  group('prCwd / inboxCwd', () {
    test('known project path counts only when it is the cwd the engine validated', () {
      final projects = [const Project(name: 'a', path: '/work/a/')];
      expect(prCwd(_pr(repo: 'a', cwd: '/work/a'), projects), '/work/a/');
      expect(prCwd(_pr(repo: 'a', cwd: '/scan/a'), projects), '/scan/a');
    });

    test('remote still applies to the app path: known path among the candidates is not used', () {
      final projects = [const Project(name: 'api', path: '/x/api')];
      const reason = '/x/api aponta para clienta/api';
      expect(prCwd(_pr(repo: 'api', candidates: const ['/x/api'], reason: reason), projects), isNull);
      const item = InboxItem(
        number: 7,
        repo: 'api',
        nameWithOwner: 'otherorg/api',
        cwdCandidates: ['/x/api'],
        cwdReason: reason,
      );
      expect(inboxCwd(item, projects), isNull);
      final ambiguous = _pr(repo: 'api', candidates: const ['/x/api', '/y/api'], reason: 'checkout ambíguo (2 cópias)');
      expect(prCwd(ambiguous, projects), isNull);
    });

    test('falls back to the engine cwd', () {
      final projects = [const Project(name: 'a'), const Project(name: 'b', path: '/work/b')];
      expect(prCwd(_pr(repo: 'a', cwd: '/scan/a'), projects), '/scan/a');
      expect(prCwd(_pr(repo: 'zzz', cwd: '/scan/z'), projects), '/scan/z');
      expect(prCwd(_pr(repo: 'zzz'), projects), isNull);
      expect(prCwd(_pr(), projects), isNull);
    });

    test('underscore repo matches the dashed project', () {
      final projects = [const Project(name: 'my-repo', path: '/work/my-repo/')];
      expect(prCwd(_pr(repo: 'my_repo', cwd: '/work/my-repo'), projects), '/work/my-repo/');
    });
  });

  test('adoId: int or non-empty string; empty, double and others are null', () {
    String? ado(Object? v) => parsePullRequest({'ado_id': v}).adoId;
    expect(ado(4821), '4821');
    expect(ado('4821'), '4821');
    expect(ado(''), isNull);
    expect(ado(4821.0), isNull);
    expect(ado(null), isNull);
  });

  group('repoLabel', () {
    test('short repo while every row shares the owner', () {
      final all = [('a', 'acme/a'), ('b', 'acme/b')];
      expect(repoLabel('a', 'acme/a', all), 'a');
      expect(repoLabel('b', 'acme/b', all), 'b');
    });

    test('owner differing from the first row shows owner/repo', () {
      final all = [('a', 'acme/a'), ('b', 'other/b')];
      expect(repoLabel('b', 'other/b', all), 'other/b');
    });

    test('same repo under two owners shows both in full', () {
      final all = [('a', 'acme/a'), ('a', 'fork/a')];
      expect(repoLabel('a', 'acme/a', all), 'acme/a');
      expect(repoLabel('a', 'fork/a', all), 'fork/a');
    });

    test('missing nameWithOwner falls back to repo, then a dash', () {
      expect(repoLabel('a', null, const [('a', null)]), 'a');
      expect(repoLabel('a', '', const [('a', '')]), 'a');
      expect(repoLabel('', '', const [('', '')]), '—');
      expect(repoLabel(null, 'o/r', const [(null, 'o/r')]), 'o/r');
    });
  });

  group('inboxFooter', () {
    test('missing and ambiguous checkouts', () {
      const items = [
        InboxItem(number: 1, repo: 'a', cwd: '/tmp/a'),
        InboxItem(number: 2, repo: 'b'),
        InboxItem(number: 3, repo: 'b'),
        InboxItem(number: 4, repo: 'c', cwdCandidates: ['/c1', '/c2']),
      ];
      final footer = inboxFooter(items, const []);
      expect(footer.missing, ['b']);
      expect(footer.ambiguous, [('c', 2)]);
    });
  });

  group('reviewProjectName', () {
    InboxItem item({String? cwd, String repo = 'my_repo'}) =>
        InboxItem(number: 7, repo: repo, nameWithOwner: 'org/$repo', cwd: cwd);

    test('no known project: repo name with dashes', () {
      expect(reviewProjectName(item(), const []), 'my-repo');
      expect(reviewProjectName(item(cwd: '/tmp/my_repo'), const []), 'my-repo');
    });

    test('known project by path', () {
      final projects = [const Project(name: 'custom-name', path: '/work/mine/')];
      expect(reviewProjectName(item(cwd: '/work/mine'), projects), 'custom-name');
    });

    test('canonical comparison resolves aliases', () {
      final projects = [const Project(name: 'real', path: '/alias/r')];
      String canonical(String p) => p.replaceFirst('/alias', '/real');
      expect(
        reviewProjectName(
          item(cwd: '/real/r', repo: 'other'),
          projects,
          canonical: canonical,
        ),
        'real',
      );
    });

    test('raw basename wins when only its workflow exists', () {
      final name = reviewProjectName(item(cwd: '/tmp/my_repo'), const [], workflowExists: (n) => n == 'my_repo');
      expect(name, 'my_repo');
    });
  });

  group('account routes', () {
    test('parseAccounts keeps flags and drops entries without a login', () {
      final accounts = parseAccounts({
        'accounts': [
          {'login': 'acct-a', 'active': true, 'valid': true},
          {'login': 'acct-b'},
          {'active': true},
          {'login': ''},
          'junk',
        ],
      });
      expect(
        [for (final a in accounts) (a.login, a.active, a.valid)],
        [('acct-a', true, true), ('acct-b', false, false)],
      );
      expect(parseAccounts(null), isEmpty);
      expect(parseAccounts({'accounts': 'x'}), isEmpty);
    });

    test('parseOrgs keeps the order and drops non-strings', () {
      expect(
        parseOrgs({
          'login': 'acct-a',
          'orgs': ['acct-a', 'org-x', 3, ''],
        }),
        ['acct-a', 'org-x'],
      );
      expect(parseOrgs([]), isEmpty);
      expect(parseOrgs({'orgs': null}), isEmpty);
    });

    test('parseSshIdentity reads login or error and falls back to the asked owner', () {
      final ok = parseSshIdentity({'owner': 'org-x', 'host': 'github.com-alias', 'login': 'acct-b'}, owner: 'org-x');
      expect((ok.owner, ok.host, ok.login, ok.error), ('org-x', 'github.com-alias', 'acct-b', null));
      final https = parseSshIdentity({
        'owner': 'org-y',
        'host': null,
        'login': null,
        'error': 'remote https: identidade definida pelo credential helper, não verificável',
      }, owner: 'org-y');
      expect((https.host, https.login), (null, null));
      expect(https.error, startsWith('remote https'));
      final broken = parseSshIdentity('junk', owner: 'org-z');
      expect((broken.owner, broken.host, broken.login, broken.error), ('org-z', null, null, null));
    });

    test('parseProtocol is null when unset or malformed', () {
      expect(parseProtocol({'protocol': 'https'}), 'https');
      expect(parseProtocol({'protocol': null}), isNull);
      expect(parseProtocol({'protocol': ''}), isNull);
      expect(parseProtocol(null), isNull);
    });
  });
}
