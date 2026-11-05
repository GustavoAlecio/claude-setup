import 'dart:convert';

import 'package:claude_flow/data/config_mutations.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/orgs.dart';
import 'package:claude_flow/data/project_name.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/engine/engine_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _orgs = [
  OrgConfig(name: 'r10', roots: ['/Users/me/development/r10']),
  OrgConfig(name: 'abm', roots: ['/Users/me/development/abm', '/Volumes/work/abm']),
];

String _identity(String p) => p;

SessionSummary _session(String project, int pending, {String? org, String? cwd, List<String> extra = const []}) =>
    SessionSummary(
      id: '$project-$org-$pending',
      project: project,
      command: '/x',
      title: '/x',
      status: SessionStatus.waitingPermission,
      createdAt: '',
      pendingPermissions: pending,
      org: org,
      cwd: cwd,
      additionalDirectories: extra,
    );

List<SessionSummary> _pending(Map<String, int> byProject) => [
  for (final e in byProject.entries) _session(e.key, e.value),
];

Map<String, dynamic> _raw() => {
  'engineDir': '/repo/engine',
  'cwds': {'alpha': '/src/alpha'},
  'unknown': {'keep': true},
  'orgs': [
    {
      'name': 'r10',
      'roots': ['/dev/r10'],
      'color': 'red',
    },
    {
      'name': 'abm',
      'roots': ['/dev/abm'],
    },
  ],
  'projects': [
    {'name': 'score', 'path': '/dev/r10/score', 'org': 'r10'},
    {'name': 'site', 'path': '/elsewhere/site', 'org': 'abm'},
  ],
  'hidden': ['old'],
  'lastOrg': 'r10',
};

void main() {
  test('parentPath drops the last segment, ignoring trailing slashes', () {
    expect(parentPath('/dev/a/alpha'), '/dev/a');
    expect(parentPath('/dev/a/alpha/'), '/dev/a');
    expect(parentPath('/dev'), '/');
    expect(parentPath('/'), '/');
  });

  group('orgHome', () {
    const config = DashboardConfig(
      orgs: [
        OrgConfig(name: 'A', roots: ['/dev/a']),
        OrgConfig(name: 'B', roots: ['/dev/b']),
        OrgConfig(name: 'C'),
      ],
    );
    const projects = [Project(name: 'a', org: 'A'), Project(name: 'h', org: 'B', hidden: true)];

    test('first visible project, else the activities of an org with roots, else null', () {
      expect(orgHome('A', projects, config), '/p/a/flow');
      expect(orgHome('B', projects, config), '/o/B/sessions');
      expect(orgHome('C', projects, config), isNull);
      expect(orgHome(kNoOrg, projects, config), isNull);
    });

    test('org locations encode each segment', () {
      expect(orgSessionsLocation('ABM Soluções'), '/o/ABM%20Solu%C3%A7%C3%B5es/sessions');
      expect(orgSessionsLocation('A', session: 's 1'), '/o/A/sessions/s%201');
    });
  });

  group('backTarget', () {
    const config = DashboardConfig(lastOrg: 'B');
    const projects = [Project(name: 'a', org: 'A'), Project(name: 'b', org: 'B'), Project(name: 'none')];

    test('project of the current org, unknown project and non-project routes stay', () {
      expect(backTarget('/p/b/runs', config, projects), '/p/b/runs');
      expect(backTarget('/p/ghost', config, projects), '/p/ghost');
      expect(backTarget('/', config, projects), '/');
    });

    test('project of another org goes to the landing', () {
      expect(backTarget('/p/a/runs', config, projects), '/');
      expect(backTarget('/p/none/runs', config, projects), '/');
    });

    test('an org route stays in its org and goes to the landing from another', () {
      expect(backTarget('/o/B/sessions', config, projects), '/o/B/sessions');
      expect(backTarget('/o/A/sessions/s1', config, projects), '/');
    });

    test('without config or projects the target is kept', () {
      expect(backTarget('/p/a/runs', null, projects), '/p/a/runs');
      expect(backTarget('/p/a/runs', config, null), '/p/a/runs');
    });
  });

  group('orgOf', () {
    test('explicit org wins over the path', () {
      expect(orgOf('/Users/me/development/r10/score', explicit: 'abm', orgs: _orgs, canonical: _identity), 'abm');
      expect(orgOf(null, explicit: 'abm', orgs: _orgs, canonical: _identity), 'abm');
      expect(orgOf('/x', explicit: kNoOrg, orgs: _orgs, canonical: _identity), kNoOrg);
    });

    test('explicit org that no longer exists falls back to the root rule', () {
      expect(orgOf('/Users/me/development/r10/score', explicit: 'gone', orgs: _orgs, canonical: _identity), 'r10');
    });

    test('root is matched by segment, first org wins', () {
      expect(orgOf('/Users/me/development/r10/score', orgs: _orgs, canonical: _identity), 'r10');
      expect(orgOf('/Users/me/development/r10/', orgs: _orgs, canonical: _identity), 'r10');
      expect(orgOf('/Volumes/work/abm/a/b/c', orgs: _orgs, canonical: _identity), 'abm');
      expect(orgOf('/Users/me/development/r10x/score', orgs: _orgs, canonical: _identity), kNoOrg);
      expect(orgOf('/Users/me/development', orgs: _orgs, canonical: _identity), kNoOrg);
    });

    test('symlinks are resolved through the injected canonical', () {
      final links = {
        '/Users/me/dev': '/Users/me/development',
        '/Users/me/dev/r10/score': '/Users/me/development/r10/score',
      };
      String canonical(String p) => links[p] ?? p;
      const orgs = [
        OrgConfig(name: 'r10', roots: ['/Users/me/dev/r10']),
      ];
      expect(orgOf('/Users/me/development/r10/score', orgs: orgs, canonical: canonical), kNoOrg);
      expect(orgOf('/Users/me/dev/r10/score', orgs: _orgs, canonical: canonical), 'r10');
    });

    test('missing root or path compares literally, without trailing slash', () {
      const orgs = [
        OrgConfig(name: 'r10', roots: ['/nope/r10/']),
      ];
      expect(orgOf('/nope/r10/score', orgs: orgs, canonical: _identity), 'r10');
      expect(orgOf('/nope/r10', orgs: orgs, canonical: _identity), 'r10');
      expect(orgOf('/nope/r10x', orgs: orgs, canonical: _identity), kNoOrg);
    });

    test('no path is Sem org', () {
      expect(orgOf(null, orgs: _orgs, canonical: _identity), kNoOrg);
      expect(orgOf('/x', orgs: const [], canonical: _identity), kNoOrg);
    });
  });

  group('resolvePath and annotateProjects', () {
    test('path precedence: registered, project_path, cwds, single scan candidate', () {
      expect(resolvePath(name: 'a', registeredPath: '/r', projectPath: '/p', cwds: {'a': '/c'}), '/r');
      expect(resolvePath(name: 'a', projectPath: '/p', cwds: {'a': '/c'}), '/p');
      expect(resolvePath(name: 'a', cwds: {'a': '/c'}), '/c');
      expect(
        resolvePath(
          name: 'a',
          scanIndex: {
            'a': [const ScanCandidate('/s/a', 1)],
          },
        ),
        '/s/a',
      );
      expect(resolvePath(name: 'a'), isNull);
    });

    test('scan candidates: the shallowest wins, a tie at the shallowest depth gives no path', () {
      expect(
        resolvePath(
          name: 'x',
          scanIndex: {
            'x': [const ScanCandidate('/root/docs/repos/x', 2), const ScanCandidate('/root/x', 0)],
          },
        ),
        '/root/x',
      );
      expect(
        resolvePath(
          name: 'x',
          scanIndex: {
            'x': [const ScanCandidate('/root/a/x', 1), const ScanCandidate('/root/b/x', 1)],
          },
        ),
        isNull,
      );
      expect(
        resolvePath(
          name: 'x',
          scanIndex: {
            'x': [
              const ScanCandidate('/root/a/x', 1),
              const ScanCandidate('/root/b/x', 1),
              const ScanCandidate('/root/c/d/x', 2),
            ],
          },
        ),
        isNull,
        reason: 'a deeper candidate never breaks a tie',
      );
    });

    test('union of workflow dirs and registered projects with org, hidden and registered', () {
      final config = DashboardConfig.fromMap(_raw());
      final projects = annotateProjects(
        const [Project(name: 'score', path: '/dev/r10/score'), Project(name: 'old'), Project(name: 'loose')],
        config,
        canonical: _identity,
        scanIndex: {
          'loose': [const ScanCandidate('/dev/abm/loose', 0)],
        },
      );
      expect(projects.map((p) => p.name), ['score', 'old', 'loose', 'site']);
      expect(projects.map((p) => p.org), ['r10', kNoOrg, 'abm', 'abm']);
      expect(projects.map((p) => p.hidden), [false, true, false, false]);
      expect(projects.map((p) => p.registered), [true, false, false, true]);
      expect(projects.map((p) => p.path), ['/dev/r10/score', null, '/dev/abm/loose', '/elsewhere/site']);
      expect(projects.last.cycle, isNull);
    });

    test('cwds give a path and therefore an org', () {
      final config = DashboardConfig.fromMap(_raw());
      final p = annotateProjects(const [Project(name: 'alpha')], config, canonical: _identity).first;
      expect(p.path, '/src/alpha');
      expect(p.org, kNoOrg);
    });

    test('projectsInOrg excludes hidden; pendingInOrg counts unknown projects only in Sem org', () {
      const projects = [
        Project(name: 'a', org: 'r10'),
        Project(name: 'b', org: 'r10', hidden: true),
        Project(name: 'c', org: 'abm'),
      ];
      expect(projectsInOrg(projects, 'r10').map((p) => p.name), ['a']);
      final pending = _pending({'a': 2, 'b': 5, 'c': 1, 'ghost': 7});
      expect(pendingInOrg(pending, projects, null, 'r10'), 2);
      expect(pendingInOrg(pending, projects, null, 'abm'), 1);
      expect(pendingInOrg(pending, projects, null, kNoOrg), 7);
    });

    test('currentOrg follows the route project and falls back to lastOrg for unknown ones', () {
      const projects = [Project(name: 'a', org: 'r10'), Project(name: 'c', org: 'abm')];
      const config = DashboardConfig(lastOrg: 'abm');
      expect(currentOrg('a', projects, config), 'r10');
      expect(currentOrg('ghost', projects, config), 'abm');
      expect(currentOrg('ghost', projects, null), kNoOrg);
    });

    test('switchableOrgs lists configured orgs and Sem org only when something lives there', () {
      const config = DashboardConfig(
        orgs: [
          OrgConfig(name: 'r10'),
          OrgConfig(name: 'abm'),
        ],
      );
      const projects = [Project(name: 'a', org: 'r10'), Project(name: 'h', hidden: true)];
      expect(switchableOrgs(config, projects, const []), ['r10', 'abm']);
      expect(switchableOrgs(config, projects, _pending({'ghost': 1})), ['r10', 'abm', kNoOrg]);
      expect(switchableOrgs(config, [...projects, const Project(name: 'loose')], const []), ['r10', 'abm', kNoOrg]);
    });
  });

  group('config mutations', () {
    List<String> keys(Map<String, dynamic> m) => m.keys.toList();

    test('createOrg appends, sets lastOrg, keeps keys and order, and leaves the input untouched', () {
      final raw = _raw();
      final before = jsonEncode(raw);
      final out = createOrg('pessoal', ['/dev/pessoal'])(raw);
      expect(jsonEncode(raw), before);
      expect(keys(out), keys(raw));
      expect((out['orgs'] as List).last, {
        'name': 'pessoal',
        'roots': ['/dev/pessoal'],
      });
      expect((out['orgs'] as List).first, {
        'name': 'r10',
        'roots': ['/dev/r10'],
        'color': 'red',
      });
      expect(out['lastOrg'], 'pessoal');
      expect(out['unknown'], {'keep': true});
    });

    test('createOrg on an empty file adds the new keys at the end', () {
      final out = createOrg('r10', ['/dev/r10'])({'engineDir': '/e'});
      expect(keys(out), ['engineDir', 'orgs', 'lastOrg']);
    });

    test('createOrg rejects Sem org, duplicates, empty names and overlapping roots', () {
      expect(() => createOrg(kNoOrg, ['/x'])(_raw()), throwsA(isA<ConfigValidationException>()));
      expect(() => createOrg('r10', ['/x'])(_raw()), throwsA(isA<ConfigValidationException>()));
      expect(() => createOrg('  ', ['/x'])(_raw()), throwsA(isA<ConfigValidationException>()));
      expect(() => createOrg('sub', ['/dev/r10/inner'])(_raw()), throwsA(isA<ConfigValidationException>()));
      expect(() => createOrg('sup', ['/dev'])(_raw()), throwsA(isA<ConfigValidationException>()));
      expect(createOrg('sib', ['/dev/r10x'])(_raw())['lastOrg'], 'sib');
    });

    test('saveOrgs with a rename rewrites projects[].org and lastOrg', () {
      final out = saveOrgs(
        const [
          OrgConfig(name: 'r10score', roots: ['/dev/r10']),
          OrgConfig(name: 'abm', roots: ['/dev/abm']),
        ],
        renames: {'r10': 'r10score'},
      )(_raw());
      expect((out['orgs'] as List).first, {
        'name': 'r10score',
        'roots': ['/dev/r10'],
        'color': 'red',
      });
      expect((out['projects'] as List).map((p) => (p as Map)['org']), ['r10score', 'abm']);
      expect(out['lastOrg'], 'r10score');
      expect(keys(out), keys(_raw()));
    });

    test('removing an org drops the explicit org of its projects and clears lastOrg', () {
      final out = removeOrg('r10')(_raw());
      expect((out['orgs'] as List).map((o) => (o as Map)['name']), ['abm']);
      final score = (out['projects'] as List).first as Map;
      expect(score.containsKey('org'), isFalse);
      expect(score['path'], '/dev/r10/score');
      expect((out['projects'] as List).last, {'name': 'site', 'path': '/elsewhere/site', 'org': 'abm'});
      expect(out.containsKey('lastOrg'), isFalse);
      final re = annotateProjects(const [], DashboardConfig.fromMap(out), canonical: _identity);
      expect(re.map((p) => (p.name, p.org)), [('score', kNoOrg), ('site', 'abm')]);
    });

    test('saveOrgs validates the new list', () {
      expect(
        () => saveOrgs(const [
          OrgConfig(name: 'a', roots: ['/x']),
          OrgConfig(name: 'a', roots: ['/y']),
        ])(_raw()),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('setLastOrg accepts orgs and Sem org only', () {
      expect(setLastOrg('abm')(_raw())['lastOrg'], 'abm');
      expect(setLastOrg(kNoOrg)(_raw())['lastOrg'], kNoOrg);
      expect(() => setLastOrg('nope')(_raw()), throwsA(isA<ConfigValidationException>()));
    });

    test('addProject appends, clears hidden and rejects duplicates by name or path', () {
      final out = addProject(name: 'old', path: '/dev/abm/old', org: 'abm')(_raw());
      expect((out['projects'] as List).last, {'name': 'old', 'path': '/dev/abm/old', 'org': 'abm'});
      expect(out['hidden'], isEmpty);
      expect(() => addProject(name: 'score', path: '/x')(_raw()), throwsA(isA<ConfigValidationException>()));
      expect(
        () => addProject(name: 'other', path: '/dev/r10/score/')(_raw()),
        throwsA(isA<ConfigValidationException>()),
      );
      expect(() => addProject(name: 'n', path: '/p', org: 'nope')(_raw()), throwsA(isA<ConfigValidationException>()));
      final noOrg = addProject(name: 'n', path: '/p')({});
      expect(noOrg, {
        'projects': [
          {'name': 'n', 'path': '/p'},
        ],
      });
    });

    test('addProject over an entry left by setProjectOrg without path merges path and keeps org', () {
      final pinned = setProjectOrg('loose', 'abm')(_raw());
      final out = addProject(name: 'loose', path: '/dev/r10/loose')(pinned);

      final entries = [
        for (final p in out['projects'] as List)
          if ((p as Map)['name'] == 'loose') p,
      ];
      expect(entries, [
        {'name': 'loose', 'org': 'abm', 'path': '/dev/r10/loose'},
      ]);
      expect(
        () => addProject(name: 'loose', path: '/elsewhere/loose')(out),
        throwsA(isA<ConfigValidationException>().having((e) => e.message, 'message', 'projeto já adicionado: "loose"')),
      );
    });

    test('setProjectOrg updates, removes or creates the entry', () {
      expect(((setProjectOrg('score', 'abm')(_raw())['projects'] as List).first as Map)['org'], 'abm');
      expect(((setProjectOrg('score', null)(_raw())['projects'] as List).first as Map).containsKey('org'), isFalse);
      final created = setProjectOrg('loose', 'r10', path: '/dev/abm/loose')(_raw());
      expect((created['projects'] as List).last, {'name': 'loose', 'path': '/dev/abm/loose', 'org': 'r10'});
      expect((created['projects'] as List).length, 3);
      expect(() => setProjectOrg('score', 'nope')(_raw()), throwsA(isA<ConfigValidationException>()));
    });

    test('hide and unhide keep a single entry per name', () {
      final hidden = hideProject('score')(hideProject('score')(_raw()));
      expect(hidden['hidden'], ['old', 'score']);
      expect(unhideProject('old')(hidden)['hidden'], ['score']);
      expect(unhideProject('x')({}).containsKey('hidden'), isFalse);
      expect(hideProject('x')({})['hidden'], ['x']);
    });
  });

  group('org github', () {
    Map<String, dynamic> withGithub() {
      final raw = _raw();
      ((raw['orgs'] as List).first as Map)['github'] = {
        'account': 'acct-a',
        'owners': ['org-x', 'bad owner'],
        'note': 'keep',
      };
      return raw;
    }

    test('updateOrg with a new name and github writes once, keeping unknown keys', () {
      const draft = OrgConfig(
        name: 'r10score',
        roots: ['/dev/r10'],
        github: OrgGithub(account: 'acct-b', owners: ['org-y', 'Org-Z']),
      );
      final raw = withGithub();
      final out = applyConfigMutation(raw, updateOrg('r10', draft))!;
      expect((out['orgs'] as List).first, {
        'name': 'r10score',
        'roots': ['/dev/r10'],
        'color': 'red',
        'github': {
          'account': 'acct-b',
          'owners': ['org-y', 'Org-Z'],
          'note': 'keep',
        },
      });
      expect((out['orgs'] as List).last, {
        'name': 'abm',
        'roots': ['/dev/abm'],
      });
      expect(out['lastOrg'], 'r10score');
      expect(out['unknown'], {'keep': true});
      expect(DashboardConfig.fromMap(out).orgs.first.github, draft.github);
    });

    test('a null draft github keeps the raw entry, invalid owners included', () {
      final out = updateOrg('r10', const OrgConfig(name: 'r10', roots: ['/dev/r10', '/vol/r10']))(withGithub());
      expect(((out['orgs'] as List).first as Map)['github'], withGithub()['orgs'][0]['github']);
    });

    test('saving another org leaves an untouched github raw', () {
      final out = updateOrg('abm', const OrgConfig(name: 'abm', roots: ['/dev/abm2']))(withGithub());
      expect(((out['orgs'] as List).first as Map)['github'], {
        'account': 'acct-a',
        'owners': ['org-x', 'bad owner'],
        'note': 'keep',
      });
    });

    test('an equal github is not rewritten, so nothing changes', () {
      const same = OrgConfig(
        name: 'r10',
        roots: ['/dev/r10'],
        github: OrgGithub(account: 'acct-a', owners: ['org-x']),
      );
      expect(applyConfigMutation(withGithub(), updateOrg('r10', same)), isNull);
    });

    test('an account that is not a login parses as null', () {
      expect(
        OrgGithub.fromRaw({
          'account': '@foo',
          'owners': ['org-x'],
        })?.account,
        isNull,
      );
      expect(OrgGithub.fromRaw({'account': 'foo', 'owners': []})?.account, 'foo');
    });

    test('validateOrgs rejects an account that is not a login', () {
      const orgs = [
        OrgConfig(
          name: 'a',
          github: OrgGithub(account: '@foo'),
        ),
      ];
      expect(validateOrgs(orgs), contains('@foo'));
    });

    test('a null account is written as null', () {
      const draft = OrgConfig(
        name: 'abm',
        roots: ['/dev/abm'],
        github: OrgGithub(owners: ['org-x']),
      );
      final out = updateOrg('abm', draft)(_raw());
      expect(((out['orgs'] as List).last as Map)['github'], {
        'account': null,
        'owners': ['org-x'],
      });
    });

    test('an invalid or case-insensitively repeated owner is a ConfigWriteException', () {
      for (final owners in [
        ['a b'],
        ['org-x', 'ORG-X'],
        ['-lead'],
      ]) {
        expect(
          () => applyConfigMutation(
            _raw(),
            updateOrg(
              'r10',
              OrgConfig(
                name: 'r10',
                github: OrgGithub(owners: owners),
              ),
            ),
          ),
          throwsA(isA<ConfigWriteException>().having((e) => e.message, 'message', contains('"r10"'))),
          reason: '$owners',
        );
      }
    });

    test('createOrg writes github only when given and validates its owners', () {
      final out = createOrg('p', ['/dev/p'], github: const OrgGithub(account: 'acct-a', owners: ['org-x']))(_raw());
      expect((out['orgs'] as List).last, {
        'name': 'p',
        'roots': ['/dev/p'],
        'github': {
          'account': 'acct-a',
          'owners': ['org-x'],
        },
      });
      expect(((createOrg('q', ['/dev/q'])(_raw())['orgs'] as List).last as Map).containsKey('github'), isFalse);
      expect(
        () => createOrg('p', ['/dev/p'], github: const OrgGithub(owners: ['x y']))(_raw()),
        throwsA(isA<ConfigValidationException>()),
      );
    });

    test('githubFor reads the org scope; Sem org, unknown and unconfigured orgs are the active account', () {
      final config = DashboardConfig.fromMap(withGithub());
      expect(githubFor('r10', config), const GithubScope(account: 'acct-a', owners: ['org-x']));
      expect(githubFor('abm', config), GithubScope.none);
      expect(githubFor(kNoOrg, config), const GithubScope());
      expect(githubFor('ghost', config), GithubScope.none);
      expect(githubFor(null, config), GithubScope.none);
      expect(githubFor('r10', null), GithubScope.none);
      expect(GithubScope.none.account, isNull);
      expect(GithubScope.none.owners, isEmpty);
    });

    test('GithubScope equality follows account and owners in order', () {
      expect(const GithubScope(account: 'a', owners: ['x', 'y']), const GithubScope(account: 'a', owners: ['x', 'y']));
      expect(
        const GithubScope(account: 'a', owners: ['x', 'y']),
        isNot(const GithubScope(account: 'a', owners: ['y', 'x'])),
      );
      expect(const GithubScope(account: 'a'), isNot(const GithubScope(account: 'b')));
    });
  });

  group('diffConfig', () {
    final base = DashboardConfig.fromMap(_raw());

    test('lastOrg, hidden and org names only re-emit', () {
      expect(diffConfig(base, DashboardConfig.fromMap(setLastOrg('abm')(_raw()))), ConfigChange.reemit);
      expect(diffConfig(base, DashboardConfig.fromMap(hideProject('score')(_raw()))), ConfigChange.reemit);
      final renamed = _raw();
      (renamed['orgs'] as List)[0] = {
        'name': 'r10score',
        'roots': ['/dev/r10'],
      };
      expect(diffConfig(base, DashboardConfig.fromMap(renamed)), ConfigChange.reemit);
      expect(diffConfig(base, DashboardConfig.fromMap(_raw())), ConfigChange.reemit);
    });

    test('renaming an org pinned by a project or re-pinning it only re-emits', () {
      final renamed = saveOrgs(
        const [
          OrgConfig(name: 'r10score', roots: ['/dev/r10']),
          OrgConfig(name: 'abm', roots: ['/dev/abm']),
        ],
        renames: {'r10': 'r10score'},
      )(_raw());
      expect((renamed['projects'] as List).first['org'], 'r10score');
      expect(diffConfig(base, DashboardConfig.fromMap(renamed)), ConfigChange.reemit);
      expect(diffConfig(base, DashboardConfig.fromMap(setProjectOrg('score', null)(_raw()))), ConfigChange.reemit);
      expect(diffConfig(base, DashboardConfig.fromMap(setProjectOrg('site', 'r10')(_raw()))), ConfigChange.reemit);
    });

    test('a different set of roots rescans; the same roots on another org do not', () {
      expect(diffConfig(base, DashboardConfig.fromMap(createOrg('p', ['/dev/p'])(_raw()))), ConfigChange.rescan);
      final moved = _raw();
      (moved['orgs'] as List)[0] = {'name': 'r10', 'roots': []};
      (moved['orgs'] as List)[1] = {
        'name': 'abm',
        'roots': ['/dev/abm/', '/dev/r10'],
      };
      expect(diffConfig(base, DashboardConfig.fromMap(moved)), ConfigChange.reemit);
    });

    test('project name/path or cwds changes reload', () {
      expect(diffConfig(base, DashboardConfig.fromMap(addProject(name: 'n', path: '/n')(_raw()))), ConfigChange.reload);
      final cwds = _raw();
      (cwds['cwds'] as Map)['beta'] = '/src/beta';
      expect(diffConfig(base, DashboardConfig.fromMap(cwds)), ConfigChange.reload);
    });
  });

  group('validateOrgs', () {
    test('accepts distinct names and disjoint roots', () {
      expect(validateOrgs(_orgs), isNull);
      expect(validateOrgs(const []), isNull);
    });

    test('rejects reserved name, duplicates, empty root and overlap in either direction', () {
      expect(validateOrgs(const [OrgConfig(name: kNoOrg)]), isNotNull);
      expect(validateOrgs(const [OrgConfig(name: 'a'), OrgConfig(name: 'a')]), isNotNull);
      expect(
        validateOrgs(const [
          OrgConfig(name: 'a', roots: ['']),
        ]),
        isNotNull,
      );
      expect(
        validateOrgs(const [
          OrgConfig(name: 'a', roots: ['/d/a']),
          OrgConfig(name: 'b', roots: ['/d/a/x']),
        ]),
        contains('sobrepõe'),
      );
      expect(
        validateOrgs(const [
          OrgConfig(name: 'a', roots: ['/d/a/x']),
          OrgConfig(name: 'b', roots: ['/d/a/']),
        ]),
        isNotNull,
      );
      expect(
        validateOrgs(const [
          OrgConfig(name: 'a', roots: ['/d/a']),
          OrgConfig(name: 'b', roots: ['/d/ab']),
        ]),
        isNull,
      );
    });

    test('rejects a slash in the name, which would break the /o/<org> route', () {
      expect(validateOrgs(const [OrgConfig(name: 'r10/app')]), 'o nome da org não pode ter "/"');
      expect(validateOrgs(const [OrgConfig(name: 'ABM Soluções')]), isNull);
    });

    test('validates github owners by login format and case-insensitive duplicates', () {
      expect(
        validateOrgs(const [
          OrgConfig(
            name: 'a',
            github: OrgGithub(owners: ['org-x', 'Org-Y']),
          ),
        ]),
        isNull,
      );
      expect(
        validateOrgs(const [
          OrgConfig(
            name: 'a',
            github: OrgGithub(owners: ['a b']),
          ),
        ]),
        'org do GitHub inválida: "a b" em "a"',
      );
      expect(
        validateOrgs(const [
          OrgConfig(
            name: 'a',
            github: OrgGithub(owners: ['org-x', 'ORG-x']),
          ),
        ]),
        'org do GitHub repetida: "ORG-x" em "a"',
      );
      expect(validateOwners(['a' * 39]), isNull);
      expect(validateOwners(['a' * 40]), isNotNull);
    });
  });

  group('org sessions', () {
    const otg = OrgConfig(name: 'OTG', roots: ['/dev/otg', '/vol/otg']);
    const projects = [Project(name: 'a', org: 'OTG')];
    final activity = _session('', 1, org: 'OTG', cwd: '/dev/otg', extra: ['/vol/otg']);

    test('a pending org session counts in its org and never in Sem org', () {
      const config = DashboardConfig(orgs: [otg]);
      final sessions = [_session('a', 1), activity];
      expect(sessionOrg(activity, projects, config), 'OTG');
      expect(pendingInOrg(sessions, projects, config, 'OTG'), 2);
      expect(pendingInOrg(sessions, projects, config, kNoOrg), 0);
      expect(switchableOrgs(config, projects, sessions), ['OTG']);
    });

    test('a renamed org keeps the session through its cwd; a removed org leaves it in Sem org', () {
      const renamed = DashboardConfig(
        orgs: [
          OrgConfig(name: 'R10', roots: ['/dev/otg', '/vol/otg']),
        ],
      );
      const renamedProjects = [Project(name: 'a', org: 'R10')];
      expect(sessionOrg(activity, renamedProjects, renamed), 'R10');
      expect(pendingInOrg([activity], renamedProjects, renamed, 'R10'), 1);

      const removed = DashboardConfig(
        orgs: [
          OrgConfig(name: 'abm', roots: ['/dev/abm']),
        ],
      );
      const loose = [Project(name: 'a')];
      expect(sessionOrg(activity, loose, removed), kNoOrg);
      expect(pendingInOrg([activity], loose, removed, kNoOrg), 1);
      expect(switchableOrgs(removed, const [], [activity]), ['abm', kNoOrg]);
    });

    test('project sessions keep their rule: unknown project in Sem org, hidden project in none', () {
      const config = DashboardConfig(orgs: [otg]);
      const withHidden = [...projects, Project(name: 'h', org: 'OTG', hidden: true)];
      expect(sessionOrg(_session('a', 0), withHidden, config), 'OTG');
      expect(sessionOrg(_session('ghost', 0), withHidden, config), kNoOrg);
      expect(sessionOrg(_session('h', 0), withHidden, config), isNull);
    });

    test('routeOrg reads the project org under /p/ and the name under /o/', () {
      expect(routeOrg('/p/a/flow', projects), 'OTG');
      expect(routeOrg('/p/a', projects), 'OTG');
      expect(routeOrg('/p/ghost/flow', projects), isNull);
      expect(routeOrg('/o/x/sessions', projects), 'x');
      expect(routeOrg('/o/x', projects), 'x');
      expect(routeOrg('/o/ABM%20Solu%C3%A7%C3%B5es/sessions/s1', projects), 'ABM Soluções');
      expect(routeOrg('/', projects), isNull);
      expect(routeOrg('/settings', projects), isNull);
    });

    test('orgSessionDirs is the first root plus the others in config order', () {
      final (cwd, additional) = orgSessionDirs(otg)!;
      expect(cwd, '/dev/otg');
      expect(additional, ['/vol/otg']);
      final (single, none) = orgSessionDirs(const OrgConfig(name: 'one', roots: ['/dev/one']))!;
      expect(single, '/dev/one');
      expect(none, isEmpty);
      expect(orgSessionDirs(const OrgConfig(name: 'none')), isNull);
    });
  });

  group('shell helpers', () {
    const projects = [Project(name: 'a', org: 'r10'), Project(name: 'z')];
    const config = DashboardConfig(orgs: _orgs, lastOrg: 'abm');

    test('isShellLocation accepts only /p/<x> and /o/<x> routes', () {
      expect(isShellLocation('/p/a/flow'), isTrue);
      expect(isShellLocation('/p/a'), isTrue);
      expect(isShellLocation('/o/Sem%20org/sessions'), isTrue);
      expect(isShellLocation('/'), isFalse);
      expect(isShellLocation('/p'), isFalse);
      expect(isShellLocation('/settings'), isFalse);
      expect(isShellLocation('/about'), isFalse);
    });

    test('orgConfigOf finds a configured org only', () {
      expect(orgConfigOf(config, 'abm')?.roots, hasLength(2));
      expect(orgConfigOf(config, kNoOrg), isNull);
      expect(orgConfigOf(config, 'gone'), isNull);
      expect(orgConfigOf(null, 'abm'), isNull);
    });

    test('paletteOrg: route org in the shell, unknown project keeps lastOrg, landing org on /', () {
      expect(paletteOrg('/p/a/flow', config, projects), 'r10');
      expect(paletteOrg('/p/ghost/flow', config, projects), 'abm');
      expect(paletteOrg('/o/r10/sessions', config, projects), 'r10');
      expect(paletteOrg('/o/Sem%20org/sessions', config, projects), kNoOrg);
      expect(paletteOrg('/', config, projects), 'abm');
      expect(paletteOrg('/?org=r10', config, projects), 'abm');
      expect(paletteOrg('/', const DashboardConfig(orgs: _orgs), projects), isNull);
      expect(paletteOrg('/settings', config, projects), isNull);
      expect(paletteOrg('/about', config, projects), isNull);
    });

    test('firstPendingInOrg points at the project or at the org activities', () {
      final sessions = [
        _session('a', 0),
        _session('a', 2),
        _session('', 1, org: 'abm', cwd: '/dev/abm'),
        _session('', 3, org: 'removed', cwd: '/nowhere'),
        _session('ghost', 1),
      ];
      expect(firstPendingInOrg(sessions, projects, config, 'r10'), (name: 'a', location: '/p/a/sessions'));
      expect(firstPendingInOrg(sessions, projects, config, 'abm'), (name: 'abm', location: '/o/abm/sessions'));
      expect(firstPendingInOrg(sessions, projects, config, kNoOrg), (name: kNoOrg, location: '/o/Sem%20org/sessions'));
      expect(firstPendingInOrg([_session('ghost', 1)], projects, config, kNoOrg)?.name, 'ghost');
      expect(firstPendingInOrg(sessions, projects, config, 'gone'), isNull);
    });
  });

  group('landingFor', () {
    const projects = [Project(name: 'a', org: 'r10'), Project(name: 'z')];

    test('no orgs → create org, regardless of lastOrg', () {
      expect(landingFor(const DashboardConfig(lastOrg: 'r10'), projects, const []), isA<CreateOrgLanding>());
    });

    test('valid lastOrg opens directly', () {
      expect(
        landingFor(const DashboardConfig(orgs: _orgs, lastOrg: 'abm'), projects, const []),
        isA<OpenOrgLanding>().having((l) => l.org, 'org', 'abm'),
      );
      expect(
        landingFor(const DashboardConfig(orgs: _orgs, lastOrg: kNoOrg), projects, const []),
        isA<OpenOrgLanding>().having((l) => l.org, 'org', kNoOrg),
      );
    });

    test('missing or invalid lastOrg offers the orgs, plus Sem org only when it has visible projects', () {
      expect(
        landingFor(const DashboardConfig(orgs: _orgs), projects, const []),
        isA<ChooseOrgLanding>().having((l) => l.options, 'options', ['r10', 'abm', kNoOrg]),
      );
      expect(
        landingFor(const DashboardConfig(orgs: _orgs, lastOrg: 'gone'), const [
          Project(name: 'z', hidden: true),
        ], const []),
        isA<ChooseOrgLanding>().having((l) => l.options, 'options', ['r10', 'abm']),
      );
      expect(
        landingFor(const DashboardConfig(orgs: _orgs, lastOrg: kNoOrg), const [], const []),
        isA<ChooseOrgLanding>(),
      );
    });

    test('a pending session of an unknown project offers Sem org exactly like switchableOrgs', () {
      const visible = [Project(name: 'a', org: 'r10'), Project(name: 'h', hidden: true)];
      const config = DashboardConfig(orgs: _orgs, lastOrg: kNoOrg);

      for (final pending in [
        const <SessionSummary>[],
        _pending({'h': 2}),
        _pending({'a': 3}),
      ]) {
        expect(
          landingFor(config, visible, pending),
          isA<ChooseOrgLanding>().having((l) => l.options, 'options', switchableOrgs(config, visible, pending)),
          reason: pending.map((s) => s.project).join(','),
        );
      }
      expect(switchableOrgs(config, visible, _pending({'ghost': 1})), contains(kNoOrg));
      expect(
        landingFor(config, visible, _pending({'ghost': 1})),
        isA<OpenOrgLanding>().having((l) => l.org, 'org', kNoOrg),
      );
    });
  });

  group('DashboardConfig.parse with orgs', () {
    OrgGithub? githubOf(Object? github) => DashboardConfig.fromMap({
      'orgs': [
        {'name': 'o', 'github': github},
      ],
    }).orgs.single.github;

    test('github absent, partial and invalid', () {
      expect(githubOf(null), isNull);
      expect(githubOf('acct-a'), isNull);
      expect(githubOf(['acct-a']), isNull);
      final partial = githubOf({'account': 'acct-a'})!;
      expect(partial, const OrgGithub(account: 'acct-a'));
      expect(
        githubOf({
          'owners': ['org-x'],
        }),
        const OrgGithub(owners: ['org-x']),
      );
      expect(githubOf({'account': '', 'owners': 'org-x'}), const OrgGithub());
      expect(githubOf({'account': 3, 'owners': null}), const OrgGithub());
      expect(
        githubOf({
          'account': 'acct-b',
          'owners': ['org-x', 'a b', 7, '', 'ORG-X', '-x', 'org-y'],
        }),
        const OrgGithub(account: 'acct-b', owners: ['org-x', 'org-y']),
      );
    });

    test('reads orgs, projects, hidden and lastOrg, skipping invalid entries', () {
      final config = DashboardConfig.parse(
        jsonEncode({
          'orgs': [
            {
              'name': 'r10',
              'roots': ['/dev/r10', 3],
            },
            {
              'roots': ['/x'],
            },
            'junk',
          ],
          'projects': [
            {'name': 'score', 'path': '/dev/r10/score', 'org': 'r10'},
            {'name': 'bare'},
            {'path': '/no/name'},
          ],
          'hidden': ['old', 1, ''],
          'lastOrg': kNoOrg,
        }),
      );
      expect(config.orgs.single.name, 'r10');
      expect(config.orgs.single.roots, ['/dev/r10']);
      expect(config.projects.map((p) => (p.name, p.path, p.org)), [
        ('score', '/dev/r10/score', 'r10'),
        ('bare', null, null),
      ]);
      expect(config.hidden, ['old']);
      expect(config.lastOrg, kNoOrg);
      expect(config.orgs.single.github, isNull);
      final empty = DashboardConfig.parse('{}');
      expect(empty.orgs, isEmpty);
      expect(empty.projects, isEmpty);
      expect(empty.hidden, isEmpty);
      expect(empty.lastOrg, isNull);
    });
  });

  group('projectNameFor', () {
    bool none(String _) => false;

    test('remote name without .git, underscores to dashes', () {
      expect(
        projectNameFor(rootBasename: 'my_repo', remoteUrl: 'git@host:org/My_Repo.git', workflowExists: none).name,
        'My-Repo',
      );
      expect(
        projectNameFor(rootBasename: 'x', remoteUrl: 'https://host/org/repo.git', workflowExists: none).name,
        'repo',
      );
      expect(projectNameFor(rootBasename: 'x', remoteUrl: 'https://host/org/repo', workflowExists: none).name, 'repo');
    });

    test('no remote uses the root basename', () {
      expect(projectNameFor(rootBasename: 'my_repo', workflowExists: none).name, 'my-repo');
      expect(projectNameFor(rootBasename: 'my_repo', remoteUrl: '', workflowExists: none).name, 'my-repo');
    });

    test('divergence: existing workflow dir under the raw basename wins and is reported', () {
      final r = projectNameFor(
        rootBasename: 'local_name',
        remoteUrl: 'git@host:org/remote-name.git',
        workflowExists: (n) => n == 'local_name',
      );
      expect(r.name, 'local_name');
      expect(r.divergence, 'workflow existente em local_name; usando local_name (remote: remote-name)');
      final both = projectNameFor(
        rootBasename: 'local_name',
        remoteUrl: 'git@host:org/remote-name.git',
        workflowExists: (n) => n == 'local_name' || n == 'remote-name',
      );
      expect((both.name, both.divergence), ('remote-name', null));
    });
  });
}
