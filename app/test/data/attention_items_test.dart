import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/attention.dart';
import 'package:claude_flow/data/mock_flow_repository.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _session(
  String id, {
  String project = 'gamma',
  String? org,
  int pending = 1,
  SessionStatus status = SessionStatus.waitingPermission,
}) => SessionSummary(
  id: id,
  project: project,
  org: org,
  command: 'c',
  title: 'título $id',
  status: status,
  createdAt: '',
  pendingPermissions: pending,
);

/// The gamma fixture with its open `plan` gate run by `s-plan`.
Project _gammaWithPlanGate() {
  final doc = jsonDecode(File('test/fixtures/workflow/gamma/report.json').readAsStringSync()) as Map<String, dynamic>;
  final plan = (doc['stages'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['stage'] == 'plan');
  plan['session_id'] = 's-plan';
  return Project(
    name: 'gamma',
    cycle: Cycle(
      stage: Stage.plan,
      runs: const [],
      stageMinutes: const {},
      report: parseReport(jsonEncode(doc)),
      reportIsCurrent: true,
    ),
  );
}

void main() {
  group('pendingAttention', () {
    test('a session on an open gate is a gate item with the gate route', () {
      final items = pendingAttention([_session('s-plan', pending: 2)], [_gammaWithPlanGate()]);
      final item = items.single;
      expect(item.kind, AttentionKind.gate);
      expect(item.gate, 'plan');
      expect(item.project, 'gamma');
      expect(item.sessionId, 's-plan');
      expect(item.pending, 2);
      expect(item.key, 'pending:s-plan:2');
      expect(item.title, 'Aguardando você · gamma');
      expect(item.body, 'título s-plan');
      expect(item.route, '/p/gamma/gate/plan');
    });

    test('a request outside a gate is a request item with the session route', () {
      final item = pendingAttention([_session('s-other', pending: 3)], [_gammaWithPlanGate()]).single;
      expect(item.kind, AttentionKind.request);
      expect(item.gate, isNull);
      expect(item.project, 'gamma');
      expect(item.sessionId, 's-other');
      expect(item.pending, 3);
      expect(item.key, 'pending:s-other:3');
      expect(item.title, 'Aguardando você · gamma');
      expect(item.body, 'título s-other');
      expect(item.route, '/p/gamma/sessions/s-other');
    });

    test('an org session has no project', () {
      final item = pendingAttention([_session('s-org', project: '', org: 'acme')], const []).single;
      expect(item.kind, AttentionKind.request);
      expect(item.project, isNull);
      expect(item.sessionId, 's-org');
      expect(item.pending, 1);
      expect(item.gate, isNull);
      expect(item.key, 'pending:s-org:1');
      expect(item.title, 'Aguardando você · acme');
      expect(item.route, '/o/acme/sessions/s-org');
    });

    test('a blocked decision is a blocked item without session', () {
      final item = pendingAttention(const [], MockFlowRepository().projects).single;
      expect(item.kind, AttentionKind.blocked);
      expect(item.project, 'demo-app');
      expect(item.sessionId, isNull);
      expect(item.pending, 0);
      expect(item.gate, isNull);
      expect(item.key, 'blocked:demo-app:impl-20261001T141210Z:T4');
      expect(item.title, 'Ciclo parado · demo-app');
      expect(item.body, 'T4 · Sincronização offline com fila de mutações: o diagnóstico espera a sua decisão');
      expect(item.route, '/p/demo-app/runs/impl-20261001T141210Z/T4');
    });
  });

  group('finishedTurns', () {
    test('a finished turn is a finished item with project and session', () {
      final now = [
        _session('s1', pending: 0, status: SessionStatus.idle),
        _session('s2', project: '', org: 'acme', pending: 0, status: SessionStatus.done),
      ];
      final items = finishedTurns({'s1': SessionStatus.running, 's2': SessionStatus.running}, now);
      expect(items.map((i) => i.kind), [AttentionKind.finished, AttentionKind.finished]);
      expect(items[0].project, 'gamma');
      expect(items[0].sessionId, 's1');
      expect(items[0].pending, 0);
      expect(items[0].gate, isNull);
      expect(items[0].key, startsWith('done:s1:'));
      expect(items[0].title, 'Turno concluído · gamma');
      expect(items[0].body, 'título s1');
      expect(items[0].route, '/p/gamma/sessions/s1');
      expect(items[1].project, isNull);
      expect(items[1].sessionId, 's2');
      expect(items[1].route, '/o/acme/sessions/s2');
    });
  });

  group('AttentionSnapshot.of', () {
    test('reads sessionId and pending, not the key', () {
      final snap = AttentionSnapshot.of(const [
        AttentionItem(
          key: 'opaque',
          title: '',
          body: '',
          route: '/',
          kind: AttentionKind.gate,
          sessionId: 'a:b',
          pending: 4,
          gate: 'plan',
        ),
        AttentionItem(key: 'k1', title: '', body: '', route: '/', kind: AttentionKind.blocked, project: 'p'),
        AttentionItem(
          key: 'pending:x:9',
          title: '',
          body: '',
          route: '/',
          kind: AttentionKind.finished,
          sessionId: 'x',
        ),
      ]);
      expect(snap.pending, {'a:b': 4});
      expect(snap.blocked, {'k1'});
    });
  });
}
