import 'package:claude_flow/data/github_models.dart';
import 'package:claude_flow/data/github_parser.dart';
import 'package:claude_flow/data/time_text.dart';
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
            'tracker': {'kind': 'ado', 'id': '4821', 'url': 'https://dev.azure.com/o/p/_workitems/edit/4821'},
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
      expect(pr.card?.label, 'AB#4821');
      expect(pr.card?.url, 'https://dev.azure.com/o/p/_workitems/edit/4821');
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
            'tracker': [],
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
      expect(pr.card, isNull);
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

    test('labels', () {
      expect(stageLabel('awaiting_review'), 'aguardando revisão');
      expect(stageLabel('changes_requested'), 'mudanças pedidas');
      expect(stageLabel('approved'), 'aprovado');
      expect(stageLabel('merged'), 'mergeado');
      expect(stageLabel('draft'), 'rascunho');
      expect(stageLabel('closed'), 'fechado');
      expect(stageLabel('deployed_prod'), 'publicado');
      expect(stageLabel('closed_unmerged'), 'fechado');
      expect(stageLabel('merge_ready'), 'pronto para mergear');
      expect(stageLabel('resolving'), 'resolvendo comentários');
      expect(stageLabel('mystery'), 'mystery');
    });
  });

  group('prStateLine', () {
    final now = DateTime.utc(2026, 11, 25, 12);
    PullRequest pr({
      String stage = 'awaiting_review',
      PrChecks? checks,
      int threads = 0,
      DateTime? mergedAt,
      DateTime? updatedAt,
      bool live = true,
    }) => PullRequest(
      number: 1,
      stage: stage,
      checks: checks,
      live: live,
      mergedAt: mergedAt,
      updatedAt: updatedAt,
      unresolved: [for (var i = 0; i < threads; i++) const ReviewThread(body: 'x')],
    );
    void expectLine(PullRequest p, String text, PrTone tone) {
      final line = prStateLine(p, now);
      expect(line.text, text);
      expect(line.tone, tone);
    }

    test('comments beat everything', () {
      expectLine(
        pr(stage: 'changes_requested', threads: 1, checks: PrChecks.failing),
        '1 comentário esperando você',
        PrTone.attention,
      );
      expectLine(pr(threads: 3), '3 comentários esperando você', PrTone.attention);
    });

    test('closed PRs ignore comments', () {
      expectLine(pr(stage: 'merged', threads: 2, mergedAt: now), 'mergeado agora', PrTone.done);
    });

    test('changes requested', () {
      expectLine(pr(stage: 'changes_requested'), 'mudanças pedidas', PrTone.attention);
    });

    test('approved with failing CI', () {
      expectLine(pr(stage: 'approved', checks: PrChecks.failing), 'aprovado, mas o CI falhou', PrTone.attention);
    });

    test('failing CI on an open PR, not on a closed one', () {
      expectLine(pr(checks: PrChecks.failing), 'CI falhou', PrTone.attention);
      expectLine(pr(stage: 'closed', checks: PrChecks.failing), 'fechado', PrTone.done);
      expectLine(pr(stage: 'merged', checks: PrChecks.failing), 'mergeado', PrTone.done);
    });

    test('merged ages', () {
      expectLine(pr(stage: 'merged', mergedAt: now.subtract(const Duration(days: 3))), 'mergeado há 3 d', PrTone.done);
      final old = now.subtract(const Duration(days: 40));
      expectLine(pr(stage: 'merged', mergedAt: old), 'mergeado em ${relativeAge(old, now)}', PrTone.done);
      expect(
        prStateLine(pr(stage: 'merged', mergedAt: old), now).text,
        matches(RegExp(r'^mergeado em \d{2}/\d{2}/\d{4}$')),
      );
      expectLine(
        pr(stage: 'merged', updatedAt: now.subtract(const Duration(hours: 2))),
        'mergeado há 2 h',
        PrTone.done,
      );
      expectLine(pr(stage: 'merged'), 'mergeado', PrTone.done);
    });

    test('closed and deployed', () {
      expectLine(pr(stage: 'closed_unmerged'), 'fechado', PrTone.done);
      expectLine(pr(stage: 'deployed_prod'), 'publicado', PrTone.done);
    });

    test('approved, running CI and plain stages', () {
      expectLine(pr(stage: 'approved'), 'aprovado', PrTone.normal);
      expectLine(pr(checks: PrChecks.pending), 'CI rodando', PrTone.normal);
      expectLine(pr(), 'aguardando revisão', PrTone.normal);
      expectLine(pr(stage: 'draft'), 'rascunho', PrTone.normal);
      expectLine(pr(stage: 'mystery'), 'mystery', PrTone.normal);
    });

    test('cached data adds a suffix and keeps the tone', () {
      expectLine(pr(stage: 'merge_ready', live: false), 'pronto para mergear · do cache', PrTone.normal);
      expectLine(pr(stage: 'changes_requested', live: false), 'mudanças pedidas · do cache', PrTone.attention);
    });
  });

  group('prNeedsYou', () {
    PullRequest pr(List<String?> paths, {int? number = 7}) => PullRequest(
      number: number,
      unresolved: [for (final p in paths) ReviewThread(path: p, body: 'x')],
    );
    const tail = 'O agente resolve; você confere antes do push.';

    test('title', () {
      expect(prNeedsYouTitle(pr(['a.dart'])), 'O PR #7 recebeu 1 comentário de revisão');
      expect(prNeedsYouTitle(pr(['a.dart', 'b.dart'])), 'O PR #7 recebeu 2 comentários de revisão');
      expect(prNeedsYouTitle(pr(['a.dart'], number: null)), 'O PR recebeu 1 comentário de revisão');
    });

    test('detail lists distinct file names', () {
      expect(prNeedsYouDetail(pr(['lib/a.dart'])), 'Em a.dart. $tail');
      expect(prNeedsYouDetail(pr(['a.dart', 'x/b.dart'])), 'Em a.dart e b.dart. $tail');
      expect(prNeedsYouDetail(pr(['a.dart', 'b.dart', 'c.dart'])), 'Em a.dart, b.dart e c.dart. $tail');
      expect(
        prNeedsYouDetail(pr(['a.dart', 'b.dart', 'c.dart', 'd.dart', 'e.dart'])),
        'Em a.dart, b.dart, c.dart e mais 2. $tail',
      );
      expect(prNeedsYouDetail(pr(['lib/a/index.dart', 'lib/b/index.dart'])), 'Em index.dart. $tail');
      expect(prNeedsYouDetail(pr([null, null])), tail);
      expect(prNeedsYouDetail(pr([null, 'a.dart'])), 'Em a.dart. $tail');
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

  test('card: known kind and an int or non-empty string id; anything else is null', () {
    String? card(Object? v) => parsePullRequest({'tracker': v}).card?.label;
    expect(card({'kind': 'ado', 'id': 4821}), 'AB#4821');
    expect(card({'kind': 'jira', 'id': 'LC-101'}), 'LC-101');
    expect(card({'kind': 'linear', 'id': 'BET-7', 'url': ''}), 'BET-7');
    expect(card({'kind': 'ado', 'id': ''}), isNull);
    expect(card({'kind': 'ado', 'id': 4821.0}), isNull);
    expect(card({'kind': 'trello', 'id': '1'}), isNull);
    expect(card({'kind': 'manual'}), isNull);
    expect(card(null), isNull);
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
