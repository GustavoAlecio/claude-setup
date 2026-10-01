import 'session_models.dart';

const mockSessions = <SessionSummary>[
  SessionSummary(
    id: 's-fix-sync',
    project: 'demo-app',
    command: '/fix',
    title: 'Logger no lugar de debugPrint no sync',
    status: SessionStatus.waitingPermission,
    startedAt: '14:41',
    cost: 0.18,
    model: 'opus',
    cwd: '~/development/demo-app',
    events: [
      UserText('14:41', '/fix trocar debugPrint por logger em favorites_sync.dart (finding do G1 na T4)'),
      Thinking(
        '14:41',
        'O finding é .claude/rules/logging.md. Preciso ver qual logger o projeto usa antes de editar — '
            'provavelmente AppLogger em core/logging.',
        seconds: 4,
      ),
      ToolCall('14:41', name: 'Read', summary: '.claude/rules/logging.md', result: '12 linhas'),
      ToolCall(
        '14:41',
        name: 'Grep',
        summary: 'AppLogger  lib/',
        result: 'lib/core/logging/app_logger.dart\nlib/features/auth/data/auth_repository.dart\n+14 arquivos',
      ),
      AssistantText(
        '14:42',
        'O projeto usa `AppLogger` injetado via construtor. Vou trocar o `debugPrint` e receber o logger no '
            '`FavoritesSync`, igual ao `AuthRepository`.',
      ),
      PermissionRequest(
        '14:42',
        toolName: 'Edit',
        target: 'lib/features/favorites/data/favorites_sync.dart',
        diff: [
          DiffLine(' ', 'class FavoritesSync {', 12),
          DiffLine('-', '  FavoritesSync(this._queue, this._api);', 13),
          DiffLine('+', '  FavoritesSync(this._queue, this._api, this._logger);', 13),
          DiffLine(' ', '', 14),
          DiffLine(' ', '  final MutationQueue _queue;', 15),
          DiffLine(' ', '  final FavoritesApi _api;', 16),
          DiffLine('+', '  final AppLogger _logger;', 17),
          DiffLine(' ', '', 18),
          DiffLine(' ', '  Future<void> flush() async {', 139),
          DiffLine('-', "    debugPrint('flushing \${_queue.length} mutations');", 140),
          DiffLine('+', "    _logger.info('favorites.sync.flush', {'pending': _queue.length});", 141),
        ],
      ),
    ],
  ),
  SessionSummary(
    id: 's-challenge',
    project: 'demo-app',
    command: '/challenge-spec',
    title: 'Desafio da spec Favoritos offline',
    status: SessionStatus.idle,
    startedAt: '13:20',
    cost: 0.41,
    model: 'opus',
    cwd: '~/development/demo-app',
    events: [
      UserText('13:20', '/challenge-spec'),
      ToolCall(
        '13:20',
        name: 'Agent',
        summary: 'spec-challenger · spec.md',
        result: 'Veredito: AJUSTES · 1 bloqueante, 2 ajustes',
      ),
      AssistantText(
        '13:24',
        '**Veredito: AJUSTES**\n\n'
            '- **[B1]** Critério 3 ("funciona offline instantaneamente") não diz se a UI reflete antes do enqueue.\n'
            '- **[A1]** Estado de erro de sync não aparece em nenhum critério.\n'
            '- **[A2]** Falta "Fora do escopo: sync entre dispositivos".',
      ),
      QuestionRequest(
        '13:24',
        header: 'Aplicar',
        question: 'Quais itens aplico na spec.md?',
        multiSelect: true,
        options: [
          QuestionOption('B1', 'Reescrever critério 3: UI otimista após enqueue confirmado'),
          QuestionOption('A1', 'Novo critério: erro de sync visível com retry'),
          QuestionOption('A2', 'Fora do escopo: sync entre dispositivos'),
        ],
      ),
    ],
  ),
  SessionSummary(
    id: 's-review',
    project: 'notifications-api',
    command: '/review 412',
    title: 'Review PR #412 retry com backoff',
    status: SessionStatus.done,
    startedAt: '11:05',
    cost: 1.12,
    model: 'opus',
    cwd: '~/development/notifications-api',
    events: [
      UserText('11:05', '/review 412'),
      ToolCall('11:05', name: 'Bash', summary: 'gh pr view 412 --json files,title', result: '6 arquivos · +214 −38'),
      ToolCall('11:06', name: 'Agent', summary: 'go-concurrency', result: '1 major'),
      ToolCall('11:06', name: 'Agent', summary: 'go-correctness', result: 'sem findings'),
      ToolCall('11:06', name: 'Agent', summary: 'go-testing', result: '1 minor'),
      AssistantText(
        '11:09',
        'Draft salvo em `reviews/412.md` com 2 comentários inline. Rode `/approve-review 412` para liberar.',
      ),
      SessionResult('11:09', isError: false, cost: 1.12, seconds: 241, turns: 9),
    ],
  ),
  SessionSummary(
    id: 's-status',
    project: 'demo-app',
    command: '/status',
    title: 'Status do fluxo',
    status: SessionStatus.detached,
    startedAt: 'ontem',
    cost: 0.03,
    model: 'sonnet',
    cwd: '~/development/demo-app',
    resumable: true,
    events: [
      UserText('ontem', '/status'),
      AssistantText('ontem', 'Fluxo em **implement** · 3/5 tasks · T4 bloqueada.'),
    ],
  ),
];
