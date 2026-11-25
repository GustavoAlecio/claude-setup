import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/config_cubit.dart';
import '../../app/projects_cubit.dart';
import '../../app/sessions_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/attention.dart';
import '../../data/docs_models.dart';
import '../../data/docs_repository.dart';
import '../../data/flow_aggregates.dart';
import '../../data/models.dart';
import '../../data/orgs.dart';
import '../../data/report_models.dart';
import '../../data/session_models.dart';
import '../../data/session_reducer.dart';
import '../../data/sessions_repository.dart';
import '../reviews/reviews_diff.dart';
import '../sessions/session_cubit.dart';
import '../sessions/session_view.dart';
import 'gate_diff.dart';
import 'gate_map.dart';
import 'report_extras.dart';

const _kMinTarget = 44.0;
const _kMaxWidth = 760.0;

/// A gate in focus, outside the shell: summary and risks before the choices. It draws and sends
/// the options of the session's pending `AskUserQuestion`, never the block's, so the labels match what the skill
/// expects back.
class GatePage extends StatefulWidget {
  const GatePage({super.key, required this.project, required this.gate, required this.backTo});

  final String project;

  /// `gate.name` from the route; anything outside [kGateOwner] is unavailable.
  final String gate;

  /// Last shell route visited, the base of "Voltar".
  final String Function() backTo;

  @override
  State<GatePage> createState() => _GatePageState();
}

typedef _DiffKey = ({String project, String gate, int round});

class _GatePageState extends State<GatePage> {
  GateSent? _sent;
  bool _leaving = false;

  /// `pr.diff` of the round on screen: `null` data once read means unavailable. Kept here, above the screen states,
  /// so rebuilds and a recreated form never read it again; only a new round does, since `/complete` rewrites it.
  _DiffKey? _diffKey;
  AsyncSnapshot<List<DiffFile>?> _diff = const AsyncSnapshot.nothing();

  void _watchDiff(String project, ReportGate gate) {
    final key = (project: project, gate: gate.name, round: gate.round);
    if (key == _diffKey) return;
    _diffKey = key;
    _diff = const AsyncSnapshot.waiting();
    final repository = DocsScope.of(context);
    unawaited(() async {
      final files = switch (await repository.read(project, 'pr.diff')) {
        DocText(:final String text) => await parseDiffText(text, text.length),
        _ => null,
      };
      if (!mounted || _diffKey != key) return;
      setState(() => _diff = AsyncSnapshot.withData(ConnectionState.done, files));
    }());
  }

  String get _location => gateLocation(widget.project, widget.gate);

  Future<void> _send(String sessionId, QuestionRequest request, int round, Map<String, String> answers) {
    final sessions = SessionsScope.of(context);
    return sessionAction(context, () async {
      await sessions.answer(sessionId, request.requestId, PermissionDecision.answer, answers: answers);
      if (mounted) setState(() => _sent = (round: round, requestId: request.requestId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final projects = context.watch<ProjectsCubit>().state.data;
    final config = context.watch<ConfigCubit>().state.data;
    final sessions = context.watch<SessionsCubit>().state.data ?? const <SessionSummary>[];
    // Only what can be answered: a gate without a conversation is not a step of this walk.
    final items = [
      if (projects != null)
        for (final i in pendingAttention(sessions, projects))
          if (!i.isOrphanGate) i,
    ];
    final header = _Header(
      onBack: () => context.go(gateBackTarget(widget.project, widget.backTo(), config, projects)),
      items: items,
      location: _location,
    );
    final owner = kGateOwner[widget.gate];
    if (owner == null) return _Frame(header: header, child: const _Unavailable());
    if (projects == null) return _Frame(header: header, child: const _Loading());
    final project = projects.where((p) => p.name == widget.project).firstOrNull;
    final stage = gateReport(project?.cycle)?.stage(owner);
    final gate = stage?.gate;
    if (project == null || stage == null || gate == null || gate.name != widget.gate) {
      return _Frame(header: header, child: const _Unavailable());
    }
    if (gate.name == 'pr') _watchDiff(project.name, gate);
    final sessionId = stage.sessionId;
    Widget body(SessionDetail? detail) =>
        _body(project, stage, gate, sessionId, detail, [for (final i in items) i.route]);
    return _Frame(
      header: header,
      child: sessionId == null
          ? body(null)
          : BlocProvider(
              key: ValueKey(sessionId),
              create: (_) => SessionCubit(SessionsScope.of(context), sessionId),
              child: BlocBuilder<SessionCubit, AsyncSnapshot<SessionDetail>>(
                builder: (context, snapshot) => body(snapshot.data),
              ),
            ),
    );
  }

  Widget _body(
    Project project,
    StageReport stage,
    ReportGate gate,
    String? sessionId,
    SessionDetail? detail,
    List<String> pendingRoutes,
  ) {
    final matched = detail == null ? null : matchGateRequest(gate, detail);
    final state = gateScreenState(gate, matched, _sent);
    _leaveOnApproval(state, gate, pendingRoutes);
    final questions = state == GateScreenState.deciding && gate.questions.isNotEmpty
        ? matched!.questions.length
        : gate.questions.length;
    final leading = [
      _ContextLine(project: project, stage: stage.stage, gate: gate),
      const SizedBox(height: 14),
      Text(
        gateReadingTitle(gate.name, gate.status, questions),
        key: const ValueKey('gate-title'),
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      Text(
        gate.summary,
        key: const ValueKey('gate-summary'),
        style: TextStyle(fontSize: 14, height: 1.5, color: context.colors.textPrimary),
      ),
      if (gate.map case final map?) ..._mapSections(map, sessionId == null ? null : detail?.summary),
      if (gate.risks.isNotEmpty) ...[const SizedBox(height: 20), _Risks(gate.risks)],
      if (gate.round >= 2) ..._previousRound(gate),
    ];
    final pr = gate.name == 'pr';
    final points = pr && gate.questions.isNotEmpty;
    final link = pr ? gateReport(project.cycle)?.pr : null;
    final files = pr ? _diff.data : null;
    final full = [
      if (files != null) ...[
        const SizedBox(height: 24),
        GateDiffFull(key: const ValueKey('gate-diff-full'), files: files),
      ],
    ];
    return switch (state) {
      GateScreenState.deciding => _GateForm(
        key: ValueKey(matched!.requestId),
        request: matched,
        approval: gate.questions.isEmpty,
        leading: leading,
        omitted: gate.omitted,
        artifactLocation: pr || gate.artifact == null
            ? null
            : Uri(
                pathSegments: ['', 'p', project.name, 'artifacts'],
                queryParameters: {'doc': gate.artifact},
              ).toString(),
        points: points ? [for (final q in matched.questions) blockQuestion(gate, q.question)] : null,
        diff: _diff,
        trailing: full,
        onSend: (answers) => _send(sessionId!, matched, gate.round, answers),
      ),
      GateScreenState.sent => _Scroll([
        ...leading,
        const SizedBox(height: 24),
        const _Notice(key: ValueKey('gate-sent'), icon: Icons.hourglass_empty, text: 'registrando suas respostas'),
      ]),
      GateScreenState.revising when pr => _Scroll([
        ...leading,
        const SizedBox(height: 24),
        ..._prRevising(gate, project.cycle?.plan ?? const [], link),
      ]),
      GateScreenState.revising => _Scroll([
        ...leading,
        const SizedBox(height: 24),
        const _Notice(key: ValueKey('gate-revising'), icon: Icons.edit_note, text: 'revisando com as suas escolhas'),
        ..._answered(gate),
      ]),
      GateScreenState.reading => _Scroll([
        ...leading,
        if (points) ..._points(gate, answers: true) else ..._answered(gate),
        if (link != null) ...[const SizedBox(height: 20), PrPanel(pr: link)],
        ...full,
      ]),
      GateScreenState.waiting => _Scroll([
        ...leading,
        const SizedBox(height: 24),
        _WaitReason(reason: gateWaitReason(sessionId, detail), session: detail?.summary),
        if (points) ..._points(gate, answers: false),
        ...full,
      ]),
    };
  }

  /// Only a send of this visit, in the gate's current round, that the report then approves moves on; a rejection
  /// stays readable.
  void _leaveOnApproval(GateScreenState state, ReportGate gate, List<String> pendingRoutes) {
    if (_leaving || _sent?.round != gate.round || state != GateScreenState.reading) return;
    if (gate.status != GateStatus.approved) return;
    _leaving = true;
    final target = afterGateRoute(pendingRoutes, _location, widget.project);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go(target);
    });
  }

  /// The map, then the ways to do it and their trade-offs on a plan map. [session] is the stage's session once its
  /// detail arrived: only then the side question is offered.
  List<Widget> _mapSections(GateMap map, SessionSummary? session) {
    final c = context.colors;
    final legend = mapLegend(map);
    final diff = map.built ? builtDiffNodes(map) : const <MapNode>[];
    final same = map.built ? builtSameLine(map) : null;
    final approaches = [...map.approaches.where((a) => a.chosen), ...map.approaches.where((a) => !a.chosen)];
    return [
      const SizedBox(height: 20),
      _Section(
        key: const ValueKey('gate-map'),
        title: map.built ? 'O que foi construído' : 'Como isso vai ser construído',
        children: [
          if (map.summary.isNotEmpty) ...[
            Text(map.summary, style: TextStyle(fontSize: 13, height: 1.45, color: c.textPrimary)),
            const SizedBox(height: 14),
          ],
          GateMapView(map: map),
          if (map.edges.any((e) => e.label?.isNotEmpty ?? false)) ...[
            const SizedBox(height: 12),
            GateMapEdgeList(map: map),
          ],
          if (legend.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              key: const ValueKey('gate-map-legend'),
              spacing: 16,
              runSpacing: 6,
              children: [for (final item in legend) _LegendItem(word: item.word, color: mapToneColor(c, item.tone))],
            ),
          ],
          if (diff.isNotEmpty) ...[
            const SizedBox(height: 16),
            Column(
              key: const ValueKey('gate-map-diff'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Muted('Diferente do plano', size: 11),
                const SizedBox(height: 6),
                for (final n in diff)
                  _Bullet(
                    [
                      n.label,
                      ?mapNodeLook(n).word,
                      if (n.files.isNotEmpty) countLabel(n.files.length, 'arquivo'),
                    ].join(' · '),
                  ),
              ],
            ),
          ],
          if (same != null) ...[
            const SizedBox(height: 10),
            Column(
              key: const ValueKey('gate-map-same'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Muted('Igual ao plano', size: 11),
                const SizedBox(height: 6),
                Text(same, style: TextStyle(fontSize: 13, color: c.textPrimary)),
              ],
            ),
          ],
          if (session != null && session.canAskAside)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('gate-map-talk'),
                style: TextButton.styleFrom(foregroundColor: c.textSecondary, minimumSize: const Size(0, _kMinTarget)),
                onPressed: () => unawaited(showAsideQuestion(context, session)),
                child: const Text('não entendi, quero perguntar', style: TextStyle(fontSize: 12.5)),
              ),
            )
          else
            const SizedBox(height: 8),
        ],
      ),
      if (approaches.isNotEmpty) ...[
        const SizedBox(height: 20),
        _Section(
          key: const ValueKey('gate-map-approaches'),
          title: 'Formas de fazer',
          children: [for (final a in approaches) _ApproachRow(approach: a)],
        ),
      ],
      if (map.gains.isNotEmpty || map.costs.isNotEmpty) ...[
        const SizedBox(height: 20),
        _Section(
          key: const ValueKey('gate-map-tradeoffs'),
          title: 'O que você ganha e o que abre mão',
          children: [
            if (map.gains.isNotEmpty) ...[
              const Muted('Ganha', size: 11.5),
              const SizedBox(height: 4),
              for (final g in map.gains) _Bullet(g),
            ],
            if (map.costs.isNotEmpty) ...[
              if (map.gains.isNotEmpty) const SizedBox(height: 6),
              const Muted('Abre mão', size: 11.5),
              const SizedBox(height: 4),
              for (final cost in map.costs) _Bullet(cost),
            ],
          ],
        ),
      ],
    ];
  }

  List<Widget> _previousRound(ReportGate gate) {
    final previous = gate.history.lastOrNull;
    final chosen = [
      for (final q in previous?.questions ?? const <GateQuestion>[])
        if (_answerLabel(q) case final label?) (q.text, label),
      if (previous != null && previous.questions.isEmpty)
        if (previous.answer?.text case final text? when text.trim().isNotEmpty) ('Ajuste', text),
    ];
    return [
      if (chosen.isNotEmpty) ...[
        const SizedBox(height: 20),
        _Section(
          key: const ValueKey('gate-history'),
          title: 'Você escolheu',
          children: [for (final (text, label) in chosen) _AnswerRow(question: text, answer: label)],
        ),
      ],
      if (gate.changes.isNotEmpty) ...[
        const SizedBox(height: 20),
        _Section(
          key: const ValueKey('gate-changes'),
          title: 'O que mudou',
          children: [for (final line in gate.changes) _Bullet(line)],
        ),
      ],
    ];
  }

  /// The block's `pr` points, read-only: no options, and with [answers] the answer given to each.
  List<Widget> _points(ReportGate gate, {required bool answers}) => [
    const SizedBox(height: 24),
    Column(
      key: const ValueKey('gate-points'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, q) in gate.questions.indexed) ...[
          if (i > 0) const SizedBox(height: 16),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PointHead(index: i, text: q.text, block: q, diff: _diff, color: context.colors.textSecondary),
                if (answers)
                  if (_answerLabel(q) case final label?) ...[
                    const SizedBox(height: 12),
                    _AnswerRow(key: ValueKey('gate-point-$i-answer'), question: 'Resposta', answer: label),
                  ],
              ],
            ),
          ),
        ],
      ],
    ),
  ];

  /// After the send: the PR link when there is one, else that the cycle went back to implementation; then what was
  /// asked. Without questions the adjustment goes through `/fix`, so no task is counted.
  List<Widget> _prRevising(ReportGate gate, List<TaskRun> plan, ReportPr? link) {
    final c = context.colors;
    if (gate.questions.isEmpty) {
      return [
        if (link != null) ...[PrPanel(pr: link), const SizedBox(height: 16)],
        const _Notice(key: ValueKey('gate-revising'), icon: Icons.edit_note, text: 'ajuste pedido'),
        if (gate.answer?.text case final text? when text.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            text,
            key: const ValueKey('gate-adjust'),
            style: TextStyle(fontSize: 13, color: c.textPrimary),
          ),
        ],
        const SizedBox(height: 8),
        const _Notice(icon: Icons.terminal, text: 'aplique com /fix na sessão'),
      ];
    }
    final asked = [
      for (final q in gate.questions)
        if (q.answer?.optionId != 'ok')
          if (_answerLabel(q) case final label?) _AnswerRow(question: q.text, answer: label),
    ];
    final count = prTaskCountLine(plan, gate.round);
    return [
      if (link != null)
        PrPanel(pr: link)
      else
        const _Notice(key: ValueKey('gate-revising'), icon: Icons.edit_note, text: 'voltou à implementação'),
      if (asked.isNotEmpty) ...[
        const SizedBox(height: 20),
        _Section(key: const ValueKey('gate-asked'), title: 'Pedido', children: asked),
      ],
      if (count.isNotEmpty) ...[
        const SizedBox(height: 12),
        Muted(count, key: const ValueKey('gate-task-count'), size: 12.5),
      ],
    ];
  }

  List<Widget> _answered(ReportGate gate) {
    final rows = [
      for (final q in gate.questions)
        if (_answerLabel(q) case final label?) _AnswerRow(question: q.text, answer: label),
      if (gate.answer?.text case final text? when text.trim().isNotEmpty) _AnswerRow(question: 'Ajuste', answer: text),
    ];
    if (rows.isEmpty) return const [];
    return [
      const SizedBox(height: 20),
      _Section(key: const ValueKey('gate-answers'), title: 'Respostas', children: rows),
    ];
  }
}

/// Free text wins over the option, as when it was sent.
String? _answerLabel(GateQuestion q) {
  final answer = q.answer;
  if (answer == null) return null;
  if (answer.text case final text? when text.trim().isNotEmpty) return text;
  return q.options.where((o) => o.id == answer.optionId).firstOrNull?.label ?? answer.optionId;
}

class _Frame extends StatelessWidget {
  const _Frame({required this.header, required this.child});

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(child: child),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack, required this.items, required this.location});

  final VoidCallback onBack;
  final List<AttentionItem> items;
  final String location;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final path = Uri.parse(location).path;
    final at = items.indexWhere((i) => Uri.parse(i.route).path == path);
    final next = nextAttentionRoute(items, location);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, kTitleBarInset, 20, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('gate-back'),
            style: TextButton.styleFrom(foregroundColor: c.textSecondary, minimumSize: const Size(0, _kMinTarget)),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Voltar', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
          if (at >= 0) Muted('Pendência ${at + 1} de ${items.length}', key: const ValueKey('gate-position')),
          if (items.length > 1 && next != null) ...[
            const SizedBox(width: 12),
            TextButton(
              key: const ValueKey('gate-skip'),
              style: TextButton.styleFrom(foregroundColor: c.textSecondary, minimumSize: const Size(0, _kMinTarget)),
              onPressed: () => context.go(next),
              child: const Text('Pular', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink(key: ValueKey('gate-loading'));
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) =>
      const Center(key: ValueKey('gate-unavailable'), child: Muted('gate indisponível', size: 13));
}

/// One centered column, wide enough to read and no wider.
class _Column extends StatelessWidget {
  const _Column({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _kMaxWidth),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );
}

class _Scroll extends StatelessWidget {
  const _Scroll(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
    child: _Column(children: children),
  );
}

class _ContextLine extends StatelessWidget {
  const _ContextLine({required this.project, required this.stage, required this.gate});

  final Project project;
  final Stage stage;
  final ReportGate gate;

  @override
  Widget build(BuildContext context) => Mono(
    [
      project.name,
      if (project.cycle?.report?.feature ?? project.cycle?.feature case final feature? when feature.isNotEmpty) feature,
      stage.label,
      if (gate.round >= 2) 'rodada ${gate.round}',
    ].join(' · '),
    key: const ValueKey('gate-context'),
  );
}

class _Risks extends StatelessWidget {
  const _Risks(this.risks);

  final List<GateRisk> risks;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _Section(
      key: const ValueKey('gate-risks'),
      title: 'Riscos',
      children: [
        for (final r in risks)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(r.text, style: TextStyle(fontSize: 13, color: c.textPrimary)),
                ),
                if (riskSourceLabel(r.source) case final source?) ...[
                  const SizedBox(width: 10),
                  Pill(label: source, color: c.textSecondary, dot: false),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Muted(title, size: 11), const SizedBox(height: 8), ...children],
    ),
  );
}

class _AnswerRow extends StatelessWidget {
  const _AnswerRow({super.key, required this.question, required this.answer});

  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
          const SizedBox(height: 2),
          Text(answer, style: TextStyle(fontSize: 13, color: c.textPrimary)),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text('· $text', style: TextStyle(fontSize: 13, color: context.colors.textPrimary)),
  );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.word, required this.color});

  final String word;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color, width: 1.5),
        ),
      ),
      const SizedBox(width: 6),
      Text(word, style: TextStyle(fontSize: 12, color: context.colors.textSecondary)),
    ],
  );
}

class _ApproachRow extends StatelessWidget {
  const _ApproachRow({required this.approach});

  final MapApproach approach;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  approach.label,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(approach.text, style: TextStyle(fontSize: 12.5, height: 1.4, color: c.textSecondary)),
              ],
            ),
          ),
          if (approach.chosen) ...[
            const SizedBox(width: 10),
            Pill(label: 'escolhida', color: c.textSecondary, dot: false),
          ],
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, size: 16, color: c.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, color: c.textSecondary)),
        ),
      ],
    );
  }
}

class _WaitReason extends StatelessWidget {
  const _WaitReason({required this.reason, required this.session});

  final GateWaitReason reason;
  final SessionSummary? session;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    final c = context.colors;
    return Column(
      key: const ValueKey('gate-waiting'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Notice(
          icon: Icons.schedule,
          text: switch (reason) {
            GateWaitReason.otherRequest => 'a sessão espera outra resposta',
            GateWaitReason.sessionEnded => 'sessão encerrada, retome em Sessões',
            GateWaitReason.terminal => 'a etapa rodou no terminal, sem sessão no app',
            GateWaitReason.notArrived => 'a pergunta ainda não chegou',
          },
        ),
        if (reason == GateWaitReason.otherRequest && session != null) ...[
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('gate-open-session'),
            style: TextButton.styleFrom(foregroundColor: c.textPrimary, minimumSize: const Size(0, _kMinTarget)),
            onPressed: () => context.go(sessionLocation(session)),
            child: const Text('abrir a conversa', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ],
    );
  }
}

bool _isAdjust(String label) => label.trim().toLowerCase().startsWith('ajustar');

/// Number and text of a `pr` point, then its why, anchor and excerpt from the [block] question of the same text.
class _PointHead extends StatelessWidget {
  const _PointHead({
    required this.index,
    required this.text,
    required this.block,
    required this.diff,
    required this.color,
  });

  final int index;
  final String text;
  final GateQuestion? block;
  final AsyncSnapshot<List<DiffFile>?> diff;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final block = this.block;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${index + 1}',
              key: ValueKey('gate-q-$index-number'),
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                key: ValueKey('gate-point-$index-text'),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textPrimary),
              ),
            ),
          ],
        ),
        if (block?.why case final why? when why.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            why,
            key: ValueKey('gate-point-$index-why'),
            style: TextStyle(fontSize: 13, height: 1.45, color: c.textSecondary),
          ),
        ],
        if (block?.anchor case final anchor?) ...[
          const SizedBox(height: 10),
          GatePointDiff(index: index, anchor: anchor, diff: diff),
        ],
      ],
    );
  }
}

/// The questions of one request. Keyed by its `requestId`, so a new round starts with nothing picked.
class _GateForm extends StatefulWidget {
  const _GateForm({
    super.key,
    required this.request,
    required this.approval,
    required this.leading,
    required this.omitted,
    required this.artifactLocation,
    required this.onSend,
    this.points,
    this.diff = const AsyncSnapshot.nothing(),
    this.trailing = const [],
  });

  final QuestionRequest request;

  /// A gate without questions: Ajustar only counts with text.
  final bool approval;
  final List<Widget> leading;
  final GateOmitted omitted;
  final String? artifactLocation;
  final Future<void> Function(Map<String, String> answers) onSend;

  /// On a `pr` gate with questions, the block question of each request question, by position; `null` elsewhere.
  /// A point has no free answer: its change option asks for text instead.
  final List<GateQuestion?>? points;
  final AsyncSnapshot<List<DiffFile>?> diff;

  /// Below the questions; reading the full diff never changes what the send asks.
  final List<Widget> trailing;

  @override
  State<_GateForm> createState() => _GateFormState();
}

class _GateFormState extends State<_GateForm> {
  final _picked = <String, String>{};
  late final _free = {for (final q in widget.request.questions) q.question: TextEditingController()};
  bool _sending = false;

  @override
  void dispose() {
    for (final c in _free.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The change option of each `pr` point that has one, by question text.
  Map<String, String> get _changeLabels {
    final points = widget.points;
    if (points == null) return const {};
    return {for (final (i, q) in widget.request.questions.indexed) q.question: ?prChangeOption(q, points[i])};
  }

  Map<String, String> get _draft {
    final questions = widget.request.questions;
    if (widget.points != null) {
      return prAnswers(questions, _picked, {
        for (final MapEntry(:key, :value) in _free.entries) key: value.text,
      }, _changeLabels);
    }
    final out = answersFor(
      questions,
      {
        for (final MapEntry(:key, :value) in _picked.entries) key: {value},
      },
      free: {for (final MapEntry(:key, :value) in _free.entries) key: value.text},
    );
    if (widget.approval) {
      final q = questions.single.question;
      final label = _picked[q];
      final text = _free[q]!.text.trim();
      out.remove(q);
      if (label != null && !_isAdjust(label)) {
        out[q] = label;
      } else if (label != null && text.isNotEmpty) {
        out[q] = text;
      }
    }
    return out;
  }

  Future<void> _submit(Map<String, String> answers) async {
    setState(() => _sending = true);
    await widget.onSend(answers);
    if (mounted) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final questions = widget.request.questions;
    final draft = _draft;
    final changes = _changeLabels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _Scroll([
            ...widget.leading,
            const SizedBox(height: 24),
            Column(
              key: const ValueKey('gate-questions'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, q) in questions.indexed) ...[
                  if (i > 0) const SizedBox(height: 16),
                  if (widget.points case final points?)
                    _point(i, q, points[i], changes[q.question], decided: draft.containsKey(q.question))
                  else
                    _question(i, q, decided: draft.containsKey(q.question)),
                ],
              ],
            ),
            ...widget.trailing,
          ]),
        ),
        _footer(draft.length, questions.length, draft),
      ],
    );
  }

  Widget _question(int index, Question q, {required bool decided}) {
    final c = context.colors;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${index + 1}',
                key: ValueKey('gate-q-$index-number'),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: decided ? c.textSecondary : c.warn),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  q.question,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final (o, option) in q.options.indexed) ...[_option(index, o, q, option), const SizedBox(height: 6)],
          const SizedBox(height: 4),
          TextField(
            key: ValueKey('gate-free-$index'),
            controller: _free[q.question],
            onChanged: (_) => setState(() {}),
            enabled: !_sending,
            minLines: 1,
            maxLines: 4,
            style: TextStyle(fontSize: 13, color: c.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: widget.approval ? 'o ajuste, se escolher Ajustar' : 'outra resposta, no lugar da opção',
            ),
          ),
        ],
      ),
    );
  }

  Widget _point(int index, Question q, GateQuestion? block, String? change, {required bool decided}) {
    final c = context.colors;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PointHead(
            index: index,
            text: q.question,
            block: block,
            diff: widget.diff,
            color: decided ? c.textSecondary : c.warn,
          ),
          const SizedBox(height: 12),
          for (final (o, option) in q.options.indexed) ...[_option(index, o, q, option), const SizedBox(height: 6)],
          if (change != null && _picked[q.question] == change) ...[
            const SizedBox(height: 4),
            TextField(
              key: ValueKey('gate-change-$index'),
              controller: _free[q.question],
              onChanged: (_) => setState(() {}),
              enabled: !_sending,
              minLines: 2,
              maxLines: 6,
              style: TextStyle(fontSize: 13, color: c.textPrimary),
              decoration: const InputDecoration(isDense: true, hintText: 'o que mudar neste trecho'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _option(int question, int index, Question q, QuestionOption option) {
    final c = context.colors;
    final selected = _picked[q.question] == option.label;
    return InkWell(
      key: ValueKey('gate-option-$question-$index'),
      borderRadius: BorderRadius.circular(8),
      onTap: _sending ? null : () => setState(() => _picked[q.question] = option.label),
      child: Container(
        constraints: const BoxConstraints(minHeight: _kMinTarget),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: c.elevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? c.textSecondary : c.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color: selected ? c.textPrimary : c.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.label, style: TextStyle(fontSize: 13, color: c.textPrimary)),
                  if (option.description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(option.description, style: TextStyle(fontSize: 12.5, color: c.textSecondary)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(int decided, int total, Map<String, String> draft) {
    final c = context.colors;
    final omitted = widget.omitted;
    final left = [
      if (omitted.risks > 0) countLabel(omitted.risks, 'risco'),
      if (omitted.questions > 0) countLabel(omitted.questions, 'pergunta'),
      if (omitted.candidates > 0) countLabel(omitted.candidates, 'candidata'),
    ];
    final artifact = widget.artifactLocation;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: _Column(
        children: [
          if (left.isNotEmpty)
            Row(
              key: const ValueKey('gate-omitted'),
              children: [
                Flexible(child: Muted('Ficou de fora do resumo: ${left.join(', ')}')),
                if (artifact != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    key: const ValueKey('gate-artifact'),
                    style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                    onPressed: () => context.go(artifact),
                    child: const Text('ver o documento', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ],
            ),
          Row(
            children: [
              Expanded(child: Muted('$decided de $total decididas', key: const ValueKey('gate-progress'))),
              FilledButton(
                key: const ValueKey('gate-send'),
                style: FilledButton.styleFrom(
                  backgroundColor: c.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, _kMinTarget),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                onPressed: decided == total && !_sending ? () => unawaited(_submit(draft)) : null,
                child: const Text('Enviar decisões', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
