import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../engine/engine_config.dart';
import 'session_models.dart';
import 'session_reducer.dart';
import 'sessions_repository.dart';
import 'sse.dart';

/// In-memory sessions fed through the same [applyFrame] as the engine stream; actions emit the frames
/// the engine would.
class MockSessionsRepository implements SessionsRepository {
  MockSessionsRepository() {
    for (final (summary, frames) in _seed) {
      _order.add(summary.id);
      _details[summary.id] = frames.fold(SessionDetail(summary: summary), applyFrame);
    }
  }

  final _order = <String>[];
  final _details = <String, SessionDetail>{};
  final _updates = StreamController<void>.broadcast();
  var _created = 0;

  /// Every [create] call, in order, for tests to assert the exact command, cwd, account and mode.
  final createCalls =
      <(String project, String command, String? cwd, String? githubAccount, PermissionMode? permissionMode)>[];

  /// Agent of every [create] and [createInOrg] call, in call order across both.
  final agentCalls = <OrgAgent>[];

  /// Every [createInOrg] call, in order.
  final orgCreateCalls =
      <
        (
          String org,
          String command,
          String cwd,
          List<String> additionalDirectories,
          String? githubAccount,
          PermissionMode? permissionMode,
        )
      >[];

  /// Every [setPermissionMode] call, in order.
  final setPermissionModeCalls = <(String id, PermissionMode mode)>[];

  List<SessionSummary> get _list => [for (final id in _order) _details[id]!.summary];

  @override
  Stream<List<SessionSummary>> watchSessions() => Stream.multi((controller) {
    controller.add(_list);
    final sub = _updates.stream.listen((_) => controller.add(_list));
    controller.onCancel = sub.cancel;
  });

  @override
  Stream<SessionDetail> watchSession(String id) => Stream.multi((controller) {
    final current = _details[id];
    if (current != null) controller.add(current);
    final sub = _updates.stream.listen((_) {
      final next = _details[id];
      if (next != null) controller.add(next);
    });
    controller.onCancel = sub.cancel;
  });

  @override
  Future<List<PaletteSkill>> skills() async => const [
    PaletteSkill('fix', 'Fluxo leve para bugs'),
    PaletteSkill('status', 'Estado atual do Fluxo Smart'),
    PaletteSkill('review', 'Revisão de um PR aberto'),
    PaletteSkill('kickoff', 'Entrada do pipeline a partir de um card'),
  ];

  @override
  Future<SessionSummary> create(
    String project,
    String command, {
    String? cwd,
    String? githubAccount,
    required PermissionMode permissionMode,
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  }) async {
    createCalls.add((project, command, cwd, githubAccount, permissionMode));
    agentCalls.add(agent);
    createImages.add(images);
    return _add(
      (id) => SessionSummary(
        id: id,
        project: project,
        command: command,
        title: command,
        status: SessionStatus.idle,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        permissionMode: permissionMode,
      ),
    );
  }

  @override
  Future<SessionSummary> createInOrg(
    String org,
    String command, {
    required String cwd,
    List<String> additionalDirectories = const [],
    String? githubAccount,
    required PermissionMode permissionMode,
    OrgAgent agent = OrgAgent.anthropic,
    List<ImageAttachment> images = const [],
  }) async {
    orgCreateCalls.add((org, command, cwd, additionalDirectories, githubAccount, permissionMode));
    agentCalls.add(agent);
    createImages.add(images);
    return _add(
      (id) => SessionSummary(
        id: id,
        project: '',
        command: command,
        title: command,
        status: SessionStatus.idle,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        cwd: cwd,
        org: org,
        additionalDirectories: additionalDirectories,
        permissionMode: permissionMode,
      ),
    );
  }

  @override
  Future<void> setPermissionMode(String id, PermissionMode mode) async {
    setPermissionModeCalls.add((id, mode));
    _apply(id, [
      _event(id, {'kind': 'permission_mode', 'mode': mode.wire}),
    ]);
  }

  /// Every [askAside] call as `(id, text)`.
  final asideCalls = <(String id, String text)>[];

  @override
  Future<SessionSummary> askAside(String id, String text) async {
    asideCalls.add((id, text));
    final parent = _details[id]!.summary;
    return _add(
      (aside) => SessionSummary(
        id: aside,
        project: parent.project,
        command: text,
        title: text,
        status: SessionStatus.idle,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        org: parent.org,
        cwd: parent.cwd,
        permissionMode: PermissionMode.plan,
        asideOf: id,
      ),
    );
  }

  final _handoffs = StreamController<TerminalHandoff>.broadcast();

  @override
  Stream<TerminalHandoff> terminalHandoffs() => _handoffs.stream;

  /// What the engine relays when the terminal runs `/app`.
  void requestHandoff(String sdkSessionId, String cwd) => _handoffs.add((sdkSessionId: sdkSessionId, cwd: cwd));

  /// What [terminalSessions] lists, per cwd; tests fill it.
  final terminal = <String, List<TerminalSession>>{};

  /// Every [importTerminalSession] call as `(sdkSessionId, cwd, project, permissionMode)`.
  final importCalls = <(String sdkSessionId, String cwd, String project, PermissionMode permissionMode)>[];

  @override
  Future<List<TerminalSession>> terminalSessions(String cwd) async => terminal[cwd] ?? const [];

  @override
  Future<SessionSummary> importTerminalSession({
    required String sdkSessionId,
    required String cwd,
    required String project,
    String? githubAccount,
    required PermissionMode permissionMode,
  }) async {
    importCalls.add((sdkSessionId, cwd, project, permissionMode));
    TerminalSession? source;
    for (final list in terminal.values) {
      source ??= list.where((t) => t.sdkSessionId == sdkSessionId).firstOrNull;
      list.remove(source);
    }
    final title = source?.firstPrompt ?? source?.title ?? sdkSessionId;
    final id = 'mock-${++_created}';
    final summary = SessionSummary(
      id: id,
      project: project,
      command: title,
      title: title,
      status: SessionStatus.detached,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      resumable: true,
      cwd: cwd,
      permissionMode: permissionMode,
    );
    _order.insert(0, id);
    _details[id] = SessionDetail(summary: summary);
    _apply(id, [_event(id, {'kind': 'user_text', 'text': title})]);
    _apply(id, [_event(id, {'kind': 'imported', 'dropped': 0})]);
    return summary;
  }

  SessionSummary _add(SessionSummary Function(String id) build) {
    final id = 'mock-${++_created}';
    final summary = build(id);
    _order.insert(0, id);
    _details[id] = SessionDetail(summary: summary);
    _apply(id, [
      _event(id, {'kind': 'user_text', 'text': summary.command}),
    ]);
    return summary;
  }

  @override
  Future<void> send(String id, String text, {List<ImageAttachment> images = const []}) async {
    sendCalls.add((id, text, images));
    return _apply(id, [
      _event(id, {
        'kind': 'user_text',
        'text': text,
        if (images.isNotEmpty) 'images': [for (var i = 0; i < images.length; i++) 'image-$i.png'],
      }),
      _status('idle'),
    ]);
  }

  /// Every [send] call, in order.
  final sendCalls = <(String id, String text, List<ImageAttachment> images)>[];

  /// Images of each [create]/[createInOrg] call, in order.
  final createImages = <List<ImageAttachment>>[];

  @override
  Uri? attachmentUri(String id, String name) => null;

  @override
  Future<void> answer(String id, String requestId, PermissionDecision decision, {Map<String, String>? answers}) async =>
      _apply(id, [
        _event(id, {
          'kind': 'permission_resolved',
          'requestId': requestId,
          'decision': decision.name,
          'answers': ?answers,
        }),
        _status('idle'),
      ]);

  @override
  Future<void> resume(String id) async => _apply(id, [
    _event(id, {'kind': 'reattached'}),
    _status('idle'),
  ]);

  @override
  Future<void> interrupt(String id) async => _apply(id, [_status('idle')]);

  void _apply(String id, List<SseFrame> frames) {
    final current = _details[id];
    if (current == null) throw SessionsException('sessão não encontrada: $id', statusCode: 404);
    _details[id] = frames.fold(current, applyFrame);
    _updates.add(null);
  }

  SseFrame _event(String id, Map<String, Object?> event) => SseFrame(
    'event',
    jsonEncode({'seq': _details[id]!.lastSeq + 1, 'at': DateTime.now().toUtc().toIso8601String(), ...event}),
  );

  /// `default` is logged in; any other account is not, until a test adds it to [loggedInAccounts].
  final loggedInAccounts = <String>{kDefaultAgentAccount};

  @override
  Future<AgentAccountStatus> agentAccount(String account) async => AgentAccountStatus(
    account: account,
    loggedIn: loggedInAccounts.contains(account),
    loginCommand: 'HOME="~/.claude-flow/accounts/antigravity/$account" agy',
  );

  /// Puts [summary] at the top of the list with [events] replayed as the engine would; [status] is the engine's
  /// spelling (`idle`, `running`…).
  void addSession(SessionSummary summary, List<Map<String, Object?>> events, {String status = 'idle'}) {
    _order.insert(0, summary.id);
    _details[summary.id] = _log(summary.createdAt, events, status).fold(SessionDetail(summary: summary), applyFrame);
    _updates.add(null);
  }

  /// What [readiness] answers; tests replace it.
  Readiness readinessState = const Readiness(
    claudeOk: true,
    claudeAccount: 'dev@example.com',
    claudePlan: 'max',
    ghOk: true,
    ghActive: 'acct-a',
  );

  @override
  Future<Readiness> readiness({bool fresh = false}) async => readinessState;

  /// Artifacts per session id, as `{name: content}`.
  final artifacts = <String, Map<String, String>>{};

  @override
  Future<List<SessionArtifact>> sessionArtifacts(String id) async => [
    for (final e in (artifacts[id] ?? const {}).entries)
      SessionArtifact(name: e.key, size: e.value.length, modifiedAt: '2026-10-06T10:00:00Z'),
  ];

  @override
  Future<String> sessionArtifact(String id, String name) async =>
      artifacts[id]?[name] ?? (throw const SessionsException('artefato nao encontrado', statusCode: 404));

  /// Diagrams need the engine's Chrome: the mock answers like an engine without it, and the block keeps the code.
  @override
  Future<Uint8List> renderMermaid(String code, {required bool dark}) async =>
      throw const SessionsException('Chrome nao encontrado', statusCode: 501);

  /// Every [setModel] call, in order.
  final setModelCalls = <(String id, String model)>[];

  @override
  Future<List<AgentModel>> claudeModels() async => const [
    AgentModel('opus', 'Opus'),
    AgentModel('sonnet', 'Sonnet'),
    AgentModel('haiku', 'Haiku'),
  ];

  @override
  Future<void> setModel(String id, String model) async {
    setModelCalls.add((id, model));
    final detail = _details[id];
    if (detail == null) return;
    _details[id] = detail.copyWith(summary: detail.summary.copyWith(model: model));
    _updates.add(null);
  }

  /// Every [revealArtifact] call, as `(id, name)`.
  final revealCalls = <(String id, String name)>[];

  @override
  Future<void> revealArtifact(String id, String name) async => revealCalls.add((id, name));

  /// Every [cycleAction] call, in order.
  final cycleCalls = <(String project, CycleAction action)>[];

  @override
  Future<void> cycleAction(String project, CycleAction action) async => cycleCalls.add((project, action));

  /// Every [agentLogin] call, in order.
  final agentLoginCalls = <String>[];

  @override
  Future<void> agentLogin(String account) async => agentLoginCalls.add(account);

  @override
  Future<List<AgentModel>> agentModels(String account) async {
    if (!loggedInAccounts.contains(account)) {
      throw SessionsException('conta $account sem login no Antigravity', statusCode: 409);
    }
    // Relative to now: a fixed date turns "renova em" into "renovando" once it passes.
    final resetsAt = DateTime.now().toUtc().add(const Duration(days: 3));
    final gemini = AgentQuota(remaining: 0, resetsAt: resetsAt);
    final claude = AgentQuota(remaining: 0.97, resetsAt: resetsAt);
    return [
      AgentModel('gemini-3.8-flash-high', 'Gemini 3.8 Flash (High)', quota: gemini),
      AgentModel('gemini-3.1-pro-high', 'Gemini 3.1 Pro (High)', quota: gemini),
      AgentModel('claude-opus-4-6-thinking', 'Claude Opus 4.6 (Thinking)', quota: claude),
    ];
  }
}

SseFrame _status(String status) => SseFrame('status', jsonEncode({'status': status}));

List<SseFrame> _log(String at, List<Map<String, Object?>> events, String status) => [
  for (final (i, e) in events.indexed) SseFrame('event', jsonEncode({'seq': i + 1, 'at': at, ...e})),
  _status(status),
];

final _seed = <(SessionSummary, List<SseFrame>)>[
  (
    const SessionSummary(
      id: 's-fix-sync',
      project: 'demo-app',
      command: '/fix',
      title: 'Logger no lugar de debugPrint no sync',
      status: SessionStatus.waitingPermission,
      createdAt: '2026-03-10T14:41:00Z',
      cost: 0.18,
      model: 'opus',
    ),
    _log('2026-03-10T14:41:00Z', [
      {'kind': 'user_text', 'text': '/fix trocar debugPrint por logger em favorites_sync.dart (finding do G1 na T4)'},
      {
        'kind': 'thinking',
        'text':
            'O finding é .claude/rules/logging.md. Preciso ver qual logger o projeto usa antes de editar — '
            'provavelmente AppLogger em core/logging.',
      },
      {
        'kind': 'tool_use',
        'id': 'tu-1',
        'name': 'Read',
        'input': {'file_path': '.claude/rules/logging.md'},
      },
      {'kind': 'tool_result', 'id': 'tu-1', 'text': '12 linhas'},
      {
        'kind': 'tool_use',
        'id': 'tu-2',
        'name': 'Grep',
        'input': {'pattern': 'AppLogger', 'path': 'lib/'},
      },
      {
        'kind': 'tool_result',
        'id': 'tu-2',
        'text': 'lib/core/logging/app_logger.dart\nlib/features/auth/data/auth_repository.dart\n+14 arquivos',
      },
      {
        'kind': 'assistant_text',
        'text':
            'O projeto usa `AppLogger` injetado via construtor. Vou trocar o `debugPrint` e receber o logger no '
            '`FavoritesSync`, igual ao `AuthRepository`.',
      },
      {
        'kind': 'permission',
        'requestId': 'rq-1',
        'toolName': 'MultiEdit',
        'input': {
          'file_path': 'lib/features/favorites/data/favorites_sync.dart',
          'edits': [
            {
              'old_string':
                  'class FavoritesSync {\n  FavoritesSync(this._queue, this._api);\n\n'
                  '  final MutationQueue _queue;\n  final FavoritesApi _api;',
              'new_string':
                  'class FavoritesSync {\n  FavoritesSync(this._queue, this._api, this._logger);\n\n'
                  '  final MutationQueue _queue;\n  final FavoritesApi _api;\n  final AppLogger _logger;',
            },
            {
              'old_string': "  Future<void> flush() async {\n    debugPrint('flushing \${_queue.length} mutations');",
              'new_string':
                  "  Future<void> flush() async {\n    _logger.info('favorites.sync.flush', {'pending': _queue.length});",
            },
          ],
        },
      },
    ], 'waiting_permission'),
  ),
  (
    const SessionSummary(
      id: 's-challenge',
      project: 'demo-app',
      command: '/challenge-spec',
      title: 'Desafio da spec Favoritos offline',
      status: SessionStatus.idle,
      createdAt: '2026-03-10T13:20:00Z',
      cost: 0.41,
      model: 'opus',
    ),
    _log('2026-03-10T13:20:00Z', [
      {'kind': 'user_text', 'text': '/challenge-spec'},
      {
        'kind': 'tool_use',
        'id': 'tu-1',
        'name': 'Agent',
        'input': {'description': 'spec-challenger · spec.md'},
      },
      {'kind': 'tool_result', 'id': 'tu-1', 'text': 'Veredito: AJUSTES · 1 bloqueante, 2 ajustes'},
      {
        'kind': 'assistant_text',
        'text':
            '**Veredito: AJUSTES**\n\n'
            '- **[B1]** Critério 3 ("funciona offline instantaneamente") não diz se a UI reflete antes do enqueue.\n'
            '- **[A1]** Estado de erro de sync não aparece em nenhum critério.\n'
            '- **[A2]** Falta "Fora do escopo: sync entre dispositivos".',
      },
      {
        'kind': 'permission',
        'requestId': 'rq-1',
        'toolName': 'AskUserQuestion',
        'input': {
          'questions': [
            {
              'header': 'Aplicar',
              'question': 'Quais itens aplico na spec.md?',
              'multiSelect': true,
              'options': [
                {'label': 'B1', 'description': 'Reescrever critério 3: UI otimista após enqueue confirmado'},
                {'label': 'A1', 'description': 'Novo critério: erro de sync visível com retry'},
                {'label': 'A2', 'description': 'Fora do escopo: sync entre dispositivos'},
              ],
            },
          ],
        },
      },
    ], 'idle'),
  ),
  (
    const SessionSummary(
      id: 's-review',
      project: 'notifications-api',
      command: '/review 412',
      title: 'Review PR #412 retry com backoff',
      status: SessionStatus.done,
      createdAt: '2026-03-10T11:05:00Z',
      cost: 1.12,
      model: 'opus',
    ),
    _log('2026-03-10T11:05:00Z', [
      {'kind': 'user_text', 'text': '/review 412'},
      {
        'kind': 'tool_use',
        'id': 'tu-1',
        'name': 'Bash',
        'input': {'command': 'gh pr view 412 --json files,title'},
      },
      {'kind': 'tool_result', 'id': 'tu-1', 'text': '6 arquivos · +214 −38'},
      for (final (i, agent, verdict) in const [
        (2, 'go-concurrency', '1 major'),
        (3, 'go-correctness', 'sem findings'),
        (4, 'go-testing', '1 minor'),
      ]) ...[
        {
          'kind': 'tool_use',
          'id': 'tu-$i',
          'name': 'Agent',
          'input': {'description': agent},
        },
        {'kind': 'tool_result', 'id': 'tu-$i', 'text': verdict},
      ],
      {
        'kind': 'assistant_text',
        'text': 'Draft salvo em `reviews/412.md` com 2 comentários inline. Rode `/approve-review 412` para liberar.',
      },
      {'kind': 'result', 'isError': false, 'cost': 1.12, 'durationMs': 241000, 'numTurns': 9},
    ], 'done'),
  ),
  (
    const SessionSummary(
      id: 's-status',
      project: 'demo-app',
      command: '/status',
      title: 'Status do fluxo',
      status: SessionStatus.detached,
      createdAt: '2026-03-09T18:00:00Z',
      cost: 0.03,
      model: 'sonnet',
      resumable: true,
    ),
    _log('2026-03-09T18:00:00Z', [
      {'kind': 'user_text', 'text': '/status'},
      {'kind': 'assistant_text', 'text': 'Fluxo em **implement** · 3/5 tasks · T4 bloqueada.'},
    ], 'detached'),
  ),
];
