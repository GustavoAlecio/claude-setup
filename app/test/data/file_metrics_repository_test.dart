import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/file_metrics_repository.dart';
import 'package:claude_flow/data/metrics_models.dart';
import 'package:claude_flow/data/metrics_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

final _fixtures = Directory('test/fixtures').absolute.path;
const _alpha = Project(name: 'alpha');

void _write(String path, String content) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}

String _trace(List<Map<String, Object?>> lines) => lines.map((l) => '${jsonEncode(l)}\n').join();

Map<String, TaskMetrics> _byKey(CycleMetrics c) => {for (final t in c.tasks) t.key: t};

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('metrics_repo_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('fixtures do gen.sh', () {
    late ProjectMetrics m;

    setUp(() async {
      m = await FileMetricsRepository(_fixtures, '$_fixtures/workflow').loadProject(_alpha);
    });

    test('lê o histórico em ordem e sem ciclo atual quando o workflow não tem trace', () {
      expect(m.cycles.map((c) => c.dir), ['2026-04-02_metricas-alpha', '2026-03-20_sem-trace-alpha']);
      expect(m.cycles.any((c) => c.current), isFalse);
      expect(m.completedCycles, 1);
    });

    test('tokens vêm do trace e ignoram o tokens_spent do metrics.json', () {
      final c = m.cycles.first;
      expect(c.tokensTotal, 1234);
      expect(c.tokensByRole, {'dev': 730, 'g0': 0, 'g1': 429, 'g2': 75, 'outros': 0});
      expect(m.tokensByRole['dev'], 730);
    });

    test('ciclo com verify-reentry: V1 por run, T2 somando na original, escalada e rodadas', () {
      final c = m.cycles.first;
      final t = _byKey(c);
      expect(t.keys, unorderedEquals(['T1', 'T2', 'verify-20260402T110000Z/V1', 'verify-20260402T130000Z/V1']));
      expect(t['T1']!.escalated, isTrue);
      expect(t['T1']!.tier0, 'sonnet');
      expect(t['T1']!.tierFinal, 'opus');
      expect(t['T2']!.attempts, 2);
      expect(t['T2']!.passedTier0, isTrue);
      expect(c.escalations, 1);
      expect(c.verifyRuns, 2);
      expect(c.rounds, 4);
      expect(c.runsWithoutTrace, 1);
      expect(c.ignoredLines, 0);
      expect(c.feature, 'Métricas alpha');
      expect(c.status, 'completed');
      expect(c.tasksLabel, '2/2');
      expect(c.date, '2026-04-02');
    });

    test('ciclo sem runs/ fica "sem trace" com feature, data e status', () {
      final c = m.cycles.last;
      expect(c.hasTrace, isFalse);
      expect(c.hasTokens, isFalse);
      expect(c.tasks, isEmpty);
      expect(c.feature, 'Ciclo sem trace');
      expect(c.date, '2026-03-20');
      expect(c.status, 'blocked');
      expect(c.tasksLabel, '1/2');
    });
  });

  group('report.json do histórico', () {
    const validReport = '{"version": 1, "cycle": {"feature": "F", "started_at": "x"}, "stages": []}';

    Future<CycleMetrics> load(String? report, {Map<String, Object?>? extra}) async {
      final home = '${tmp.path}/home';
      final cycle = '$home/projects/p/history/2026-06-01_com-report';
      _write('$cycle/metrics.json', jsonEncode({'feature': 'Com report', 'status': 'completed', ...?extra}));
      if (report != null) _write('$cycle/report.json', report);
      final m = await FileMetricsRepository(home, '${tmp.path}/workflow').loadProject(const Project(name: 'p'));
      return m.cycles.single;
    }

    test('ciclo do fixture com report.json tem hasReport e as etapas; o sem report não', () async {
      final m = await FileMetricsRepository(_fixtures, '$_fixtures/workflow').loadProject(_alpha);

      final withReport = m.cycles.first;
      expect(withReport.hasReport, isTrue);
      expect(withReport.report!.stages.map((s) => s.stage), [Stage.kickoff, Stage.implement]);
      expect(withReport.report!.stage(Stage.implement)!.decisions.single.by, 'agent:T1');
      expect(withReport.warnings, isEmpty);
      expect(m.cycles.last.hasReport, isFalse);
      expect(m.cycles.last.report, isNull);
    });

    test('sem arquivo: sem relatório e sem aviso', () async {
      final c = await load(null);

      expect(c.hasReport, isFalse);
      expect(c.warnings, isEmpty);
    });

    test('inválido ou version 2: sem relatório, o resto do ciclo segue', () async {
      for (final bad in ['{"version": 1, "stages": [', '{"version": 2, "stages": []}', '[]']) {
        final c = await load(bad);
        tmp.deleteSync(recursive: true);
        tmp.createSync();

        expect(c.hasReport, isFalse, reason: bad);
        expect(c.feature, 'Com report');
      }
    });

    test('2 MB exatos valem; 2 MB + 1 byte viram aviso e sem relatório', () async {
      const limit = 2 * 1024 * 1024;
      final exact = validReport.replaceFirst(
        '"stages": []',
        '"pad": "${'a' * (limit - validReport.length - 11)}", "stages": []',
      );
      expect(exact.length, limit);
      expect((await load(exact)).hasReport, isTrue);
      tmp.deleteSync(recursive: true);
      tmp.createSync();

      final c = await load('$exact ');

      expect(c.hasReport, isFalse);
      expect(c.warnings, ['report.json grande demais']);
      expect(c.feature, 'Com report');
    });
  });

  group('ciclo atual', () {
    test('aparece primeiro, "em andamento", com a feature do current.json', () async {
      final wf = '${tmp.path}/workflow';
      _write(
        '$wf/alpha/current.json',
        jsonEncode({
          'feature': 'Em curso',
          'tasks': {'total': 3, 'completed': 1},
        }),
      );
      _write(
        '$wf/alpha/runs/impl-20260501T090000Z/trace.jsonl',
        _trace([
          {
            'persisted_at': '2026-05-01T10:00:00Z',
            'seq': 0,
            'role': 'dev',
            'task': 'T1',
            'tier': 'sonnet',
            'tokens_out': 5,
          },
        ]),
      );
      Directory('$wf/alpha/runs/impl-20260501T100000Z').createSync(recursive: true);

      final m = await FileMetricsRepository(_fixtures, wf).loadProject(_alpha);

      final c = m.cycles.first;
      expect(c.current, isTrue);
      expect(c.status, 'em andamento');
      expect(c.feature, 'Em curso');
      expect(c.tasksLabel, '1/3');
      expect(c.runsWithoutTrace, 1);
      expect(m.cycles, hasLength(3));
      expect(m.completedCycles, 1);
    });

    test('sem current.json usa "ciclo atual"; runs sem trace não criam ciclo', () async {
      final wf = '${tmp.path}/workflow';
      _write(
        '$wf/alpha/runs/impl-1/trace.jsonl',
        _trace([
          {'role': 'g0', 'task': 'T1', 'verdict': 'pass'},
        ]),
      );
      Directory('$wf/beta/runs/impl-1').createSync(recursive: true);
      final repo = FileMetricsRepository('${tmp.path}/home', wf);

      expect((await repo.loadProject(_alpha)).cycles.single.feature, 'ciclo atual');
      expect((await repo.loadProject(const Project(name: 'beta'))).cycles, isEmpty);
    });
  });

  test('trace com 2 MB + 1 byte vira aviso e o resto é calculado sem esse run', () async {
    final home = '${tmp.path}/home';
    final cycle = '$home/projects/p/history/2026-06-01_grande';
    _write('$cycle/metrics.json', jsonEncode({'feature': 'Grande', 'status': 'completed', 'tokens_spent': 999999999}));
    _write(
      '$cycle/runs/impl-1/trace.jsonl',
      _trace([
        {'role': 'dev', 'task': 'T1', 'tier': 'sonnet', 'tokens_out': 1234},
        {'role': 'g0', 'task': 'T1', 'verdict': 'pass'},
      ]),
    );
    File('$cycle/runs/impl-2/trace.jsonl')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(kMetricsFileLimit + 1, 0x20));

    final m = await FileMetricsRepository(home, '${tmp.path}/workflow').loadProject(const Project(name: 'p'));

    final c = m.cycles.single;
    expect(c.warnings, ['trace grande demais: impl-2']);
    expect(c.tokensTotal, 1234);
    expect(c.tasks.single.key, 'T1');
    expect(c.runsWithoutTrace, 0);
  });

  test('ciclo atual com só um trace grande demais aparece com aviso', () async {
    final wf = '${tmp.path}/workflow';
    File('$wf/p/runs/impl-1/trace.jsonl')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(kMetricsFileLimit + 1, 0x20));

    final m = await FileMetricsRepository('${tmp.path}/home', wf).loadProject(const Project(name: 'p'));

    final c = m.cycles.single;
    expect(c.current, isTrue);
    expect(c.warnings, ['trace grande demais: impl-1']);
    expect(c.tasks, isEmpty);
  });

  test('metrics.json inválido vira aviso; projeto sem histórico nem ciclo atual fica vazio', () async {
    final home = '${tmp.path}/home';
    _write('$home/projects/p/history/2026-06-01_x/metrics.json', '{');

    final repo = FileMetricsRepository(home, '${tmp.path}/workflow');
    final c = (await repo.loadProject(const Project(name: 'p'))).cycles.single;

    expect(c.warnings, ['metrics.json inválido']);
    expect(c.feature, 'x');
    expect((await repo.loadProject(const Project(name: 'nada'))).cycles, isEmpty);
  });
}
