import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/workflow_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Finding _f(String rule, {String severity = 'major', String gate = 'g0', String file = 'lib/a.dart', int? line = 3}) =>
    Finding(gate: gate, severity: severity, file: file, line: line, ruleRef: rule, message: 'msg $rule');

Attempt _a(
  int n, {
  Tier tier = Tier.haiku,
  List<GateResult> gates = const [],
  String? summary,
  Tier? escalatedTo,
  String? label,
}) =>
    Attempt(number: n, ordinal: n, tier: tier, gates: gates, summary: summary, escalatedTo: escalatedTo, label: label);

GateResult _fail(List<Finding> findings, {String gate = 'g0'}) => GateResult(gate, Verdict.fail, findings);

TaskRun _task({
  Verdict status = Verdict.blocked,
  List<Attempt> attempts = const [],
  Tier tier0 = Tier.haiku,
  String? blockedReason,
  List<Hypothesis> diagnosis = const [],
}) => TaskRun(
  id: 'T1',
  title: 't',
  complexity: Complexity.m,
  tier0: tier0,
  status: status,
  attempts: attempts,
  blockedReason: blockedReason,
  diagnosis: diagnosis,
);

List<Attempt> _n(int n, {Tier tier = Tier.haiku}) => [for (var i = 1; i <= n; i++) _a(i, tier: tier)];

Hypothesis _h(String text, double confidence) =>
    Hypothesis(lens: 'l', hypothesis: text, confidence: confidence, evidence: const [], action: 'replan');

void main() {
  group('taskHeadline', () {
    test('blocked after 1 and 3 attempts', () {
      expect(taskHeadline(_task(attempts: _n(1))), 'travou após 1 tentativa');
      expect(taskHeadline(_task(attempts: _n(3))), 'travou após 3 tentativas');
    });

    test('pass on the first attempt and on the second', () {
      expect(taskHeadline(_task(status: Verdict.pass, attempts: _n(1))), 'pronta de primeira');
      expect(taskHeadline(_task(status: Verdict.pass, attempts: _n(2))), 'pronta na tentativa 2');
    });

    test('running without and with attempts', () {
      expect(taskHeadline(_task(status: Verdict.running)), 'rodando, tentativa 1');
      expect(taskHeadline(_task(status: Verdict.running, attempts: _n(2))), 'rodando, tentativa 2');
    });

    test('fail', () {
      expect(taskHeadline(_task(status: Verdict.fail, attempts: _n(2))), 'reprovou após 2 tentativas');
    });

    test('pending and inconclusive', () {
      expect(taskHeadline(_task(status: Verdict.pending, attempts: _n(2))), 'parou após 2 tentativas');
      expect(taskHeadline(_task(status: Verdict.inconclusive, attempts: _n(1))), 'parou após 1 tentativa');
      expect(taskHeadline(_task(status: Verdict.pending)), 'na fila');
    });

    test('position and total only when both exist', () {
      final t = _task(attempts: _n(1));
      expect(taskHeadline(t, position: 2, total: 3), 'Task 2 de 3 · travou após 1 tentativa');
      expect(taskHeadline(t, position: 2), 'travou após 1 tentativa');
      expect(taskHeadline(t, total: 3), 'travou após 1 tentativa');
    });

    test('escalation', () {
      final t = _task(
        attempts: [_a(1, tier: Tier.fable)],
        tier0: Tier.opus,
      );
      expect(taskHeadline(t), 'travou após 1 tentativa · escalou de opus para fable');
      expect(
        taskHeadline(t, position: 1, total: 2),
        'Task 1 de 2 · travou após 1 tentativa · escalou de opus para fable',
      );
    });
  });

  group('taskAttemptLines', () {
    test('critical is shown even after a major, the major goes to others', () {
      final lines = taskAttemptLines(
        _task(
          attempts: [
            _a(
              1,
              gates: [
                _fail([_f('maj'), _f('crit', severity: 'critical', file: 'lib/b.dart', line: 9)]),
              ],
            ),
          ],
        ),
      );
      expect(lines.single.message, 'msg crit');
      expect(lines.single.rule, 'crit');
      expect(lines.single.location, 'lib/b.dart:9');
      expect(lines.single.others, [(message: 'msg maj', location: 'lib/a.dart:3', rule: 'maj')]);
    });

    test('new critical next to a repeated major is the same failure and shows the critical', () {
      final lines = taskAttemptLines(
        _task(
          attempts: [
            _a(
              1,
              gates: [
                _fail([_f('maj')]),
              ],
            ),
            _a(
              2,
              gates: [
                _fail([_f('maj'), _f('crit', severity: 'critical')]),
              ],
            ),
          ],
        ),
      );
      expect(lines[0].subtitle, 'haiku · reprovada em G0');
      expect(lines[1].subtitle, 'haiku · mesma falha da tentativa 1');
      expect(lines[1].message, 'msg crit');
    });

    test('same failure points to the earliest attempt that had it', () {
      final lines = taskAttemptLines(
        _task(
          attempts: [
            _a(
              1,
              gates: [
                _fail([_f('x')]),
              ],
            ),
            _a(
              2,
              gates: [
                _fail([_f('y')]),
              ],
            ),
            _a(
              3,
              gates: [
                _fail([_f('y')]),
              ],
            ),
            _a(
              4,
              gates: [
                _fail([_f('x'), _f('y')]),
              ],
            ),
          ],
        ),
      );
      expect(lines.map((l) => l.subtitle), [
        'haiku · reprovada em G0',
        'haiku · reprovada em G0',
        'haiku · mesma falha da tentativa 2',
        'haiku · mesma falha da tentativa 1',
      ]);
    });

    test('finding without line and root-relative location', () {
      final lines = taskAttemptLines(
        _task(
          attempts: [
            _a(
              1,
              gates: [
                _fail([_f('r', file: '/repo/lib/a.dart', line: null)]),
              ],
            ),
          ],
        ),
        root: '/repo',
      );
      expect(lines.single.location, 'lib/a.dart');
    });

    test('failed attempt without finding uses the summary and the first failed gate', () {
      final lines = taskAttemptLines(
        _task(
          attempts: [
            _a(
              1,
              summary: 'quebrou',
              gates: [
                const GateResult('g0', Verdict.pass),
                _fail(const [], gate: 'g1'),
              ],
            ),
          ],
        ),
      );
      expect(lines.single.subtitle, 'haiku · reprovada em G1');
      expect(lines.single.message, 'quebrou');
      expect(lines.single.location, '');
      expect(lines.single.rule, '');
      expect(lines.single.others, isEmpty);
    });

    test('passed attempt', () {
      final lines = taskAttemptLines(
        _task(
          status: Verdict.pass,
          attempts: [
            _a(1, gates: [const GateResult('g0', Verdict.pass)]),
          ],
        ),
      );
      expect(lines.single.subtitle, 'haiku · passou');
    });

    test('attempt without gates is running in a running task and without verdict in a blocked one', () {
      expect(taskAttemptLines(_task(status: Verdict.running, attempts: _n(1))).single.subtitle, 'haiku · rodando');
      expect(taskAttemptLines(_task(attempts: _n(1))).single.subtitle, 'haiku · sem veredito');
      expect(taskAttemptLines(_task(status: Verdict.running, attempts: _n(2))).first.subtitle, 'haiku · sem veredito');
    });

    test('verify round prefix', () {
      final lines = taskAttemptLines(
        _task(
          attempts: [
            _a(
              1,
              label: 'r2 #1',
              gates: [
                _fail([_f('x')]),
              ],
            ),
          ],
        ),
      );
      expect(lines.single.subtitle, 'rodada 2 · haiku · reprovada em G0');
      expect(lines.single.title, 'Tentativa 1');
    });

    test('note: escalation, then blocked reason on the last attempt only', () {
      final lines = taskAttemptLines(
        _task(
          blockedReason: 'max_attempts',
          attempts: [
            _a(1, escalatedTo: Tier.sonnet),
            _a(2, tier: Tier.sonnet),
            _a(3, tier: Tier.sonnet),
          ],
        ),
      );
      expect(lines[0].note, 'Desfez as mudanças e escalou para um modelo maior: haiku → sonnet');
      expect(lines[1].note, '');
      expect(lines[2].note, blockedReasonText('max_attempts'));
    });
  });

  group('alpha T2', () {
    late TaskRun t2;
    late List<TaskAttemptLine> lines;

    setUpAll(() {
      const id = 'impl-20260310T101500Z';
      final raw = File('test/fixtures/workflow/alpha/runs/$id/result.json').readAsStringSync();
      final run = parseResultRun(id, jsonDecode(raw) as Map<String, dynamic>, const {});
      t2 = run.tasks.firstWhere((t) => t.id == 'T2');
      lines = taskAttemptLines(t2);
    });

    test('subtitles', () {
      expect(lines.map((l) => l.subtitle), [
        'haiku · reprovada em G0',
        'haiku · mesma falha da tentativa 1',
        'sonnet · mesma falha da tentativa 1',
        'sonnet · reprovada em G1',
      ]);
    });

    test('notes', () {
      expect(lines[1].note, endsWith('haiku → sonnet'));
      expect(lines[3].note, blockedReasonText('same_failure_across_tiers'));
      expect(lines[0].note, '');
      expect(lines[2].note, '');
    });

    test('headline', () {
      expect(
        taskHeadline(t2, position: 2, total: 3),
        'Task 2 de 3 · travou após 4 tentativas · escalou de haiku para sonnet',
      );
    });
  });

  group('rankedHypotheses', () {
    test('by confidence, ties keep the original order', () {
      final ranked = rankedHypotheses(
        _task(diagnosis: [_h('a', 0.5), _h('b', 0.9), _h('c', 0.5), _h('d', 0.5), _h('e', 0.1)]),
      );
      expect(ranked.map((h) => h.hypothesis), ['b', 'a', 'c', 'd', 'e']);
    });

    test('empty diagnosis', () {
      expect(rankedHypotheses(_task()), isEmpty);
    });
  });

  group('blockedReasonText', () {
    test('the four known reasons', () {
      expect(blockedReasonText('same_failure_across_tiers'), contains('não é capacidade, é spec ou plano'));
      expect(blockedReasonText('ladder_exhausted'), 'A escada chegou ao topo (fable) sem passar nos gates.');
      expect(blockedReasonText('max_attempts'), 'Limite de 5 tentativas atingido.');
      expect(blockedReasonText('agent_failed'), contains('rode /implement de novo'));
    });

    test('unknown or null is empty', () {
      expect(blockedReasonText('nope'), '');
      expect(blockedReasonText(null), '');
    });
  });

  group('taskLocation', () {
    test('fromRuns appends the query', () {
      expect(taskLocation('p', 'r', 'T1'), '/p/p/runs/r/T1');
      expect(taskLocation('p', 'r', 'T1', fromRuns: true), '/p/p/runs/r/T1?from=runs');
    });
  });
}
