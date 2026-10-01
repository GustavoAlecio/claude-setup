import 'dart:async';
import 'dart:convert';

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
  ];

  @override
  Future<SessionSummary> create(String project, String command, {String? cwd}) async {
    final id = 'mock-${++_created}';
    final summary = SessionSummary(
      id: id,
      project: project,
      command: command,
      title: command,
      status: SessionStatus.idle,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    _order.insert(0, id);
    _details[id] = SessionDetail(summary: summary);
    _apply(id, [
      _event(id, {'kind': 'user_text', 'text': command}),
    ]);
    return summary;
  }

  @override
  Future<void> send(String id, String text) async => _apply(id, [
    _event(id, {'kind': 'user_text', 'text': text}),
    _status('idle'),
  ]);

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
