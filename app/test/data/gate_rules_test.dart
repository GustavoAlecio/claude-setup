import 'dart:convert';
import 'dart:io';

import 'package:claude_flow/data/flow_aggregates.dart';
import 'package:claude_flow/data/models.dart';
import 'package:claude_flow/data/report_models.dart';
import 'package:claude_flow/data/report_parser.dart';
import 'package:claude_flow/data/session_models.dart';
import 'package:claude_flow/data/session_reducer.dart';
import 'package:claude_flow/data/sse.dart';
import 'package:flutter_test/flutter_test.dart';

ReportDoc _gamma() => parseReport(File('test/fixtures/workflow/gamma/report.json').readAsStringSync())!;

const _summary = SessionSummary(
  id: 's1',
  project: 'gamma',
  command: '/plan',
  title: '/plan',
  status: SessionStatus.waitingPermission,
  createdAt: '2026-03-10T08:00:00Z',
);

Question _q(String text, [List<String> labels = const ['Opção A', 'Opção B']]) =>
    Question(question: text, header: 'Q', options: [for (final l in labels) QuestionOption(l, '')]);

QuestionRequest _request(String id, int seq, List<Question> questions, {bool expired = false}) =>
    QuestionRequest('2026-03-10T08:00:00Z', requestId: id, seq: seq, questions: questions, expired: expired);

SessionDetail _detail(List<SessionEvent> events, {SessionStatus status = SessionStatus.waitingPermission}) =>
    SessionDetail(
      summary: _summary.copyWith(status: status),
      events: events,
    );

GateQuestion _gq(String id, String text, {GateAnswer? answer}) => GateQuestion(id: id, text: text, answer: answer);

const _texts = [
  'Onde guardar o estado da tela gamma?',
  'A rota nova substitui a antiga?',
  'O repositório lê do disco a cada abertura?',
];

void main() {
  late ReportGate plan;
  setUp(() => plan = _gamma().stage(Stage.plan)!.gate!);

  group('matchGateRequest', () {
    test('same question texts in order match', () {
      final r = _request('r1', 3, [for (final t in _texts) _q(t)]);
      expect(matchGateRequest(plan, _detail([r])), same(r));
    });

    test('texts equal up to whitespace match', () {
      final r = _request('r1', 3, [
        _q('  Onde guardar o estado\nda tela   gamma? '),
        _q('A rota nova  substitui a antiga?'),
        _q('\tO repositório lê do disco a cada abertura?'),
      ]);
      expect(matchGateRequest(plan, _detail([r])), same(r));
    });

    test('with 1 of 3 answered, a request with the 2 remaining matches', () {
      final gate = ReportGate(
        name: 'plan',
        status: GateStatus.open,
        questions: [
          _gq('Q1', _texts[0], answer: const GateAnswer(optionId: 'a')),
          _gq('Q2', _texts[1]),
          _gq('Q3', _texts[2]),
        ],
      );
      final partial = _request('r2', 5, [_q(_texts[1]), _q(_texts[2])]);
      final full = _request('r1', 4, [for (final t in _texts) _q(t)]);
      expect(matchGateRequest(gate, _detail([full, partial])), same(partial));
    });

    test('a gate without questions matches the only pending request with Aprovar, Ajustar and Rejeitar', () {
      const gate = ReportGate(name: 'spec', status: GateStatus.open);
      final r = _request('r1', 2, [
        _q('Aprovar a spec?', ['Aprovar (Recomendado)', 'ajustar', 'Rejeitar']),
      ]);
      expect(matchGateRequest(gate, _detail([r])), same(r));
    });

    test('different texts do not match', () {
      final r = _request('r1', 3, [_q(_texts[0]), _q('Outra pergunta?'), _q(_texts[2])]);
      expect(matchGateRequest(plan, _detail([r])), isNull);
    });

    test('a gate that is not open matches nothing', () {
      const gate = ReportGate(
        name: 'plan',
        status: GateStatus.revising,
        questions: [GateQuestion(id: 'Q1', text: 'Onde?')],
      );
      expect(
        matchGateRequest(
          gate,
          _detail([
            _request('r1', 3, [_q('Onde?')]),
          ]),
        ),
        isNull,
      );
    });

    test('an expired request never matches', () {
      final r = _request('r1', 3, [for (final t in _texts) _q(t)], expired: true);
      expect(matchGateRequest(plan, _detail([r])), isNull);
    });

    test('a gate without questions does not match a single request missing the three options', () {
      const gate = ReportGate(name: 'spec', status: GateStatus.open);
      final r = _request('r1', 2, [
        _q('Aprovar a spec?', ['Aprovar', 'Rejeitar']),
      ]);
      expect(matchGateRequest(gate, _detail([r])), isNull);
    });

    test('a gate without questions does not match when two questions are pending', () {
      const gate = ReportGate(name: 'spec', status: GateStatus.open);
      final labels = ['Aprovar', 'Ajustar', 'Rejeitar'];
      final detail = _detail([
        _request('r1', 2, [_q('Aprovar a spec?', labels)]),
        _request('r2', 3, [_q('Aprovar a spec?', labels)]),
      ]);
      expect(matchGateRequest(gate, detail), isNull);
    });

    test('the highest seq wins among several matches', () {
      final old = _request('r1', 3, [for (final t in _texts) _q(t)]);
      final latest = _request('r2', 7, [for (final t in _texts) _q(t)]);
      expect(matchGateRequest(plan, _detail([latest, old])), same(latest));
    });

    test('matches the request the skill builds from the real show output, with rewritten labels', () {
      final show = jsonDecode(File('test/fixtures/show/gamma-plan.json').readAsStringSync()) as Map<String, dynamic>;
      final questions = [
        for (final q in (show['questions'] as List).cast<Map<String, dynamic>>())
          {
            'question': q['question'],
            'header': q['header'],
            'multiSelect': q['multiSelect'],
            'options': [
              for (final o in (q['options'] as List).cast<Map<String, dynamic>>().reversed)
                {'label': o['id'] == 'a' ? '${o['label']} (Recomendado)' : o['label'], 'description': o['description']},
            ],
          },
      ];
      final frame = SseFrame(
        'event',
        jsonEncode({
          'seq': 9,
          'at': '2026-03-10T08:00:00Z',
          'kind': 'permission',
          'requestId': 'req-plan',
          'toolName': 'AskUserQuestion',
          'input': {'questions': questions},
        }),
      );
      final detail = applyFrame(const SessionDetail(summary: _summary), frame);

      final matched = matchGateRequest(plan, detail);

      expect(matched?.requestId, 'req-plan');
      expect(matched!.questions.first.options.last.label, 'Opção A (Recomendado)');
    });
  });

  group('gateScreenState', () {
    final r1 = _request('r1', 3, [_q('Onde?')]);
    const open = ReportGate(name: 'plan', status: GateStatus.open, round: 1);

    test('open with a matched request is deciding; without one and nothing sent, waiting', () {
      expect(gateScreenState(open, r1, null), GateScreenState.deciding);
      expect(gateScreenState(open, null, null), GateScreenState.waiting);
    });

    test('a send of this round is sent, whether the request still matches or no longer does', () {
      const sent = (round: 1, requestId: 'r1');
      expect(gateScreenState(open, r1, sent), GateScreenState.sent);
      expect(gateScreenState(open, null, sent), GateScreenState.sent);
    });

    test('a send of an older round is ignored: a new round with a new request is deciding again', () {
      const round2 = ReportGate(name: 'plan', status: GateStatus.open, round: 2);
      const sent = (round: 1, requestId: 'r1');
      final r2 = _request('r2', 9, [_q('Onde?')]);
      expect(gateScreenState(round2, r2, sent), GateScreenState.deciding);
      expect(gateScreenState(round2, null, sent), GateScreenState.waiting);
    });

    test('revising, and the closed statuses read only', () {
      expect(
        gateScreenState(const ReportGate(name: 'plan', status: GateStatus.revising), null, (round: 1, requestId: 'r1')),
        GateScreenState.revising,
      );
      for (final status in [GateStatus.approved, GateStatus.passed, GateStatus.rejected]) {
        expect(gateScreenState(ReportGate(name: 'plan', status: status), r1, null), GateScreenState.reading);
      }
    });
  });

  group('gateReadingTitle', () {
    test('a decided gate names its outcome', () {
      const titles = {
        'spec': ['Spec aprovada', 'Spec passou sem decisão', 'Spec rejeitada'],
        'plan': ['Plano aprovado', 'Plano passou sem decisão', 'Plano rejeitado'],
        'tasks': ['Tasks aprovadas', 'Tasks passaram sem decisão', 'Tasks rejeitadas'],
      };
      const statuses = [GateStatus.approved, GateStatus.passed, GateStatus.rejected];
      for (final MapEntry(key: gate, value: expected) in titles.entries) {
        for (var i = 0; i < 3; i++) {
          expect(gateReadingTitle(gate, statuses[i], 0), expected[i]);
        }
      }
    });

    test('open and revising keep gateTitle', () {
      expect(gateReadingTitle('plan', GateStatus.open, 3), gateTitle('plan', 3));
      expect(gateReadingTitle('tasks', GateStatus.revising, 0), gateTitle('tasks', 0));
    });
  });

  group('gateTitle', () {
    test('counts the request questions and asks to approve without any', () {
      expect(gateTitle('plan', 3), '3 decisões antes de gerar as tasks');
      expect(gateTitle('tasks', 1), '1 decisão antes de implementar');
      expect(gateTitle('spec', 0), 'Aprovar a spec?');
      expect(gateTitle('spec', 2), '2 decisões antes de planejar');
      expect(gateTitle('plan', 0), 'Aprovar o plano?');
      expect(gateTitle('tasks', 0), 'Aprovar as tasks?');
    });
  });

  test('riskSourceLabel names who raised the risk', () {
    expect(riskSourceLabel('challenger:C3'), 'revisão adversarial');
    expect(riskSourceLabel('critic'), 'crítico');
    expect(riskSourceLabel('author'), 'autor');
    expect(riskSourceLabel(null), isNull);
  });

  group('gate report', () {
    test('only a report of this cycle has gates', () {
      final report = _gamma();
      Cycle cycle({required bool current}) =>
          Cycle(stage: Stage.plan, runs: const [], stageMinutes: const {}, report: report, reportIsCurrent: current);
      expect(gateReport(cycle(current: true)), same(report));
      expect(gateReport(cycle(current: false)), isNull);
      expect(gateReport(null), isNull);
    });

    test('open and passed gates come from their owner stage, in pipeline order', () {
      final report = _gamma();
      expect(openGates(report).map((s) => (s.stage, s.gate!.name)), [(Stage.challenge, 'spec'), (Stage.plan, 'plan')]);
      expect(passedGates(report).map((s) => (s.stage, s.gate!.name)), [(Stage.tasks, 'tasks')]);
      expect(openGates(null), isEmpty);
    });

    test('a session running several stages takes the first open gate in pipeline order', () {
      const report = ReportDoc(
        feature: 'f',
        startedAt: null,
        stages: [
          StageReport(
            stage: Stage.challenge,
            status: ReportStatus.done,
            sessionId: 's1',
            gate: ReportGate(name: 'spec', status: GateStatus.approved),
          ),
          StageReport(
            stage: Stage.plan,
            status: ReportStatus.running,
            sessionId: 's1',
            gate: ReportGate(name: 'plan', status: GateStatus.open),
          ),
          StageReport(
            stage: Stage.complete,
            status: ReportStatus.running,
            sessionId: 's2',
            gate: ReportGate(name: 'pr', status: GateStatus.open),
          ),
        ],
      );
      expect(sessionGate(report, 's1')?.name, 'plan');
      expect(sessionGate(report, 's2'), isNull);
      expect(sessionGate(report, 'ghost'), isNull);
    });

    test('withoutOpenGateSessions drops the sessions of open spec, plan and tasks gates', () {
      const report = ReportDoc(
        feature: 'f',
        startedAt: null,
        stages: [
          StageReport(
            stage: Stage.challenge,
            status: ReportStatus.running,
            sessionId: 's-spec',
            gate: ReportGate(name: 'spec', status: GateStatus.open),
          ),
          StageReport(
            stage: Stage.plan,
            status: ReportStatus.done,
            sessionId: 's-plan',
            gate: ReportGate(name: 'plan', status: GateStatus.passed),
          ),
          StageReport(
            stage: Stage.complete,
            status: ReportStatus.running,
            sessionId: 's-pr',
            gate: ReportGate(name: 'pr', status: GateStatus.open),
          ),
        ],
      );
      SessionSummary s(String id) => SessionSummary(
        id: id,
        project: 'gamma',
        command: '/plan',
        title: id,
        status: SessionStatus.waitingPermission,
        createdAt: '2026-03-10T08:00:00Z',
      );
      final all = [s('s-spec'), s('s-plan'), s('s-pr'), s('s-free')];
      expect(withoutOpenGateSessions(all, report).map((x) => x.id), ['s-plan', 's-pr', 's-free']);
      expect(withoutOpenGateSessions(all, null), all);
    });

    test('gateLocation', () {
      expect(gateLocation('gamma', 'plan'), '/p/gamma/gate/plan');
    });
  });

  group('gateWaitReason', () {
    test('says why an open gate has nothing to answer', () {
      expect(gateWaitReason(null, null), GateWaitReason.terminal);
      expect(gateWaitReason('s1', null), GateWaitReason.notArrived);
      expect(gateWaitReason('s1', _detail(const [], status: SessionStatus.running)), GateWaitReason.notArrived);
      const permission = PermissionRequest(
        '2026-03-10T08:00:00Z',
        requestId: 'p1',
        seq: 2,
        toolName: 'Bash',
        target: 'ls',
      );
      expect(gateWaitReason('s1', _detail([permission])), GateWaitReason.otherRequest);
      expect(gateWaitReason('s1', _detail([permission], status: SessionStatus.done)), GateWaitReason.sessionEnded);
    });
  });

  group('afterGateRoute', () {
    const gate = '/p/gamma/gate/plan';

    test('goes to the pending item after the gate, never to the gate itself', () {
      expect(
        afterGateRoute(['/p/gamma/sessions/1', gate, '/p/gamma/sessions/2'], gate, 'gamma'),
        '/p/gamma/sessions/2',
      );
      expect(afterGateRoute(['/p/gamma/sessions/1', gate], gate, 'gamma'), '/p/gamma/sessions/1');
      expect(afterGateRoute(['/p/gamma/sessions/1', '/p/gamma/sessions/2'], gate, 'gamma'), '/p/gamma/sessions/1');
    });

    test('pending items of other projects or orgs never count', () {
      expect(afterGateRoute(['/p/a/sessions/1', gate, '/p/b/sessions/2'], gate, 'gamma'), '/p/gamma/flow');
      expect(afterGateRoute(['/o/acme/sessions?session=1'], gate, 'gamma'), '/p/gamma/flow');
      expect(afterGateRoute(['/p/gamma2/sessions/1', '/p/a/gate/plan'], gate, 'gamma'), '/p/gamma/flow');
      expect(afterGateRoute(['/p/a/sessions/1', '/p/gamma/sessions/2'], gate, 'gamma'), '/p/gamma/sessions/2');
    });

    test('without other pending items, the project Fluxo', () {
      expect(afterGateRoute(const [], gate, 'gamma'), '/p/gamma/flow');
      expect(afterGateRoute(const [gate], gate, 'gamma'), '/p/gamma/flow');
    });
  });
}
