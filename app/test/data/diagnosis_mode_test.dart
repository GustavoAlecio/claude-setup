import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

TaskRun _task(String id, Verdict status) =>
    TaskRun(id: id, title: id, complexity: Complexity.m, tier0: Tier.sonnet, status: status);

Run _run(String id, List<TaskRun> tasks) =>
    Run(id: id, kind: 'implement', status: Verdict.blocked, startedAt: '', tasks: tasks);

SessionSummary _session(
  String id,
  String command, {
  String project = 'alpha',
  SessionStatus status = SessionStatus.running,
  int pending = 0,
  String? org,
}) => SessionSummary(
  id: id,
  project: project,
  command: command,
  title: command,
  status: status,
  createdAt: '2026-03-10T10:00:00Z',
  org: org,
  pendingPermissions: pending,
);

void main() {
  group('diagnosisMode', () {
    final blocked = _task('T2', Verdict.blocked);
    final run = _run('impl-2', [_task('T1', Verdict.pass), blocked]);
    final project = Project(
      name: 'alpha',
      cycle: Cycle(stage: Stage.implement, stageMinutes: const {}, runs: [run]),
    );

    DiagnosisMode mode(List<SessionSummary> sessions, {Project? p, TaskRun? task, Run? r}) =>
        diagnosisMode(p ?? project, task ?? blocked, r ?? run, sessions);

    test('inert without a project', () {
      expect(diagnosisMode(null, blocked, run, const []), (kind: DiagnosisKind.inert, route: null));
    });

    test('inert for a task of an old run, matched by id', () {
      final old = _run('impl-1', [_task('T2', Verdict.blocked)]);
      expect(mode(const [], r: old, task: old.tasks.single).kind, DiagnosisKind.inert);
      expect(mode(const [], task: _task('T1', Verdict.blocked)).kind, DiagnosisKind.inert);
    });

    test('inert while the cycle is paused', () {
      final paused = Project(
        name: 'alpha',
        cycle: Cycle(stage: Stage.implement, stageMinutes: const {}, runs: [run], pausedAt: DateTime.utc(2026, 3, 10)),
      );
      expect(mode(const [], p: paused).kind, DiagnosisKind.inert);
    });

    test('answer points to the live pipeline session holding a request', () {
      final m = mode([_session('s', '/plan', pending: 1)]);
      expect(m, (kind: DiagnosisKind.answer, route: '/p/alpha/sessions/s'));
    });

    test('busy for a live pipeline session without request', () {
      expect(mode([_session('s', '/implement', status: SessionStatus.idle)]), (kind: DiagnosisKind.busy, route: null));
    });

    test('launch without a live pipeline session', () {
      expect(mode(const []), (kind: DiagnosisKind.launch, route: null));
      expect(mode([_session('s', '/plan', status: SessionStatus.done)]).kind, DiagnosisKind.launch);
      expect(mode([_session('s', '/plan', project: 'beta', pending: 1)]).kind, DiagnosisKind.launch);
      expect(mode([_session('s', '/plan', org: 'acme', pending: 1)]).kind, DiagnosisKind.launch);
    });

    test('busy for a starting pipeline session', () {
      expect(mode([_session('s', '/plan', status: SessionStatus.starting)]), (kind: DiagnosisKind.busy, route: null));
    });

    test('a conversation outside the pipeline with a request does not change the mode', () {
      expect(mode([_session('s', 'me explica o repo', pending: 2)]).kind, DiagnosisKind.launch);
      expect(mode([_session('s', 'me explica o repo', pending: 2), _session('p', '/plan', pending: 1)]), (
        kind: DiagnosisKind.answer,
        route: '/p/alpha/sessions/p',
      ));
    });
  });
}
