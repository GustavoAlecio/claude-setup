import 'package:claude_flow/data/mock_metrics_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sample tem os valores fixos que os widget tests usam', () async {
    final m = await MockMetricsRepository.sample().loadProject(const Project(name: 'x'));

    expect(m.cycles.map((c) => c.dir), [
      'ciclo-atual',
      '2026-04-20_metricas',
      '2026-04-20_adrs',
      '2026-04-10_sem-trace',
    ]);
    expect(m.completedCycles, 3);
    expect(m.tasks, 5);
    expect(m.passedTier0, 4);
    expect(m.escalations, 1);
    expect(m.tokensByRole, {'dev': 870, 'g0': 0, 'g1': 310, 'g2': 30, 'outros': 0});
  });

  test('empty não tem ciclos', () async {
    expect((await const MockMetricsRepository.empty().loadProject(const Project(name: 'x'))).cycles, isEmpty);
  });
}
