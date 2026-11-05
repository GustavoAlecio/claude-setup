import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/workflow_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

Map<String, dynamic> _entry(
  String role,
  String task,
  int attempt,
  String verdict, {
  Object? tier,
  int? tokens,
  List? findings,
  int? round,
}) => {
  'role': role,
  'task': task,
  'attempt': attempt,
  'tier': tier ?? 'haiku',
  'verdict': verdict,
  'blocking': [],
  'findings': findings ?? [],
  'tokens_out': ?tokens,
  'round': ?round,
};

void main() {
  group('stageOf', () {
    const table = {
      'triaged': Stage.kickoff,
      'specifying': Stage.specify,
      'spec_approved': Stage.challenge,
      'planning': Stage.plan,
      'plan_approved': Stage.plan,
      'tasking': Stage.tasks,
      'implementing': Stage.implement,
      'implemented': Stage.implement,
      'verifying': Stage.verify,
      'verified': Stage.complete,
      'completed': Stage.complete,
    };
    for (final e in table.entries) {
      test('${e.key} -> ${e.value.name}', () => expect(stageOf(e.key, false, {}), e.value));
    }

    test('spec_approved with challenge goes to plan', () => expect(stageOf('spec_approved', true, {}), Stage.plan));

    test('unknown status falls back to last stage with end', () {
      final phases = {
        'specify': {'start': '2026-03-10T09:00:00Z', 'end': '2026-03-10T09:12:00Z'},
        'plan': {'start': '2026-03-10T09:20:00Z'},
      };
      expect(stageOf('weird', false, phases), Stage.specify);
      expect(stageOf(null, false, {}), Stage.kickoff);
    });

    test('minutes only for stages with end', () {
      final phases = {
        'specify': {'start': '2026-03-10T09:00:00Z', 'end': '2026-03-10T09:12:00Z'},
        'plan': {'start': '2026-03-10T09:20:00Z'},
      };
      expect(stageMinutes(phases), {Stage.specify: 12});
    });

    test('parseCycle maps tracker, feature fallback and nullable branch', () {
      final c = parseCycle({'status': 'planning', 'ado_id': 1001, 'phases': {}}, projectName: 'p', branch: '');
      expect(c.feature, 'p');
      expect(c.tracker, '#1001');
      expect(c.branch, isNull);
      expect(c.stage, Stage.plan);
      final l = parseCycle(
        {'status': 'planning', 'linear_key': 'BET-7', 'feature': 'F'},
        projectName: 'p',
        branch: 'main',
      );
      expect(l.tracker, 'BET-7');
      expect(l.feature, 'F');
      expect(l.branch, 'main');
      expect(parseCycle({'status': 'planning'}, projectName: 'p').tracker, isNull);
    });
  });

  group('parseResultRun', () {
    final now = DateTime.utc(2026, 3, 10, 12);
    final g1Finding = {
      'id': 'G1-ARCH-LAYER',
      'severity': 'critical',
      'file': 'lib/a.dart',
      'message': 'm',
      'line': 0,
      'rule_ref': 'flutter-app/estado',
    };

    final result = {
      'status': 'blocked',
      'blocked_task': 'T2',
      'reason': 'same_failure_across_tiers',
      'diagnosis': [
        {
          'lens': 'a',
          'hypothesis': 'h1',
          'confidence': 0.3,
          'evidence': ['e'],
          'recommended_action': 'act1',
        },
        {'lens': 'b', 'hypothesis': 'h2', 'confidence': 0.8, 'evidence': [], 'recommended_action': 'act2'},
      ],
      'tasks': [
        {
          'id': 'T1',
          'complexity': 'S',
          'risk': 'low',
          'tier0': 'haiku',
          'status': 'done',
          'files_changed': ['a.dart'],
          'summary': 'ok',
        },
        {
          'id': 'T2',
          'complexity': 'L',
          'risk': 'high',
          'tier0': 'haiku',
          'status': 'blocked',
          'summary': 'ultima',
          'escalations': [
            {'from': 'haiku', 'to': 'sonnet', 'at_attempt': 2},
          ],
        },
        {'id': 'T3', 'status': 'pending'},
      ],
      'trace': [
        _entry('dev', 'T1', 1, 'done', tokens: 100),
        _entry('g0', 'T1', 1, 'pass', tokens: 10),
        _entry('ops', 'T1', 1, 'ok', tokens: 5),
        _entry('dev', 'T2', 1, 'done', tokens: 200),
        _entry(
          'g0',
          'T2',
          1,
          'fail',
          tokens: 20,
          findings: [
            {'id': 'X', 'severity': 'major', 'file': 'f.dart', 'message': 'm', 'line': 12, 'rule_ref': 'unused_import'},
          ],
        ),
        _entry('dev', 'T2', 2, 'done', tokens: 300),
        _entry('g0', 'T2', 2, 'fail', findings: [g1Finding]),
        _entry('dev', 'T2', 3, 'done', tier: 'sonnet', tokens: 400),
        _entry('g0', 'T2', 3, 'pass', tier: 'sonnet'),
        _entry('g1', 'T2', 3, 'agent_failed', tier: 'sonnet'),
      ],
    };

    test('run status, reason and tasks', () {
      final run = parseResultRun('impl-20260310T101500Z', result, {'T1': 'Titulo 1'}, now: now);
      expect(run.status, Verdict.blocked);
      expect(run.kind, 'implement');
      expect(run.reason, 'same_failure_across_tiers');
      expect(run.tasks.map((t) => t.title), ['Titulo 1', 'T2', 'T3']);
      expect(run.tasks.map((t) => t.status), [Verdict.pass, Verdict.blocked, Verdict.pending]);
      expect(run.tasks[1].complexity, Complexity.l);
      expect(run.tasks[1].risk, isTrue);
      expect(run.tasks[0].files, ['a.dart']);
    });

    test('attempts grouped by (task, attempt) with summed tokens and tier from dev', () {
      final t2 = parseResultRun('impl-20260310T101500Z', result, {}, now: now).tasks[1];
      expect(t2.attempts.map((a) => a.number), [1, 2, 3]);
      expect(t2.attempts.map((a) => a.ordinal), [1, 2, 3]);
      expect(t2.attempts.map((a) => a.tier), [Tier.haiku, Tier.haiku, Tier.sonnet]);
      expect(t2.attempts.map((a) => a.tokensOut), [220, 300, 400]);
      expect(t2.tokensOut, 920);
      expect(t2.attempts.map((a) => a.escalatedTo), [null, Tier.sonnet, null]);
      expect(t2.attempts.map((a) => a.summary), [null, null, 'ultima']);
      expect(
        parseResultRun('impl-20260310T101500Z', result, {}, now: now).tasks[0].attempts.single.gates.map((g) => g.gate),
        ['g0'],
      );
    });

    test('gates: only g0/g1, agent_failed is fail without findings', () {
      final a3 = parseResultRun('impl-20260310T101500Z', result, {}, now: now).tasks[1].attempts[2];
      expect(a3.gates.map((g) => g.gate), ['g0', 'g1']);
      expect(a3.gates.last.verdict, Verdict.fail);
      expect(a3.gates.last.findings, isEmpty);
      expect(a3.verdict, Verdict.fail);
    });

    test('findings: ruleRef falls back to id, line 0 becomes null', () {
      final attempts = parseResultRun('impl-20260310T101500Z', result, {}, now: now).tasks[1].attempts;
      final f1 = attempts[0].gates.single.findings.single;
      expect((f1.line, f1.ruleRef, f1.gate, f1.fingerprint), (12, 'unused_import', 'g0', 'g0:f.dart:unused_import'));
      final f2 = attempts[1].gates.single.findings.single;
      expect(f2.line, isNull);
      expect(f2.ruleRef, 'flutter-app/estado');
      final noRef = _json(
        jsonEncode({
          'status': 'done',
          'tasks': [
            {'id': 'T1', 'status': 'done'},
          ],
          'trace': [
            _entry(
              'g0',
              'T1',
              1,
              'fail',
              findings: [
                {'id': 'ID-1', 'file': 'a', 'message': 'm'},
              ],
            ),
          ],
        }),
      );
      final f = parseResultRun(
        'impl-20260310T101500Z',
        noRef,
        {},
        now: now,
      ).tasks.single.attempts.single.gates.single.findings.single;
      expect(f.ruleRef, 'ID-1');
      expect(f.line, isNull);
    });

    test('diagnosis only on blocked task, ordered by confidence desc', () {
      final run = parseResultRun('impl-20260310T101500Z', result, {}, now: now);
      expect(run.tasks[0].diagnosis, isEmpty);
      expect(run.tasks[1].diagnosis.map((h) => h.action), ['act2', 'act1']);
      expect(run.tasks[1].blockedReason, 'same_failure_across_tiers');
      expect(run.tasks[0].blockedReason, isNull);
      expect(run.blockedTask?.id, 'T2');
    });

    test('status mapping', () {
      Run run(String s) =>
          parseResultRun('impl-20260310T101500Z', {'status': s, 'tasks': [], 'trace': []}, {}, now: now);
      expect(run('done').status, Verdict.pass);
      expect(run('verified').status, Verdict.pass);
      expect(run('blocked').status, Verdict.blocked);
      expect(run('inconclusive').status, Verdict.inconclusive);
      final bt = run('backtrack');
      expect(bt.status, Verdict.blocked);
      expect(bt.reason, 'backtrack');
    });

    test('verify: V<n> title, round labels, header gates from last round', () {
      final verify = {
        'status': 'verified',
        'tasks': [
          {
            'id': 'V1',
            'status': 'done',
            'tier0': 'opus',
            'summary': 's',
            'escalations': [
              {'to': 'fable', 'at_attempt': 1},
            ],
          },
        ],
        'trace': [
          {
            'role': 'g1:arch',
            'round': 1,
            'verdict': 'fail',
            'findings': [g1Finding],
          },
          {'role': 'g2', 'round': 1, 'verdict': 'inconclusive', 'findings': []},
          _entry('dev', 'V1', 1, 'done', tier: 'opus', tokens: 10, round: 1),
          _entry('dev', 'V1', 1, 'done', tier: 'opus', tokens: 10, round: 2),
          _entry('dev', 'V1', 2, 'done', tier: 'opus', tokens: 10, round: 2),
          {'role': 'g1:arch', 'round': 2, 'verdict': 'pass', 'findings': []},
          {'role': 'g2', 'round': 2, 'verdict': 'inconclusive', 'findings': []},
        ],
      };
      final run = parseResultRun('verify-20260310T113000Z', verify, {}, now: now);
      expect(run.kind, 'verify');
      expect(run.status, Verdict.pass);
      final v1 = run.tasks.single;
      expect(v1.title, 'Correções transversais do verify r1');
      expect(v1.attempts.map((a) => a.label), ['r1 #1', 'r2 #1', 'r2 #2']);
      expect(v1.attempts.map((a) => a.ordinal), [1, 2, 3]);
      expect(v1.attempts.map((a) => a.escalatedTo), [null, Tier.fable, null]);
      expect(run.gates.map((g) => (g.gate, g.verdict)), [('g1:arch', Verdict.pass), ('g2', Verdict.inconclusive)]);
    });

    test('startedAt: HH:mm if today', () {
      final local = DateTime(2026, 3, 10, 10, 15, 0);
      final id = 'impl-${_stamp(local.toUtc())}';
      expect(parseResultRun(id, result, {}, now: local).startedAt, '10:15');
    });

    test('alpha fixture, when present', () {
      final f = File('test/fixtures/workflow/alpha/runs/impl-20260310T101500Z/result.json');
      if (!f.existsSync()) return;
      final run = parseResultRun('impl-20260310T101500Z', _json(f.readAsStringSync()), {}, now: now);
      final t2 = run.tasks.firstWhere((t) => t.id == 'T2');
      expect(t2.attempts, hasLength(4));
      expect(t2.attempts.map((a) => a.escalatedTo), [null, Tier.sonnet, null, null]);
      expect(t2.diagnosis.first.confidence, 0.8);
    });
  });

  group('parseEventsRun', () {
    final events = decodeJsonl('''
{"role": "dev", "task": "T1", "tier": "haiku", "verdict": "start", "attempt": 1}
{"role": "g0", "task": "T1", "tier": "haiku", "verdict": "fail", "attempt": 1, "count": 2}
{"role": "escalate", "task": "T1", "tier": "sonnet", "note": "from haiku"}
{"role": "dev", "task": "T1", "tier": "sonnet", "verdict": "start", "attempt": 2}
''');
    final now = DateTime.utc(2026, 3, 11, 15);

    test('running run with two attempts, escalation and no tokens', () {
      final run = parseEventsRun('impl-20260311T140000Z', events, titles: {'T1': 'Servico'}, now: now);
      expect(run.status, Verdict.running);
      final t = run.tasks.single;
      expect(t.title, 'Servico');
      expect(t.status, Verdict.running);
      expect(t.attempts, hasLength(2));
      expect(t.attempts[0].gates.single.verdict, Verdict.fail);
      expect(t.attempts[0].escalatedTo, Tier.sonnet);
      expect(t.attempts[1].tier, Tier.sonnet);
      expect(t.attempts.map((a) => a.tokensOut), [null, null]);
      expect(run.tokensOut, isNull);
      expect(t.tier0, Tier.haiku);
    });

    test('g0 without dev start creates the attempt', () {
      final run = parseEventsRun('impl-20260311T140000Z', [
        {'role': 'g0', 'task': 'T1', 'tier': 'opus', 'verdict': 'pass', 'attempt': 3},
      ], now: now);
      final a = run.tasks.single.attempts.single;
      expect((a.number, a.tier, a.verdict), (3, Tier.opus, Verdict.pass));
    });

    test('event without attempt goes to last attempt of the task', () {
      final run = parseEventsRun('impl-20260311T140000Z', [
        {'role': 'dev', 'task': 'T1', 'tier': 'haiku', 'verdict': 'start', 'attempt': 1},
        {'role': 'dev', 'task': 'T1', 'tier': 'haiku', 'verdict': 'start', 'attempt': 2},
        {'role': 'g1', 'task': 'T1', 'tier': 'haiku', 'verdict': 'fail'},
      ], now: now);
      final attempts = run.tasks.single.attempts;
      expect(attempts, hasLength(2));
      expect(attempts[0].gates, isEmpty);
      expect(attempts[1].gates.single.gate, 'g1');
    });

    test('dev blocked sets summary; ops and unknown roles ignored', () {
      final run = parseEventsRun('impl-20260311T140000Z', [
        {'role': 'dev', 'task': 'T1', 'tier': 'haiku', 'verdict': 'blocked', 'attempt': 1},
        {'role': 'ops', 'task': 'T1', 'verdict': 'ok'},
        {'role': 'dev', 'verdict': 'start'},
      ], now: now);
      expect(run.tasks.single.attempts.single.summary, 'dev declarou blocked');
    });

    test('tasks keep order of first appearance; earlier passing task is pass', () {
      final run = parseEventsRun('impl-20260311T140000Z', [
        {'role': 'dev', 'task': 'T1', 'tier': 'haiku', 'verdict': 'start', 'attempt': 1},
        {'role': 'g0', 'task': 'T1', 'tier': 'haiku', 'verdict': 'pass', 'attempt': 1},
        {'role': 'dev', 'task': 'V2', 'tier': 'opus', 'verdict': 'start', 'attempt': 1},
      ], now: now);
      expect(run.tasks.map((t) => t.id), ['T1', 'V2']);
      expect(run.tasks.map((t) => t.status), [Verdict.pass, Verdict.running]);
      expect(run.tasks[1].title, 'Correções transversais do verify r2');
    });
  });

  group('decodeJsonl', () {
    test('skips invalid and truncated lines, reporting them', () {
      final bad = <String>[];
      final out = decodeJsonl('{"a":1}\n\n   \nnot json\n[1]\n{"b":2}\n{"c":', onInvalid: (l, _) => bad.add(l));
      expect(out, [
        {'a': 1},
        {'b': 2},
      ]);
      expect(bad, ['not json', '[1]', '{"c":']);
    });

    test('works without callback', () => expect(decodeJsonl('{"a":'), isEmpty));
  });

  group('classify', () {
    const root = '/private/var/folders/x/workflow';

    test('root, project and run scopes', () {
      expect(classify(root, root), isA<RootScope>());
      expect(classify(root, '$root/alpha'), isA<RootScope>());
      expect(
        classify(root, '$root/alpha/current.json'),
        isA<ProjectScope>().having((s) => s.project, 'project', 'alpha'),
      );
      expect(classify(root, '$root/alpha/runs'), isA<ProjectScope>());
      final run = classify(root, '$root/alpha/runs/impl-20260310T101500Z/result.json');
      expect(
        run,
        isA<RunScope>()
            .having((s) => s.project, 'project', 'alpha')
            .having((s) => s.runId, 'runId', 'impl-20260310T101500Z'),
      );
      expect(classify(root, '$root/alpha/runs/impl-20260310T101500Z'), isA<RunScope>());
    });

    test('ignores dot segments, tmp and lock', () {
      expect(classify(root, '$root/alpha/.current.json.lock'), isNull);
      expect(classify(root, '$root/alpha/current.tmp'), isNull);
      expect(classify(root, '$root/alpha/runs/impl-20260310T101500Z/result.json.tmp'), isNull);
      expect(classify(root, '$root/.hidden/x'), isNull);
      expect(classify(root, '$root/.dashboard.json'), isNull);
      expect(classify(root, '$root/alpha/x.lock'), isNull);
    });

    test('move uses the destination', () {
      expect(
        classify(root, '$root/alpha/current.tmp', destination: '$root/alpha/current.json'),
        isA<ProjectScope>().having((s) => s.project, 'project', 'alpha'),
      );
      expect(classify(root, '$root/alpha/current.json', destination: '$root/alpha/.trash'), isNull);
    });

    test('outside root and unresolved symlink prefix', () {
      expect(classify(root, '/var/folders/x/workflow/alpha/current.json'), isNull);
      expect(classify(root, '$root-other/alpha/current.json'), isNull);
      expect(classify('$root/', '$root/alpha/current.json'), isA<ProjectScope>());
    });
  });

  group('formatStartedAt', () {
    test('HH:mm if today, dd/MM HH:mm otherwise', () {
      final now = DateTime(2026, 3, 11, 18, 0);
      expect(formatStartedAt(DateTime(2026, 3, 11, 9, 5).toUtc(), now.toUtc()), '09:05');
      expect(formatStartedAt(DateTime(2026, 3, 10, 14, 30).toUtc(), now.toUtc()), '10/03 14:30');
      expect(formatStartedAt(DateTime(2025, 12, 1, 7, 0).toUtc(), now.toUtc()), '01/12 07:00');
    });

    test('runStart parses run id', () {
      expect(runStart('impl-20260310T101500Z'), DateTime.utc(2026, 3, 10, 10, 15));
      expect(runStart('nope'), isNull);
      expect(runIdPattern.hasMatch('verify-20260310T113000Z'), isTrue);
      expect(runIdPattern.hasMatch('impl-2026'), isFalse);
    });
  });
}

String _stamp(DateTime u) {
  String t(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${t(u.year, 4)}${t(u.month)}${t(u.day)}T${t(u.hour)}${t(u.minute)}${t(u.second)}Z';
}
