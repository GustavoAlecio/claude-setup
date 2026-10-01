import 'dart:convert';

import 'metrics_models.dart';
import 'metrics_parser.dart';
import 'metrics_repository.dart';
import 'models.dart';

/// [sample]: ciclo atual; dois ciclos em 2026-04-20 (o de `persisted_at` maior primeiro) e um sem trace em 2026-04-10.
/// Totais: 3 ciclos concluídos, 5 tasks, 4 passaram no tier0, 1 escalada; tokens dev 870, g0 0, g1 310, g2 30.
class MockMetricsRepository implements MetricsRepository {
  const MockMetricsRepository.empty() : _metrics = const ProjectMetrics.empty();

  MockMetricsRepository.sample() : _metrics = _sample();

  final ProjectMetrics _metrics;

  @override
  Future<ProjectMetrics> loadProject(Project project) async => _metrics;
}

String _line(
  String role, {
  String? task,
  int? attempt,
  String? tier,
  String? verdict,
  int tokens = 0,
  required String at,
  required int seq,
  String? stage,
  int? round,
}) => jsonEncode({
  'persisted_at': at,
  'seq': seq,
  'role': role,
  'task': ?task,
  'attempt': ?attempt,
  'tier': ?tier,
  'verdict': ?verdict,
  'tokens_out': tokens,
  'stage': ?stage,
  'round': ?round,
});

ProjectMetrics _sample() {
  const metricsAt = '2026-04-20T12:00:00Z';
  const verifyAt = '2026-04-20T13:00:00Z';
  const adrsAt = '2026-04-20T09:00:00Z';
  const currentAt = '2026-05-01T10:00:00Z';
  return projectSummary([
    aggregateCycle(
      'ciclo-atual',
      const {'feature': 'Ciclo em curso', 'tasks_total': 2, 'tasks_completed': 1},
      {
        'impl-20260501T090000Z': [
          _line('dev', task: 'T1', attempt: 1, tier: 'sonnet', verdict: 'done', tokens: 300, at: currentAt, seq: 0),
          _line('g0', task: 'T1', attempt: 1, tier: 'sonnet', verdict: 'pass', at: currentAt, seq: 1),
        ],
      },
      current: true,
    ),
    aggregateCycle(
      '2026-04-20_metricas',
      const {'feature': 'Métricas', 'tasks_total': 2, 'tasks_completed': 2, 'status': 'completed'},
      {
        'impl-20260420T100000Z': [
          _line('dev', task: 'T1', attempt: 1, tier: 'sonnet', verdict: 'done', tokens: 100, at: metricsAt, seq: 0),
          _line('g0', task: 'T1', attempt: 1, tier: 'sonnet', verdict: 'fail', at: metricsAt, seq: 1),
          _line('dev', task: 'T1', attempt: 2, tier: 'opus', verdict: 'done', tokens: 200, at: metricsAt, seq: 2),
          _line('g0', task: 'T1', attempt: 2, tier: 'opus', verdict: 'pass', at: metricsAt, seq: 3),
          _line('g1', task: 'T1', attempt: 2, tier: 'opus', verdict: 'pass', tokens: 50, at: metricsAt, seq: 4),
          _line('dev', task: 'T2', attempt: 1, tier: 'sonnet', verdict: 'done', tokens: 120, at: metricsAt, seq: 5),
          _line('g0', task: 'T2', attempt: 1, tier: 'sonnet', verdict: 'pass', at: metricsAt, seq: 6),
          _line('g1', task: 'T2', attempt: 1, tier: 'sonnet', verdict: 'pass', tokens: 40, at: metricsAt, seq: 7),
        ],
        'verify-20260420T123000Z': [
          _line(
            'g1:flutter-architecture',
            verdict: 'fail',
            tokens: 80,
            at: verifyAt,
            seq: 0,
            stage: 'verify',
            round: 1,
          ),
          _line('g2', verdict: 'pass', tokens: 30, at: verifyAt, seq: 1, stage: 'verify', round: 1),
          _line(
            'dev',
            task: 'V1',
            attempt: 1,
            tier: 'sonnet',
            verdict: 'done',
            tokens: 60,
            at: verifyAt,
            seq: 2,
            stage: 'verify-reentry',
            round: 1,
          ),
          _line(
            'g0',
            task: 'V1',
            attempt: 1,
            tier: 'sonnet',
            verdict: 'pass',
            at: verifyAt,
            seq: 3,
            stage: 'verify-reentry',
            round: 1,
          ),
          _line(
            'g1:flutter-architecture',
            verdict: 'pass',
            tokens: 70,
            at: verifyAt,
            seq: 4,
            stage: 'verify',
            round: 2,
          ),
        ],
      },
    ),
    aggregateCycle(
      '2026-04-20_adrs',
      const {'feature': 'ADRs', 'tasks_total': 1, 'tasks_completed': 1, 'status': 'completed'},
      {
        'impl-20260420T080000Z': [
          _line('dev', task: 'T1', attempt: 1, tier: 'haiku', verdict: 'done', tokens: 90, at: adrsAt, seq: 0),
          _line('g0', task: 'T1', attempt: 1, tier: 'haiku', verdict: 'pass', at: adrsAt, seq: 1),
          _line('g1', task: 'T1', attempt: 1, tier: 'haiku', verdict: 'pass', tokens: 70, at: adrsAt, seq: 2),
        ],
      },
    ),
    aggregateCycle('2026-04-10_sem-trace', const {
      'feature': 'Sem trace',
      'tasks_total': 2,
      'tasks_completed': 1,
      'status': 'completed',
    }, const {}),
  ]);
}
