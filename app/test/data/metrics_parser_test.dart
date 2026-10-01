import 'dart:convert';

import 'package:claude_flow/data/metrics_models.dart';
import 'package:claude_flow/data/metrics_parser.dart';
import 'package:flutter_test/flutter_test.dart';

String l(Map<String, Object?> m) => jsonEncode(m);

Map<String, Object?> row(
  String role, {
  String? run,
  String? task,
  int? attempt,
  String? tier,
  String? verdict,
  Object? tokens = 10,
  String? at,
  int? seq,
  int? round,
}) => {
  'run_id': run ?? 'r',
  'role': role,
  'task': ?task,
  'attempt': ?attempt,
  'tier': ?tier,
  'verdict': ?verdict,
  'tokens_out': ?tokens,
  'persisted_at': ?at,
  'seq': ?seq,
  'round': ?round,
};

void main() {
  group('parseTraceLine', () {
    test('valida: objeto com role; campos opcionais ausentes', () {
      final t = parseTraceLine('{"role":"g1:a"}');
      expect(t, isNotNull);
      expect(t!.task, isNull);
      expect(t.tokensOut, isNull);
    });

    test('inválidas: JSON quebrado, não objeto, sem role', () {
      expect(parseTraceLine('{'), isNull);
      expect(parseTraceLine('[]'), isNull);
      expect(parseTraceLine('{"tier":"opus"}'), isNull);
      expect(parseTraceLine('{"role":""}'), isNull);
    });
  });

  group('aggregateCycle', () {
    final impl = [
      l(row('dev', task: 'T1', attempt: 1, tier: 'sonnet', verdict: 'fail', at: '01')),
      l(row('dev', task: 'T1', attempt: 2, tier: 'opus', at: '02')),
      l(row('g0', task: 'T1', verdict: 'pass', at: '03')),
      l(row('dev', task: 'T2', attempt: 1, tier: 'sonnet', at: '04')),
      l(row('dev', task: 'T2', attempt: 2, tier: 'sonnet', at: '05')),
      l(row('g0', task: 'T2', verdict: 'pass', at: '06')),
      l(row('dev', task: 'T3', attempt: 1, tier: 'opus', at: '07')),
      l(row('g1', task: 'T3', verdict: 'pass', at: '08')),
    ];
    final verify = [
      l(row('dev', task: 'T3', attempt: 1, tier: 'opus', at: '09', round: 1)),
      l(row('g1:a', verdict: 'pass', at: '10', round: 2)),
    ];

    Map<String, TaskMetrics> byKey(CycleMetrics c) => {for (final t in c.tasks) t.key: t};

    test('C1: escalada, repetição no mesmo tier e reentry somando na task original', () {
      final c = aggregateCycle('2026-01-01_x', null, {'impl-1': impl, 'verify-1': verify});
      final t = byKey(c);
      expect(c.tasks, hasLength(3));
      expect(t['T1']!.attempts, 2);
      expect(t['T1']!.tier0, 'sonnet');
      expect(t['T1']!.tierFinal, 'opus');
      expect(t['T1']!.escalated, isTrue);
      expect(t['T1']!.passedTier0, isFalse);
      expect(t['T2']!.attempts, 2);
      expect(t['T2']!.escalated, isFalse);
      expect(t['T2']!.passedTier0, isTrue);
      expect(t['T3']!.attempts, 2);
      expect(c.escalations, 1);
      expect(c.attempts, 6);
      expect(c.verifyRuns, 1);
      expect(c.rounds, 2);
    });

    test('C2: V1 em dois verify vira 2 tasks; papéis agregados; gate sem task não é ignorado', () {
      final c = aggregateCycle('2026-01-01_x', null, {
        'verify-a': [
          l(row('dev', task: 'V1', tier: 'sonnet', at: '1')),
          l(row('g1', verdict: 'pass', tokens: 1, at: '2')),
          l(row('g1:a', tokens: 2, at: '3')),
          l(row('g1:b', tokens: 3, at: '4')),
        ],
        'verify-b': [l(row('dev', task: 'V1', tier: 'sonnet', at: '5')), l(row('ops', tokens: 7, at: '6'))],
      });
      expect(c.tasks, hasLength(2));
      expect(c.ignoredLines, 0);
      expect(c.tokensByRole['g1'], 6);
      expect(c.tokensByRole['dev'], 20);
      expect(c.tokensByRole['outros'], 7);
      expect(c.verifyRuns, 2);
    });

    test('linhas inválidas contam em ignoredLines; verify sem task conta em tokens', () {
      final c = aggregateCycle('2026-01-01_x', null, {
        'verify-1': ['{', '[]', '{"tier":"opus"}', '', l(row('g2', tokens: 5))],
      });
      expect(c.ignoredLines, 3);
      expect(c.tokensByRole['g2'], 5);
      expect(c.tasks, isEmpty);
    });

    test('tokens_out ausente versus 0', () {
      final none = aggregateCycle('d', null, {
        'impl': [l(row('dev', task: 'T1', tokens: null))],
      });
      expect(none.hasTokens, isFalse);
      expect(none.tokensMissing, 1);
      final zero = aggregateCycle('d', null, {
        'impl': [l(row('dev', task: 'T1', tokens: 0)), l(row('dev', task: 'T1', tokens: '9'))],
      });
      expect(zero.hasTokens, isTrue);
      expect(zero.tokensMissing, 1);
      expect(zero.tokensTotal, 0);
    });

    test('persist duplicado (mesmo run_id e seq) vale o maior persisted_at', () {
      final c = aggregateCycle('d', null, {
        'impl': [
          l(row('dev', task: 'T1', tier: 'sonnet', seq: 1, at: '01', tokens: 100)),
          l(row('dev', task: 'T1', tier: 'opus', seq: 1, at: '02', tokens: 5)),
        ],
      });
      expect(c.tasks.single.attempts, 1);
      expect(c.tasks.single.tierFinal, 'opus');
      expect(c.tokensTotal, 5);
    });

    test('persist repetido no mesmo segundo conta uma vez; vale o último do arquivo', () {
      final c = aggregateCycle('d', null, {
        'impl': [
          l(row('dev', task: 'T1', tier: 'sonnet', seq: 1, at: '01', tokens: 100)),
          l(row('dev', task: 'T1', tier: 'sonnet', seq: 1, at: '02', tokens: 7)),
          l(row('dev', task: 'T1', tier: 'opus', seq: 1, at: '02', tokens: 5)),
        ],
      });
      expect(c.tasks.single.attempts, 1);
      expect(c.tasks.single.tierFinal, 'opus');
      expect(c.tokensTotal, 5);
    });

    test('metrics.json: feature, tasks e status; tokens_spent ignorado; ciclo atual', () {
      final c = aggregateCycle(
        '2026-01-01_x',
        {'feature': 'F', 'tasks_total': 5, 'tasks_completed': 4, 'status': 'completed', 'tokens_spent': 999999999},
        {
          'impl': [l(row('dev', task: 'T1', tokens: 1234))],
        },
      );
      expect(c.feature, 'F');
      expect(c.tasksLabel, '4/5');
      expect(c.status, 'completed');
      expect(c.tokensTotal, 1234);
      final cur = aggregateCycle('current', null, const {}, current: true);
      expect(cur.feature, 'ciclo atual');
      expect(cur.status, 'em andamento');
      expect(cur.hasTrace, isFalse);
    });

    test('não lança com tipos errados', () {
      final c = aggregateCycle(
        'x',
        {'feature': 3, 'tasks_total': [], 'status': {}},
        {
          'impl': ['null', '"s"', '{"role":1}', '{"role":"dev","task":"T1","tier":5,"tokens_out":"x"}'],
        },
      );
      expect(c.ignoredLines, 3);
      expect(c.tasks.single.attempts, 1);
    });
  });

  group('orderCycles / projectSummary', () {
    test('ciclo atual, data desc, persisted_at desc, nome desc; sem trace ao fim da data', () {
      CycleMetrics mk(String dir, {String? at, bool current = false, String status = 'completed'}) => aggregateCycle(
        dir,
        {'status': status},
        at == null
            ? const {}
            : {
                'impl': [l(row('dev', task: 'T1', tier: 'a', verdict: 'pass', at: at))],
              },
        current: current,
      );
      final ordered = orderCycles([
        mk('2026-01-01_a', at: '5'),
        mk('2026-01-02_old'),
        mk('2026-01-02_b', at: '1'),
        mk('2026-01-02_c', at: '9'),
        mk('2026-01-01_z', at: '5'),
        mk('current', at: '0', current: true),
      ]);
      expect(ordered.map((c) => c.dir), [
        'current',
        '2026-01-02_c',
        '2026-01-02_b',
        '2026-01-02_old',
        '2026-01-01_z',
        '2026-01-01_a',
      ]);
    });

    test('cards somam ciclos concluídos, tasks, escaladas e tokens', () {
      final a = aggregateCycle(
        '2026-01-01_a',
        {'status': 'completed'},
        {
          'impl': [
            l(row('dev', task: 'T1', tier: 's', tokens: 3)),
            l(row('dev', task: 'T1', tier: 'o', tokens: 3)),
            l(row('g0', task: 'T1', verdict: 'pass', tokens: 1)),
            l(row('dev', task: 'T2', tier: 's', tokens: 3)),
            l(row('g0', task: 'T2', verdict: 'pass', tokens: 1)),
          ],
        },
      );
      final cur = aggregateCycle('current', null, {
        'impl': [l(row('dev', task: 'T1', tier: 's', tokens: 2))],
      }, current: true);
      final p = projectSummary([a, cur]);
      expect(p.completedCycles, 1);
      expect(p.tasks, 3);
      expect(p.passedTier0, 1);
      expect(p.escalations, 1);
      expect(p.tokensByRole['dev'], 11);
      expect(p.tokensByRole['g0'], 2);
      expect(p.cycles.first.current, isTrue);
      expect(projectSummary(const []).passTier0Percent, isNull);
    });
  });
}
